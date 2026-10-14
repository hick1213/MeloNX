using Ryujinx.Graphics.Shader;
using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Ryujinx.Graphics.Vulkan
{
    // Diagnostic identity only: keep IDs, interfaces, debug names, and all executable instructions unchanged.
    static class SpirvDiagnosticNames
    {
        public static bool TryRename(byte[] original, ShaderStage stage, out byte[] renamed, out string name)
        {
            renamed = null;
            name = null;

            if (!BitConverter.IsLittleEndian || original.Length < 20 || (original.Length & 3) != 0)
            {
                return false;
            }

            ReadOnlySpan<uint> words = MemoryMarshal.Cast<byte, uint>(original);
            if (words[0] != 0x07230203 || words[3] == 0 || words[4] != 0)
            {
                return false;
            }

            uint model = stage switch
            {
                ShaderStage.Vertex => 0,
                ShaderStage.TessellationControl => 1,
                ShaderStage.TessellationEvaluation => 2,
                ShaderStage.Geometry => 3,
                ShaderStage.Fragment => 4,
                ShaderStage.Compute => 5,
                _ => uint.MaxValue,
            };

            if (model == uint.MaxValue)
            {
                return false;
            }

            int entry = -1;
            int nameWords = 0;
            for (int offset = 5; offset < words.Length;)
            {
                int count = (int)(words[offset] >> 16);
                if (count == 0 || count > words.Length - offset)
                {
                    return false;
                }

                if ((words[offset] & 0xffff) == 15) // OpEntryPoint
                {
                    if (entry != -1 || count < 5 || words[offset + 1] != model)
                    {
                        return false;
                    }

                    ReadOnlySpan<byte> entryName = original.AsSpan((offset + 3) * 4, (count - 3) * 4);
                    int length = entryName.IndexOf((byte)0);
                    if (length != 4 || !entryName[..4].SequenceEqual("main"u8))
                    {
                        return false;
                    }

                    nameWords = (length + 4) / 4;
                    if (entryName[length..(nameWords * 4)].IndexOfAnyExcept((byte)0) != -1)
                    {
                        return false;
                    }

                    entry = offset;
                }

                offset += count;
            }

            if (entry == -1)
            {
                return false;
            }

            const int newNameWords = (4 + 64 + 4) / 4; // mnx_, full SHA-256, terminator and padding.
            int delta = newNameWords - nameWords;
            if ((words[entry] >> 16) + delta > ushort.MaxValue)
            {
                return false;
            }

            name = "mnx_" + Convert.ToHexString(SHA256.HashData(original)).ToLowerInvariant();
            renamed = new byte[original.Length + delta * 4];
            int nameOffset = (entry + 3) * 4;
            original.AsSpan(0, nameOffset).CopyTo(renamed);
            Encoding.ASCII.GetBytes(name, renamed.AsSpan(nameOffset));
            original.AsSpan(nameOffset + nameWords * 4).CopyTo(renamed.AsSpan(nameOffset + newNameWords * 4));
            Span<uint> renamedWords = MemoryMarshal.Cast<byte, uint>(renamed.AsSpan());
            renamedWords[entry] = (uint)(((words[entry] >> 16) + delta) << 16) | 15;
            return true;
        }
    }
}
