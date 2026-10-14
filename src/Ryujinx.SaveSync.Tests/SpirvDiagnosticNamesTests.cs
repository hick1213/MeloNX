using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using NUnit.Framework;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Vulkan;

namespace Ryujinx.SaveSync.Tests;

[NonParallelizable]
public class SpirvDiagnosticNamesTests
{
    private static readonly Assembly Vulkan = typeof(VulkanRenderer).Assembly;
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

    // A complete compute module: one input interface, a main OpName, and an empty function.
    private static byte[] Module() => Bytes([
        0x07230203, 0x00010000, 0, 9, 0,
        0x00020011, 1,
        0x0003000e, 0, 1,
        0x0006000f, 5, 7, 0x6e69616d, 0, 6,
        0x00060010, 7, 17, 1, 1, 1,
        0x00040005, 7, 0x6e69616d, 0,
        0x00040047, 6, 11, 28,
        0x00020013, 1,
        0x00030021, 2, 1,
        0x00040015, 3, 32, 0,
        0x00040017, 4, 3, 3,
        0x00040020, 5, 1, 4,
        0x0004003b, 5, 6, 1,
        0x00050036, 1, 7, 0, 2,
        0x000200f8, 8,
        0x000100fd,
        0x00010038]);

    [Test]
    public void RenameIsStableAndPreservesEveryNonNameWord()
    {
        byte[] original = Module();
        byte[] before = original.ToArray();
        var (success, renamed, name) = Rename(original, ShaderStage.Compute);
        Assert.That(success, Is.True);
        Assert.That(name, Is.EqualTo("mnx_" + Convert.ToHexString(SHA256.HashData(original)).ToLowerInvariant()));
        Assert.That(original, Is.EqualTo(before), "Do not mutate shared or cached source binaries.");
        Assert.That(renamed, Is.Not.SameAs(original));
        Assert.That(Rename(original, ShaderStage.Compute).name, Is.EqualTo(name));
        // Entry starts at word 10; its ID/model and final interface word must survive.
        Assert.That(renamed[..40], Is.EqualTo(before[..40]));
        Assert.That(renamed[44..52], Is.EqualTo(before[44..52]));
        int nameBytes = (name.Length + 1 + 3) & ~3;
        Assert.That(Encoding.ASCII.GetString(renamed, 52, name.Length), Is.EqualTo(name));
        Assert.That(renamed[(52 + name.Length)..(52 + nameBytes)], Is.All.Zero);
        Assert.That(renamed[(52 + nameBytes)..], Is.EqualTo(before[60..]), "Interfaces, OpName, IDs, and instructions must remain byte-identical.");
        Assert.That(BitConverter.ToUInt32(renamed, 40), Is.EqualTo((uint)((4 + nameBytes / 4) << 16 | 15)));
    }

    [TestCase(ShaderStage.Vertex, 0)]
    [TestCase(ShaderStage.TessellationControl, 1)]
    [TestCase(ShaderStage.TessellationEvaluation, 2)]
    [TestCase(ShaderStage.Geometry, 3)]
    [TestCase(ShaderStage.Fragment, 4)]
    [TestCase(ShaderStage.Compute, 5)]
    public void MatchesRequestedExecutionModel(ShaderStage stage, int model)
    {
        byte[] original = Module();
        Write(original, 11, (uint)model);
        Assert.That(Rename(original, stage).success, Is.True);
    }

    [Test]
    public void InvalidStageCannotMatchInvalidExecutionModel()
    {
        byte[] input = Module();
        Write(input, 11, uint.MaxValue);
        byte[] before = input.ToArray();
        var result = Rename(input, (ShaderStage)byte.MaxValue);
        Assert.That(result.success, Is.False);
        Assert.That(result.renamed, Is.Null);
        Assert.That(result.name, Is.Null);
        Assert.That(input, Is.EqualTo(before));
    }

    [Test]
    public void RejectsEntryWhoseLongerNameWouldOverflowInstructionWordCount()
    {
        byte[] module = Module();
        byte[] input = [.. module[..64], .. new byte[(65535 - 6) * 4], .. module[64..]];
        Write(input, 10, 0xffff000f);
        Assert.That(Rename(input, ShaderStage.Compute).success, Is.False);
    }

    [TestCase("short-header")]
    [TestCase("unaligned")]
    [TestCase("bad-magic")]
    [TestCase("zero-word-count")]
    [TestCase("truncated-tail")]
    [TestCase("unterminated-entry")]
    [TestCase("short-entry")]
    [TestCase("wrong-stage")]
    [TestCase("non-main")]
    [TestCase("no-entry")]
    [TestCase("multiple-entry")]
    public void RejectsAmbiguousOrMalformedWholeModuleWithoutChangingSource(string fault)
    {
        byte[] input = Module();
        switch (fault)
        {
            case "short-header": input = input[..16]; break;
            case "unaligned": input = input[..^1]; break;
            case "bad-magic": Write(input, 0, 0); break;
            case "zero-word-count": Write(input, input.Length / 4 - 1, 56); break;
            case "truncated-tail": Write(input, input.Length / 4 - 1, 0x00020038); break;
            case "unterminated-entry": Write(input, 14, 0x61616161); Write(input, 15, 0x61616161); break;
            case "short-entry": Write(input, 10, 0x0003000f); break;
            case "wrong-stage": Write(input, 11, 0); break;
            case "non-main": Write(input, 13, 0x6e696178); break;
            case "no-entry": Write(input, 10, 0x00060000); break;
            case "multiple-entry": input = [.. input, .. input[40..64]]; break;
        }
        byte[] before = input.ToArray();
        var result = Rename(input, ShaderStage.Compute);
        Assert.That(result.success, Is.False);
        Assert.That(result.renamed, Is.Null);
        Assert.That(result.name, Is.Null);
        Assert.That(input, Is.EqualTo(before));
    }

    [TestCase(null)]
    [TestCase("0")]
    [TestCase("true")]
    [TestCase("1")]
    public unsafe void ProcessOptInUsesMatchingPointerAndDisposalReleasesOnlyOwnedName(string? setting)
    {
        string? previous = Environment.GetEnvironmentVariable("MELONX_SHADER_DIAGNOSTIC_NAMES");
        Type shaderType = Vulkan.GetType("Ryujinx.Graphics.Vulkan.Shader")!;
        object shader = RuntimeHelpers.GetUninitializedObject(shaderType);
        shaderType.GetField("CompileTask")!.SetValue(shader, Task.CompletedTask);
        try
        {
            Environment.SetEnvironmentVariable("MELONX_SHADER_DIAGNOSTIC_NAMES", setting);
            MethodInfo? prepare = shaderType.GetMethod("PrepareDiagnosticSpirv", Private);
            Assert.That(prepare, Is.Not.Null, "Shader diagnostic identity path has not been implemented.");
            byte[] input = Module();
            byte[] output = (byte[])prepare!.Invoke(shader, [input, ShaderStage.Compute])!;
            var info = (PipelineShaderStageCreateInfo)shaderType.GetMethod("GetInfo")!.Invoke(shader, null)!;
            string? actualName = Marshal.PtrToStringAnsi((nint)info.PName);
            Assert.That(actualName, Is.EqualTo(setting == "1" ? Rename(input, ShaderStage.Compute).name : "main"));
            Assert.That(ReferenceEquals(input, output), Is.EqualTo(setting != "1"));
            ((IDisposable)shader).Dispose();
            Assert.That(shaderType.GetField("_ptrDiagnosticEntryPointName", Private)!.GetValue(shader), Is.EqualTo((nint)0));
            ((IDisposable)shader).Dispose();
            // The shared main pointer survives both diagnostic and ordinary shader disposal.
            object next = RuntimeHelpers.GetUninitializedObject(shaderType);
            var nextInfo = (PipelineShaderStageCreateInfo)shaderType.GetMethod("GetInfo")!.Invoke(next, null)!;
            Assert.That(Marshal.PtrToStringAnsi((nint)nextInfo.PName), Is.EqualTo("main"));
        }
        finally
        {
            ((IDisposable)shader).Dispose();
            Environment.SetEnvironmentVariable("MELONX_SHADER_DIAGNOSTIC_NAMES", previous);
        }
    }

    [TestCase(false)]
    [TestCase(true)]
    public unsafe void DiagnosticMalformedModuleFallsBackToOriginalAndMainPointer(bool invalidStage)
    {
        string? previous = Environment.GetEnvironmentVariable("MELONX_SHADER_DIAGNOSTIC_NAMES");
        Type type = Vulkan.GetType("Ryujinx.Graphics.Vulkan.Shader")!;
        object shader = RuntimeHelpers.GetUninitializedObject(type);
        type.GetField("CompileTask")!.SetValue(shader, Task.CompletedTask);
        try
        {
            Environment.SetEnvironmentVariable("MELONX_SHADER_DIAGNOSTIC_NAMES", "1");
            byte[] malformed = Module();
            Write(malformed, invalidStage ? 11 : malformed.Length / 4 - 1, invalidStage ? uint.MaxValue : 0);
            byte[] before = malformed.ToArray();
            ShaderStage stage = invalidStage ? (ShaderStage)byte.MaxValue : ShaderStage.Compute;
            var output = type.GetMethod("PrepareDiagnosticSpirv", Private)!.Invoke(shader, [malformed, stage]);
            Assert.That(output, Is.SameAs(malformed));
            Assert.That(malformed, Is.EqualTo(before));
            var info = (PipelineShaderStageCreateInfo)type.GetMethod("GetInfo")!.Invoke(shader, null)!;
            Assert.That(Marshal.PtrToStringAnsi((nint)info.PName), Is.EqualTo("main"));
            Assert.That(type.GetField("_ptrDiagnosticEntryPointName", Private)!.GetValue(shader), Is.EqualTo((nint)0));
        }
        finally
        {
            ((IDisposable)shader).Dispose();
            Environment.SetEnvironmentVariable("MELONX_SHADER_DIAGNOSTIC_NAMES", previous);
        }
    }

    private static (bool success, byte[] renamed, string name) Rename(byte[] input, ShaderStage stage)
    {
        Type? helper = Vulkan.GetType("Ryujinx.Graphics.Vulkan.SpirvDiagnosticNames");
        Assert.That(helper, Is.Not.Null, "SPIR-V diagnostic entrypoint naming has not been implemented.");
        object?[] arguments = [input, stage, null, null];
        bool result = (bool)helper!.GetMethod("TryRename", BindingFlags.Static | BindingFlags.Public)!.Invoke(null, arguments)!;
        return (result, (byte[])arguments[2]!, (string)arguments[3]!);
    }

    private static byte[] Bytes(uint[] words)
    {
        byte[] bytes = new byte[words.Length * 4];
        System.Buffer.BlockCopy(words, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    private static void Write(byte[] data, int word, uint value) => BitConverter.GetBytes(value).CopyTo(data, word * 4);
}
