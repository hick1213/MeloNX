using NUnit.Framework;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.Translation;
using Ryujinx.Graphics.Shader.Translation.Optimizations;

namespace Ryujinx.SaveSync.Tests;

public class BindlessPhiTests
{
    private sealed class Accessor : IGpuAccessor
    {
        public readonly List<string> Messages = [];
        public bool SeparateSampler = true;
        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => [];
        public SetBindingPair CreateConstantBufferBinding(int index) => new(0, index);
        public SetBindingPair CreateImageBinding(int count, bool isBuffer) => new(2, 0);
        public SetBindingPair CreateStorageBufferBinding(int index) => new(1, index);
        public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => new(3, 7);
        public bool QueryHostSupportsSeparateSampler() => SeparateSampler;
        public int QuerySamplerArrayLengthFromPool() => 16;
        public int QueryTextureArrayLengthFromPool() => 16;
        public int QueryTextureArrayLengthFromBuffer(int slot) => 16;
        public void Log(string message) => Messages.Add(message);
    }

    private static Operand Combined(int samplerOffset = 346)
    {
        var handle = new Operand(OperandType.LocalVariable);
        _ = new Operation(Instruction.BitwiseOr, handle, new Operand(2, 94), new Operand(2, samplerOffset));
        return handle;
    }

    private static Operand Merge(params Operand[] sources)
    {
        var handle = new Operand(OperandType.LocalVariable);
        var phi = new PhiNode(handle);
        for (int i = 0; i < sources.Length; i++) phi.AddSource(new BasicBlock(i), sources[i]);
        return handle;
    }

    private static (BasicBlock Block, TextureOperation Sample, Operand Dest, Accessor Gpu, ResourceManager Resources) Run(Operand handle, bool separateSampler = true)
    {
        var block = new BasicBlock(0);
        var dest = new Operand(OperandType.LocalVariable);
        var sample = new TextureOperation(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown,
            TextureFlags.Bindless, 0, 0, 0, [dest], [handle, OperandHelper.Const(0), OperandHelper.Const(0)]);
        block.Append(sample);
        var gpu = new Accessor { SeparateSampler = separateSampler };
        var resources = new ResourceManager(ShaderStage.Compute, gpu);
        BindlessToArray.RunPass(block, resources, gpu);
        BindlessElimination.RunPass(block, resources, gpu);
        return (block, sample, dest, gpu, resources);
    }

    [Test]
    public void CapturedNestedPhiPreservesTextureSampleAndStaticBinding()
    {
        var handle = Merge(Merge(Merge(Combined(), Combined()), Combined()), Combined());
        var result = Run(handle);
        Assert.That(result.Block.Operations.Contains(result.Sample), Is.True);
        Assert.That(result.Sample.Flags & TextureFlags.Bindless, Is.EqualTo(TextureFlags.None));
        Assert.That(result.Sample.Binding, Is.EqualTo(7));
        Assert.That(result.Sample.SourcesCount, Is.EqualTo(2));
        Assert.That(result.Dest.AsgOp, Is.SameAs(result.Sample));
        Assert.That(result.Gpu.Messages, Is.Empty);
        var descriptor = result.Resources.GetTextureDescriptors().Single();
        Assert.That(descriptor.CbufSlot, Is.EqualTo(TextureHandle.PackSlots(2, 2)));
        Assert.That(descriptor.HandleIndex, Is.EqualTo(TextureHandle.PackOffsets(94, 346, TextureHandleType.SeparateSamplerHandle)));
    }

    [Test]
    public void DifferentNestedIncomingHandleStillFailsClosed()
    {
        var result = Run(Merge(Merge(Combined(), Combined(347)), Combined()));
        Assert.That(result.Block.Operations.Contains(result.Sample), Is.False);
        Assert.That(result.Dest.AsgOp, Is.TypeOf<Operation>());
        Assert.That(((Operation)result.Dest.AsgOp).GetSource(0).Value, Is.Zero);
        Assert.That(result.Gpu.Messages.Any(x => x.Contains("Failed to find handle source")), Is.True);
    }

    [Test]
    public void CyclicPhiWithoutConcreteHandleFailsClosed()
    {
        var handle = new Operand(OperandType.LocalVariable);
        var phi = new PhiNode(handle);
        phi.AddSource(new BasicBlock(0), handle);
        var result = Run(handle, separateSampler: false);
        Assert.That(result.Block.Operations.Contains(result.Sample), Is.False);
    }

    [Test]
    public void SharedPhiDagPreservesSampling()
    {
        var shared = Merge(Combined(), Combined());
        var result = Run(Merge(Merge(shared, Combined()), Merge(shared, Combined())));
        Assert.That(result.Block.Operations.Contains(result.Sample), Is.True);
        Assert.That(result.Gpu.Messages, Is.Empty);
    }

    [Test]
    public void DirectAndSinglePhiRemainSupported()
    {
        foreach (var handle in new[] { Combined(), Merge(Combined(), Combined()) })
        {
            var result = Run(handle);
            Assert.That(result.Block.Operations.Contains(result.Sample), Is.True);
            Assert.That(result.Gpu.Messages, Is.Empty);
        }
    }

    [Test]
    public void EmptyPhiAndUnsupportedLeafFailClosed()
    {
        var differentSlot = new Operand(OperandType.LocalVariable);
        _ = new Operation(Instruction.BitwiseOr, differentSlot, new Operand(3, 94), new Operand(2, 346));
        var differentInstruction = new Operand(OperandType.LocalVariable);
        _ = new Operation(Instruction.BitwiseAnd, differentInstruction, new Operand(2, 94), new Operand(2, 346));
        foreach (var handle in new[] { Merge(), Merge(Combined(), Merge(new Operand(OperandType.Undefined), new Operand(OperandType.Undefined))),
            Merge(Combined(), differentSlot), Merge(Combined(), differentInstruction) })
        {
            var result = Run(handle, separateSampler: false);
            Assert.That(result.Block.Operations.Contains(result.Sample), Is.False);
        }
    }

    [Test]
    public void ExcessivePhiDepthFailsClosedWithoutStackOverflow()
    {
        var handle = Combined();
        for (int i = 0; i < 1000; i++) handle = Merge(handle, Combined());
        var result = Run(handle, separateSampler: false);
        Assert.That(result.Block.Operations.Contains(result.Sample), Is.False);
    }

    [Test]
    public void TwoNodePhiCycleWithHandleStillFailsClosed()
    {
        var a = new Operand(OperandType.LocalVariable);
        var b = new Operand(OperandType.LocalVariable);
        var aPhi = new PhiNode(a);
        var bPhi = new PhiNode(b);
        aPhi.AddSource(new BasicBlock(0), b);
        aPhi.AddSource(new BasicBlock(1), Combined());
        bPhi.AddSource(new BasicBlock(2), a);
        bPhi.AddSource(new BasicBlock(3), Combined());
        var result = Run(a, separateSampler: false);
        Assert.That(result.Block.Operations.Contains(result.Sample), Is.False);
    }
}
