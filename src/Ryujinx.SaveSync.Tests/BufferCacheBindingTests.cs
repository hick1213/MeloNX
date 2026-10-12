using System.Reflection;
using System.Runtime.CompilerServices;
using NUnit.Framework;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Cpu;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using Ryujinx.Memory.Tracking;
using Ryujinx.Tests.Memory;

namespace Ryujinx.SaveSync.Tests;

public class BufferCacheBindingTests
{
    [Test]
    public void PreparingAnotherBufferMustNotInvalidateAnEarlierComputeBinding()
    {
        var renderer = new BufferRenderer();
        using var context = new GpuContext(renderer, default);
        var assembly = typeof(GpuContext).Assembly;
        var physicalType = assembly.GetType("Ryujinx.Graphics.Gpu.Memory.PhysicalMemory")!;
        using var physical = (IDisposable)Activator.CreateInstance(physicalType, context, new TrackedMemory())!;
        object cache = physicalType.GetProperty("BufferCache")!.GetValue(physical)!;
        var type = cache.GetType();
        type.GetField("_maxCachedBufferBytes", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(cache, 4096UL);
        var stageType = assembly.GetType("Ryujinx.Graphics.Gpu.Memory.BufferStage")!;
        object stage = Enum.ToObject(stageType, 0x40); // Compute storage read.
        var create = type.GetMethod("CreateBuffer", [typeof(ulong), typeof(ulong), stageType])!;
        create.Invoke(cache, [0x1000UL, 4096UL, stage]);
        create.Invoke(cache, [0x3000UL, 4096UL, stage]);
        var get = type.GetMethod("GetBufferRangeAligned", [typeof(MultiRange), stageType, typeof(bool)])!;
        Assert.DoesNotThrow(() => get.Invoke(cache, [new MultiRange(0x1000, 4096), stage, false]));
        var first = (BufferRange)get.Invoke(cache, [new MultiRange(0x1000, 4096), stage, false])!;
        Assert.That(first.Handle, Is.Not.EqualTo(BufferHandle.Null));
        Assert.That(first.Size, Is.EqualTo(4096));
    }

    internal sealed class TrackedMemory : MockVirtualMemoryManager, IVirtualMemoryManagerTracked
    {
        private readonly byte[] _bytes = new byte[65536];
        private readonly MemoryTracking _tracking;
        public TrackedMemory() : base(65536, 4096) { _tracking = new MemoryTracking(this, 4096); }
        ReadOnlySpan<byte> IVirtualMemoryManager.GetSpan(ulong address, int size, bool tracked) => _bytes.AsSpan((int)address, size);
        public T ReadTracked<T>(ulong address) where T : unmanaged => throw new NotSupportedException();
        public void WriteUntracked(ulong address, ReadOnlySpan<byte> data) => data.CopyTo(_bytes.AsSpan((int)address));
        public RegionHandle BeginTracking(ulong address, ulong size, int id, RegionFlags flags) => _tracking.BeginTracking(address, size, id, flags);
        public MultiRegionHandle BeginGranularTracking(ulong address, ulong size, IEnumerable<IRegionHandle> handles, ulong granularity, int id, RegionFlags flags) => _tracking.BeginGranularTracking(address, size, handles, granularity, id, flags);
        public SmartMultiRegionHandle BeginSmartGranularTracking(ulong address, ulong size, ulong granularity, int id) => _tracking.BeginSmartGranularTracking(address, size, granularity, id);
    }

    internal class BufferRenderer : IRenderer
    {
        private ulong _next;
        public event EventHandler<ScreenCaptureImageInfo>? ScreenCaptured { add {} remove {} }
        public bool PreferThreading => false;
        public IPipeline Pipeline => throw new NotSupportedException();
        public IWindow Window => throw new NotSupportedException();
        public uint ProgramCount => 0;
        public void BackgroundContextAction(Action action, bool alwaysBackground = false) => action();
        public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default) { var value = ++_next; return Unsafe.As<ulong, BufferHandle>(ref value); }
        public BufferHandle CreateBuffer(nint pointer, int size) => CreateBuffer(size);
        public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers) => throw new NotSupportedException();
        public IImageArray CreateImageArray(int size, bool isBuffer) => throw new NotSupportedException();
        public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info) => throw new NotSupportedException();
        public ISampler CreateSampler(SamplerCreateInfo info) => throw new NotSupportedException();
        public virtual ITexture CreateTexture(TextureCreateInfo info) => throw new NotSupportedException();
        public ITextureArray CreateTextureArray(int size, bool isBuffer) => throw new NotSupportedException();
        public bool PrepareHostMapping(nint address, ulong size) => false;
        public void CreateSync(ulong id, bool strict) {}
        public void DeleteBuffer(BufferHandle buffer) {}
        public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size) => throw new NotSupportedException();
        public Capabilities GetCapabilities() => default;
        public ulong GetCurrentSync() => 0;
        public HardwareInfo GetHardwareInfo() => default;
        public IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info) => throw new NotSupportedException();
        public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data) {}
        public void UpdateCounters() {}
        public void PreFrame() {}
        public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved) => throw new NotSupportedException();
        public void ResetCounter(CounterType type) {}
        public void WaitSync(ulong id) {}
        public void Initialize(GraphicsDebugLevel logLevel) {}
        public void SetInterruptAction(Action<Action> interruptAction) {}
        public void Screenshot() {}
        public void Dispose() {}
    }
}
