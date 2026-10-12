using System.Reflection;
using System.Runtime.InteropServices;
using NUnit.Framework;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Memory.Range;

namespace Ryujinx.SaveSync.Tests;

public class TextureAliasTests
{
    private sealed class Renderer : BufferCacheBindingTests.BufferRenderer
    {
        public override ITexture CreateTexture(TextureCreateInfo info) => new HostTexture(info.Width, info.Height);
    }

    private sealed class HostTexture(int width, int height) : ITexture
    {
        public int Width => width;
        public int Height => height;
        public byte[] Bytes = new byte[8];
        public int PinReleases;
        public int Writes;
        public void CopyTo(ITexture destination, int firstLayer, int firstLevel) => throw new AssertionException("Format-converting copy is invalid for exposure aliases");
        public void CopyTo(ITexture destination, int srcLayer, int dstLayer, int srcLevel, int dstLevel) => CopyTo(destination, srcLayer, srcLevel);
        public void CopyTo(ITexture destination, Extents2D srcRegion, Extents2D dstRegion, bool linearFilter) => throw new NotSupportedException();
        public void CopyTo(BufferRange range, int layer, int level, int stride) => throw new NotSupportedException();
        public ITexture CreateView(TextureCreateInfo info, int firstLayer, int firstLevel) => throw new NotSupportedException();
        public PinnedSpan<byte> GetData() => GetData(0, 0);
        public unsafe PinnedSpan<byte> GetData(int layer, int level)
        {
            var pin = GCHandle.Alloc(Bytes, GCHandleType.Pinned);
            return new PinnedSpan<byte>((void*)pin.AddrOfPinnedObject(), Bytes.Length, () => { PinReleases++; pin.Free(); });
        }
        public void SetData(MemoryOwner<byte> data) => SetData(data, 0, 0);
        public void SetData(MemoryOwner<byte> data, int layer, int level)
        {
            try { Bytes = data.Memory.Span.ToArray(); Writes++; } finally { data.Dispose(); }
        }
        public void SetData(MemoryOwner<byte> data, int layer, int level, Rectangle<int> region) => SetData(data, layer, level);
        public void SetStorage(BufferRange buffer) => throw new NotSupportedException();
        public void Release() {}
    }

    private sealed class Fixture : IDisposable
    {
        public GpuContext Context = new(new Renderer(), default);
        public PhysicalMemory Physical;
        private readonly List<Ryujinx.Graphics.Gpu.Image.Texture> _textures = [];
        public Fixture() { Physical = new(Context, new BufferCacheBindingTests.TrackedMemory()); }
        public (Ryujinx.Graphics.Gpu.Image.Texture Texture, TextureGroupHandle Handle, HostTexture Host) Make(bool exposure, ulong address = 0x1000, ulong rangeSize = 512,
            Format? formatOverride = null, int levels = 1, int samples = 1, int? width = null, int height = 1, int gobY = 1)
        {
            var format = exposure ? new FormatInfo(Format.R32G32Float, 1, 1, 8, 2) : new FormatInfo(Format.R32Uint, 1, 1, 4, 1);
            if (formatOverride.HasValue) format = new FormatInfo(formatOverride.Value, 1, 1, format.BytesPerPixel, format.Components);
            var info = new TextureInfo(address, width ?? (exposure ? 1 : 2), height, 1, levels, samples, 1, 0, false, gobY, 1, 1, Target.Texture2D, format);
            var texture = new Ryujinx.Graphics.Gpu.Image.Texture(Context, Physical, info, info.CalculateSizeInfo(), new MultiRange(address, rangeSize), TextureScaleMode.Blacklisted);
            texture.InitializeGroup(false, false, []);
            texture.InitializeData(false);
            _textures.Add(texture);
            var handles = (TextureGroupHandle[])typeof(TextureGroup).GetField("_handles", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(texture.Group)!;
            return (texture, handles.Single(), (HostTexture)texture.HostTexture);
        }
        public void Dispose() { foreach (var texture in _textures) texture.Group.Dispose(); Physical.Dispose(); Context.Dispose(); }
    }

    private static TextureGroupHandle CurrentHandle(Ryujinx.Graphics.Gpu.Image.Texture texture) =>
        ((TextureGroupHandle[])typeof(TextureGroup).GetField("_handles", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(texture.Group)!).Single();

    [Test]
    public void ExposureAliasesCopyExactLatestBitsLazily()
    {
        using var f = new Fixture();
        var source = f.Make(true); var target = f.Make(false);
        Assert.That(TextureCompatibility.IsFormatHostIncompatible(source.Texture.Info, default), Is.False);
        Assert.That(TextureCompatibility.IsFormatHostIncompatible(target.Texture.Info, default), Is.False);
        target.Texture.Group.RegisterIncompatibleOverlap(new(source.Texture.Group, TextureViewCompatibility.Incompatible), true);
        int initialPins = source.Host.PinReleases;
        source.Host.Bytes = [0, 0, 128, 63, 0, 0, 0, 64];
        source.Texture.Group.SignalModified(source.Texture);
        Assert.That(CurrentHandle(target.Texture).NeedsCopy, Is.True);
        Assert.That(target.Host.Bytes, Is.EqualTo(new byte[8]));
        Assert.That(CurrentHandle(target.Texture).Copy(f.Context), Is.True);
        Assert.That(target.Host.Bytes, Is.EqualTo(source.Host.Bytes));
        source.Host.Bytes = [0, 0, 0, 63, 0, 0, 128, 64];
        source.Texture.Group.SignalModified(source.Texture);
        Assert.That(CurrentHandle(target.Texture).Copy(f.Context), Is.True);
        Assert.That(target.Host.Bytes, Is.EqualTo(source.Host.Bytes));
        Assert.That(source.Host.PinReleases, Is.EqualTo(initialPins + 2));
    }

    [TestCase(0x2000UL, 512UL)]
    [TestCase(0x1000UL, 1024UL)]
    public void DifferentGuestRangeDoesNotCreateRawDependency(ulong address, ulong size)
    {
        using var f = new Fixture(); var source = f.Make(true); var target = f.Make(false, address, size);
        target.Texture.Group.RegisterIncompatibleOverlap(new(source.Texture.Group, TextureViewCompatibility.Incompatible), true);
        Assert.That(CurrentHandle(target.Texture).Dependencies, Is.Empty);
    }

    [Test]
    public void DisallowedRawFormatsAndLayoutsCannotFallBackToRegularCopy()
    {
        using var f = new Fixture(); var source = f.Make(false);
        var targets = new[] { f.Make(false, formatOverride: Format.D32Float), f.Make(false, levels: 2),
            f.Make(false, samples: 2), f.Make(false, width: 1, height: 2), f.Make(false, gobY: 2) };
        foreach (var target in targets)
        {
            target.Texture.Group.RegisterIncompatibleOverlap(new(source.Texture.Group, TextureViewCompatibility.Incompatible), true);
            Assert.That(CurrentHandle(target.Texture).Dependencies, Is.Empty);
            Assert.That(target.Host.Writes, Is.Zero);
        }
    }

    [Test]
    public void InvalidReadbackLengthRetainsPendingCopyAndReleasesPin()
    {
        using var f = new Fixture(); var source = f.Make(true); var target = f.Make(false);
        target.Texture.Group.RegisterIncompatibleOverlap(new(source.Texture.Group, TextureViewCompatibility.Incompatible), true);
        source.Host.Bytes = new byte[7]; source.Texture.Group.SignalModified(source.Texture);
        var handle = CurrentHandle(target.Texture); int pins = source.Host.PinReleases;
        Assert.That(handle.Copy(f.Context), Is.False);
        Assert.That(handle.NeedsCopy && handle.DeferredCopyRaw, Is.True);
        Assert.That(source.Host.PinReleases, Is.EqualTo(pins + 1));
        source.Host.Bytes = [1, 2, 3, 4, 5, 6, 7, 8];
        Assert.That(handle.Copy(f.Context), Is.True);
        Assert.That(target.Host.Bytes, Is.EqualTo(source.Host.Bytes));
        Assert.That(handle.NeedsCopy || handle.DeferredCopyRaw, Is.False);
    }

    [Test]
    public void InheritedHandlePreservesRawDependencyAndPendingMode()
    {
        using var f = new Fixture(); var source = f.Make(true); var target = f.Make(false);
        target.Texture.Group.RegisterIncompatibleOverlap(new(source.Texture.Group, TextureViewCompatibility.Incompatible), true);
        source.Host.Bytes = [8, 7, 6, 5, 4, 3, 2, 1]; source.Texture.Group.SignalModified(source.Texture);
        using var inherited = new TextureGroupHandle(target.Texture.Group, 0, 512, null, 0, 0, 0, 1, []);
        inherited.Inherit(CurrentHandle(target.Texture), true);
        Assert.That(inherited.Dependencies.All(x => x.RawCopy), Is.True);
        Assert.That(inherited.DeferredCopyRaw, Is.True);
        Assert.That(inherited.Copy(f.Context), Is.True);
        Assert.That(target.Host.Bytes, Is.EqualTo(source.Host.Bytes));
    }

    [Test]
    public void RawEdgeCannotCreateUnvalidatedRegularTransitiveEdge()
    {
        using var f = new Fixture(); var source = f.Make(true); var alias = f.Make(false); var third = f.Make(false);
        alias.Texture.Group.RegisterIncompatibleOverlap(new(source.Texture.Group, TextureViewCompatibility.Incompatible), true);
        CurrentHandle(alias.Texture).CreateCopyDependency(CurrentHandle(third.Texture));
        Assert.That(CurrentHandle(source.Texture).Dependencies.Any(x => x.Other.Handle == CurrentHandle(third.Texture)), Is.False);
    }

    [Test]
    public void InitialRawCopyRespectsCpuDirtyAndNewerTargetData()
    {
        using var f = new Fixture(); var source = f.Make(true); var target = f.Make(false);
        source.Host.Bytes = [1, 2, 3, 4, 5, 6, 7, 8]; target.Host.Bytes = [9, 9, 9, 9, 9, 9, 9, 9];
        var sourceHandle = CurrentHandle(source.Texture); var targetHandle = CurrentHandle(target.Texture);
        foreach (var region in sourceHandle.Handles) region.ForceDirty();
        Assert.That(targetHandle.Copy(f.Context, sourceHandle, rawCopy: true), Is.False);
        foreach (var region in sourceHandle.Handles) region.Reprotect();
        targetHandle.Modified = true;
        Assert.That(targetHandle.Copy(f.Context, sourceHandle, rawCopy: true), Is.False);
        Assert.That(target.Host.Bytes, Is.EqualTo(new byte[] { 9, 9, 9, 9, 9, 9, 9, 9 }));
        Assert.That(targetHandle.Modified, Is.True);
    }

    [Test]
    public void CpuDirtyDiscardsBothPendingSourceAndRawMode()
    {
        using var f = new Fixture(); var source = f.Make(true); var target = f.Make(false);
        target.Texture.Group.RegisterIncompatibleOverlap(new(source.Texture.Group, TextureViewCompatibility.Incompatible), true);
        source.Texture.Group.SignalModified(source.Texture);
        var handle = CurrentHandle(target.Texture);
        Assert.That(handle.NeedsCopy && handle.DeferredCopyRaw, Is.True);
        typeof(TextureGroupHandle).GetMethod("DirtyAction", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(handle, null);
        Assert.That(handle.NeedsCopy || handle.DeferredCopyRaw, Is.False);
    }
}
