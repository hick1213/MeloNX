using System.Reflection;
using System.Runtime.CompilerServices;
using NUnit.Framework;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Vulkan;

namespace Ryujinx.SaveSync.Tests;

public class TextureBufferWriteTests
{
    private const BindingFlags Fields = BindingFlags.Instance | BindingFlags.NonPublic;
    private static readonly Assembly Vulkan = typeof(VulkanRenderer).Assembly;

    // Exercise the actual TextureBuffer -> BufferManager -> BufferHolder path.
    // Only native view allocation and command-buffer ownership are bypassed.
    private sealed class Fixture
    {
        public readonly object Holder;
        private readonly object _texture;
        private readonly object _key;
        private readonly object _cbs;
        private readonly MethodInfo _getView;

        public Fixture(int offset, int size)
        {
            Holder = RuntimeHelpers.GetUninitializedObject(Type("BufferHolder"));
            var manager = RuntimeHelpers.GetUninitializedObject(Type("BufferManager"));
            var buffersField = manager.GetType().GetField("_buffers", Fields)!;
            var buffers = Activator.CreateInstance(buffersField.FieldType, true)!;
            int id = (int)buffers.GetType().GetMethod("Add")!.Invoke(buffers, [Holder])!;
            buffersField.SetValue(manager, buffers);

            var renderer = RuntimeHelpers.GetUninitializedObject(typeof(VulkanRenderer));
            Set(renderer, "<BufferManager>k__BackingField", manager);
            _texture = RuntimeHelpers.GetUninitializedObject(Type("TextureBuffer"));
            ulong rawHandle = (uint)id;
            Set(_texture, "_gd", renderer);
            Set(_texture, "_bufferHandle", Unsafe.As<ulong, BufferHandle>(ref rawHandle));
            Set(_texture, "_offset", offset);
            Set(_texture, "_size", size);
            Set(Holder, "<Size>k__BackingField", 512);

            var viewType = Type("DisposableBufferView");
            var autoType = Type("Auto`1").MakeGenericType(viewType);
            var view = autoType.GetConstructors().Single(c => c.GetParameters().Length == 4).Invoke(
                [Activator.CreateInstance(viewType), Holder, null, Array.CreateInstance(Type("IAutoPrivate"), 0)]);
            // Get still calls the real holder's ClearMirrors, without a native pool.
            Set(view, "_destroyed", true);
            Set(_texture, "_bufferView", view);
            _key = Activator.CreateInstance(Type("DrawCountCacheKey"))!;
            _cbs = Activator.CreateInstance(Type("CommandBufferScoped"))!;
            _getView = _texture.GetType().GetMethod("GetBufferView")!;
        }

        public void Cache(int offset, int size)
        {
            Holder.GetType().GetMethod("AddCachedConvertedBuffer")!.Invoke(Holder, [offset, size, _key, null]);
            Assert.That(Contains(offset, size), Is.True, "Fixture must seed a real conversion-cache entry.");
        }

        public bool Contains(int offset, int size) => (bool)Holder.GetType().GetMethod("TryGetCachedConvertedBuffer")!
            .Invoke(Holder, [offset, size, _key, null])!;

        public void GetView(bool write) => _getView.Invoke(_texture, [_cbs, write]);
    }

    [TestCase(64, 64)]
    [TestCase(96, 64)]
    [TestCase(32, 64)]
    public void WritableViewInvalidatesOverlappingConversions(int offset, int size)
    {
        var fixture = new Fixture(offset, size);
        fixture.Cache(64, 64);
        fixture.Cache(256, 64);
        fixture.GetView(true);
        Assert.That(fixture.Contains(64, 64), Is.False, "GPU image writes must invalidate converted geometry.");
        Assert.That(fixture.Contains(256, 64), Is.True, "Disjoint conversions should remain reusable.");
    }

    [Test]
    public void ReadOnlyViewPreservesConversions()
    {
        var fixture = new Fixture(64, 64);
        fixture.Cache(64, 64);
        fixture.GetView(false);
        Assert.That(fixture.Contains(64, 64), Is.True);
    }

    [TestCase(0, 64)]
    [TestCase(128, 64)]
    public void WritableAdjacentViewPreservesConversion(int offset, int size)
    {
        var fixture = new Fixture(offset, size);
        fixture.Cache(64, 64);
        fixture.GetView(true);
        Assert.That(fixture.Contains(64, 64), Is.True);
    }

    [Test]
    public void WholeBufferWriteInvalidatesAllConversionsAndCanRepeat()
    {
        var fixture = new Fixture(0, 512);
        fixture.Cache(64, 64);
        fixture.Cache(256, 64);
        fixture.GetView(true);
        Assert.That(fixture.Contains(64, 64), Is.False);
        Assert.That(fixture.Contains(256, 64), Is.False);
        fixture.Cache(256, 64);
        fixture.GetView(true);
        Assert.That(fixture.Contains(64, 64), Is.False);
        Assert.That(fixture.Contains(256, 64), Is.False);
    }

    private static Type Type(string name) => Vulkan.GetType("Ryujinx.Graphics.Vulkan." + name)!;
    private static void Set(object value, string field, object data) => value.GetType().GetField(field, Fields)!.SetValue(value, data);
}
