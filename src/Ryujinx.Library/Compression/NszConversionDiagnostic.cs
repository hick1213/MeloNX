#if MELONX_IMPORT_DIAGNOSTICS
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Ryujinx.Common.Configuration;
using Ryujinx.Nsz;

namespace Ryujinx.Library.Compression;

// Debug QA only. This never replaces the production package validator or publishes to a game directory.
internal static class NszConversionDiagnostic
{
    internal sealed record Proof(long BytesWritten, string Sha256, bool CancellationVerified, bool SpaceFailureVerified);
    internal static Proof RunProof(string source, string output)
    {
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (input.Length > 2 * 1024 * 1024 || NszConverter.EstimateOutputSize(input, new()) > 2 * 1024 * 1024)
            throw new InvalidDataException("QA vectors exceed the diagnostic limit.");
        input.Position = 0; byte[] before = SHA256.HashData(input); input.Position = 0;
        ConversionReport report;
        using (var result = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            report = NszConverter.Convert(input, result, new(), CancellationToken.None, _ => { });
        string hash;
        using (var result = File.OpenRead(output)) hash = Convert.ToHexString(SHA256.HashData(result)).ToLowerInvariant();
        string qaRoot = Path.GetDirectoryName(output)!;
        using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
        var validator = new BarrierValidator(entered, release);
        using var cancelledJob = new NszImportJob(new(Guid.NewGuid(), source, qaRoot, "cancel-never-committed.nsp", NszPackageKind.Application, 0x100), validator, new(), () => long.MaxValue);
        var run = Task.Run(cancelledJob.Run);
        if (!entered.Wait(5000))
        {
            release.Set(); try { run.GetAwaiter().GetResult(); } catch { }
            throw new IOException("QA validation barrier did not start.");
        }
        cancelledJob.Cancel(); bool heldUntilEnd = !cancelledJob.HasEnded; release.Set();
        bool cancelled = false;
        try { run.GetAwaiter().GetResult(); } catch (OperationCanceledException) { cancelled = true; }
        cancelled &= heldUntilEnd && cancelledJob.HasEnded && cancelledJob.CommittedPath == null;
        using var quotaJob = new NszImportJob(new(Guid.NewGuid(), source, qaRoot, "quota-never-committed.nsp", NszPackageKind.Application, 0x100), validator, new(), () => 0);
        bool quota = false;
        try { quotaJob.Run(); } catch (NszImportException error) when (error.Code == NszImportError.InsufficientSpace) { quota = true; }
        input.Position = 0;
        if (!SHA256.HashData(input).AsSpan().SequenceEqual(before) || !cancelled || !quota)
            throw new InvalidDataException("QA preservation or cancellation failed.");
        return new(report.BytesWritten, hash, cancelled, quota);
    }
    private sealed class BarrierValidator(ManualResetEventSlim entered, ManualResetEventSlim release) : INszPackageValidator
    {
        public NszPackage Validate(string path, CancellationToken cancellation)
        {
            entered.Set(); if (!release.Wait(5000)) throw new IOException("QA barrier timeout.");
            cancellation.ThrowIfCancellationRequested();
            throw new InvalidDataException("Generated QA headers must never be published as games.");
        }
    }
    [UnmanagedCallersOnly(EntryPoint = "nsz_conversion_probe")]
    public static unsafe nint Probe(byte* sourceValue, byte* outputValue)
    {
        try
        {
            string source = Path.GetFullPath(ReadPath(sourceValue)), output = Path.GetFullPath(ReadPath(outputValue));
            string root = Path.Combine(AppDataManager.BaseDirPath, "Downloads", "NSZImportQA") + Path.DirectorySeparatorChar;
            if (!source.StartsWith(root, StringComparison.Ordinal) || !output.StartsWith(root, StringComparison.Ordinal) ||
                Path.GetDirectoryName(source) != Path.GetDirectoryName(output) || !source.EndsWith(".nsz", StringComparison.Ordinal) || !output.EndsWith(".nsp", StringComparison.Ordinal))
                throw new ArgumentException();
            var proof = RunProof(source, output);
            using var bytes = new MemoryStream();
            using (var json = new Utf8JsonWriter(bytes))
            {
                json.WriteStartObject(); json.WriteNumber("version", 1); json.WriteBoolean("passed", true);
                json.WriteNumber("bytes", proof.BytesWritten); json.WriteString("sha256", proof.Sha256);
                json.WriteBoolean("cancellationVerified", proof.CancellationVerified); json.WriteBoolean("spaceFailureVerified", proof.SpaceFailureVerified); json.WriteEndObject();
            }
            return NszUtf8Buffers.Allocate(Encoding.UTF8.GetString(bytes.ToArray()));
        }
        catch { return NszUtf8Buffers.Allocate("{\"version\":1,\"passed\":false,\"error\":\"conversion_probe_failed\"}"); }
    }
    private static unsafe string ReadPath(byte* value)
    {
        if (value == null) throw new ArgumentException();
        int count = 0; while (count <= 4096 && value[count] != 0) count++;
        if (count > 4096) throw new ArgumentException();
        return new UTF8Encoding(false, true).GetString(new ReadOnlySpan<byte>(value, count));
    }
}
#endif
