using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using System.Collections.Generic;
using System.Text;

namespace Ryujinx.Graphics.Shader.Translation.Optimizations
{
    // Failure-only description of IR metadata, never buffer contents. Limits
    // prevent cyclic phi graphs or large expressions from flooding game logs.
    static class BindlessHandleDiagnostic
    {
        public static string Describe(Operand handle)
        {
            var text = new StringBuilder();
            var seen = new HashSet<Operand>();
            int budget = 24;
            Append(handle, 0);
            return text.Length <= 2048 ? text.ToString() : text.ToString(0, 2048);

            void Append(Operand value, int depth)
            {
                if (value == null) { text.Append("null"); return; }
                if (depth >= 5 || budget-- <= 0 || text.Length >= 1800) { text.Append("..."); return; }
                if (!seen.Add(value)) { text.Append("seen"); return; }
                if (value.Type == OperandType.ConstantBuffer)
                {
                    text.Append($"cbuf[{value.GetCbufSlot()}:{value.GetCbufOffset()}]");
                    return;
                }
                text.Append(value.Type);
                if (value.Type == OperandType.Constant) { text.Append($"(0x{value.Value:x8})"); return; }
                INode source = value.AsgOp;
                if (source == null) { text.Append("(unassigned)"); return; }
                if (source is Operation op) text.Append($":{op.Inst}/{op.StorageKind}");
                else if (source is PhiNode) text.Append(":Phi");
                else { text.Append(":other"); return; }
                text.Append('(');
                for (int index = 0; index < source.SourcesCount; index++)
                {
                    if (index > 0) text.Append(',');
                    if (budget <= 0 || text.Length >= 1800) { text.Append("..."); break; }
                    Append(source.GetSource(index), depth + 1);
                }
                text.Append(')');
            }
        }
    }
}
