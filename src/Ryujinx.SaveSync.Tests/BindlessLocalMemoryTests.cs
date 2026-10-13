using NUnit.Framework;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.Translation;
using Ryujinx.Graphics.Shader.Translation.Optimizations;

namespace Ryujinx.SaveSync.Tests;

public class BindlessLocalMemoryTests
{
    private sealed class Accessor : IGpuAccessor
    {
        public readonly List<string> Messages = [];
        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => [];
        public SetBindingPair CreateConstantBufferBinding(int index) => new(0, index);
        public SetBindingPair CreateImageBinding(int count, bool isBuffer) => new(2, 3);
        public SetBindingPair CreateStorageBufferBinding(int index) => new(1, index);
        public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => new(3, 7);
        public bool QueryHostSupportsSeparateSampler() => false;
        public int QuerySamplerArrayLengthFromPool() => 16;
        public int QueryTextureArrayLengthFromPool() => 16;
        public int QueryTextureArrayLengthFromBuffer(int slot) => 16;
        public SamplerType QuerySamplerType(int handle, int cbufSlot = -1) => SamplerType.TextureBuffer;
        public void Log(string message) => Messages.Add(message);
    }

    private sealed class Fixture(int word = 5)
    {
        public readonly BasicBlock Block = new(0);
        public readonly Accessor Gpu = new();
        public readonly Operand Handle = OperandHelper.Local();
        public readonly Operand Coord = OperandHelper.Const(123);
        public readonly Operand Value = OperandHelper.Const(456);
        public readonly int Word = word;
        public TextureOperation Image = null!;
        public ResourceManager Resources = null!;

        public void Store(Operand memory, Operand index, Operand value) =>
            Block.Append(new Operation(Instruction.Store, StorageKind.LocalMemory, null!, memory, index, value));

        public void StoreHandle(int offset = 72) => Store(OperandHelper.Const(0), OperandHelper.Const(Word), new Operand(2, offset));

        public Operation Load(Operand? memory = null, Operand? index = null, bool append = true)
        {
            var load = new Operation(Instruction.Load, StorageKind.LocalMemory, Handle,
                memory ?? OperandHelper.Const(0), index ?? OperandHelper.Const(Word));
            if (append) Block.Append(load);
            return load;
        }

        public void Run(Operand? handle = null)
        {
            Image = new TextureOperation(Instruction.ImageStore, SamplerType.TextureBuffer, TextureFormat.R32Uint,
                TextureFlags.Bindless, 0, 0, 0, [], [handle ?? Handle, Coord, Value]);
            Block.Append(Image);
            Resources = new ResourceManager(ShaderStage.Compute, Gpu);
            Resources.SetCurrentLocalMemory(128, true);
            BindlessToArray.RunPass(Block, Resources, Gpu);
            BindlessElimination.RunPass(Block, Resources, Gpu);
        }

        public void AssertPreserved(int offset = 72)
        {
            Assert.That(Block.Operations.Contains(Image), Is.True, "Keep the captured GPU write.");
            Assert.That(Image.Flags & TextureFlags.Bindless, Is.EqualTo(TextureFlags.None));
            Assert.That(Image.Binding, Is.EqualTo(3));
            Assert.That(Image.SourcesCount, Is.EqualTo(2));
            Assert.That(Image.GetSource(0), Is.SameAs(Coord));
            Assert.That(Image.GetSource(1), Is.SameAs(Value));
            var descriptor = Resources.GetImageDescriptors().Single();
            Assert.That(descriptor.CbufSlot, Is.EqualTo(2));
            Assert.That(descriptor.HandleIndex, Is.EqualTo(offset));
            Assert.That(Gpu.Messages, Is.Empty);
        }
    }

    [TestCase(1)]
    [TestCase(2)]
    [TestCase(5)]
    [TestCase(7)]
    public void CapturedSameBlockStaticHandleSpillPreservesImageStore(int word)
    {
        var f = new Fixture(word);
        f.StoreHandle();
        f.Load();
        f.Run();
        f.AssertPreserved();
    }

    [Test]
    public void DirectImageHandleKeepsExistingBindingPath()
    {
        var f = new Fixture();
        f.Run(new Operand(2, 72));
        f.AssertPreserved();
    }

    [Test]
    public void NearestEarlierStoreWinsAndOtherSlotsDoNotAlias()
    {
        var f = new Fixture();
        f.StoreHandle(74);
        f.StoreHandle();
        f.Store(OperandHelper.Const(1), OperandHelper.Const(f.Word), new Operand(2, 80));
        f.Store(OperandHelper.Const(0), OperandHelper.Const(f.Word + 1), new Operand(2, 82));
        f.Load();
        f.Run();
        f.AssertPreserved();
    }

    [Test]
    public void LaterStoreDoesNotChangeAlreadyLoadedHandle()
    {
        var f = new Fixture();
        f.StoreHandle();
        f.Load();
        f.StoreHandle(74);
        f.Run();
        f.AssertPreserved();
    }

    [TestCase("no-store")]
    [TestCase("dynamic-store-index")]
    [TestCase("dynamic-store-memory")]
    [TestCase("opaque-overwrite")]
    [TestCase("call")]
    [TestCase("store-after-load")]
    [TestCase("other-block-load")]
    [TestCase("dynamic-load-index")]
    [TestCase("dynamic-load-memory")]
    [TestCase("scan-limit")]
    public void UnprovenOrAliasedSpillsRemainUnsupported(string kind)
    {
        var f = new Fixture();
        if (kind != "no-store" && kind != "store-after-load") f.StoreHandle();
        switch (kind)
        {
            case "dynamic-store-index": f.Store(OperandHelper.Const(0), OperandHelper.Local(), new Operand(2, 74)); break;
            case "dynamic-store-memory": f.Store(OperandHelper.Local(), OperandHelper.Const(f.Word), new Operand(2, 74)); break;
            case "opaque-overwrite": f.Store(OperandHelper.Const(0), OperandHelper.Const(f.Word), OperandHelper.Local()); break;
            case "call": f.Block.Append(new Operation(Instruction.Call, null!, OperandHelper.Const(1))); break;
            case "scan-limit":
                for (int i = 0; i < 1024; i++) f.Block.Append(new Operation(Instruction.Copy, OperandHelper.Local(), OperandHelper.Const(i)));
                break;
        }
        if (kind == "other-block-load") new BasicBlock(1).Append(f.Load(append: false));
        else f.Load(memory: kind == "dynamic-load-memory" ? OperandHelper.Local() : null,
            index: kind == "dynamic-load-index" ? OperandHelper.Local() : null);
        if (kind == "store-after-load") f.StoreHandle();
        f.Run();
        Assert.That(f.Block.Operations.Contains(f.Image), Is.False);
        Assert.That(f.Resources.GetImageDescriptors(), Is.Empty);
        Assert.That(f.Gpu.Messages.Any(x => x.Contains("Failed to find handle source")), Is.True);
    }
}
