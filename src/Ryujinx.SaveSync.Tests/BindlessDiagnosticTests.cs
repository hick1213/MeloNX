using NUnit.Framework;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.Translation.Optimizations;
namespace Ryujinx.SaveSync.Tests;
public class BindlessDiagnosticTests {
    [Test] public void DiagnosticKeepsHandleStorageAndCombinationProvenance() {
        var loaded = new Operand(OperandType.LocalVariable);
        _ = new Operation(Instruction.Load, StorageKind.StorageBuffer, loaded, new Operand(OperandType.Constant, 2), new Operand(OperandType.Constant, 16));
        var handle = new Operand(OperandType.LocalVariable);
        _ = new Operation(Instruction.BitwiseOr, handle, loaded, new Operand(3, 12));
        var text = BindlessHandleDiagnostic.Describe(handle);
        Assert.That(text, Does.Contain("BitwiseOr")); Assert.That(text, Does.Contain("Load/StorageBuffer"));
        Assert.That(text, Does.Contain("cbuf[3:12]"));
    }
    [Test] public void CyclicPhiCannotCauseRecursiveLoggingOrMutation() {
        var handle = new Operand(OperandType.LocalVariable); var phi = new PhiNode(handle);
        phi.AddSource(new BasicBlock(0), handle);
        var text = BindlessHandleDiagnostic.Describe(handle);
        Assert.That(text, Does.Contain("seen")); Assert.That(handle.AsgOp, Is.SameAs(phi));
    }
    [Test] public void VeryLargeTreeIsBounded() {
        var handle = new Operand(OperandType.Constant, 1);
        for (int i = 0; i < 1000; i++) {
            var next = new Operand(OperandType.LocalVariable); _ = new Operation(Instruction.BitwiseOr, next, handle, handle); handle = next;
        }
        Assert.That(BindlessHandleDiagnostic.Describe(handle).Length, Is.LessThanOrEqualTo(2048));
    }
}
