using System.Text;
using System.Security.Cryptography;

namespace Ryujinx.Nsz;

public sealed class NszConverter
{
    private sealed record EntryPlan(Pfs0Entry Source, string Name, long Size, NczLayout? Layout);
    private static List<EntryPlan> Plan(Stream input, NszLimits limits, CancellationToken cancellation)
    {
        var plans = new List<EntryPlan>();
        try
        {
            cancellation.ThrowIfCancellationRequested();
            foreach (var entry in Pfs0Directory.Read(input, limits))
            {
                cancellation.ThrowIfCancellationRequested();
                if (entry.Name.EndsWith(".ncz", StringComparison.OrdinalIgnoreCase))
                {
                    var slice = new BoundedReadStream(input, entry.Offset, entry.Size);
                    var layout = NczLayout.Parse(slice, limits, cancellation);
                    plans.Add(new EntryPlan(entry, entry.Name[..^4] + ".nca", layout.OutputSize, layout));
                }
                else plans.Add(new EntryPlan(entry, entry.Name, entry.Size, null));
            }
            return plans;
        }
        catch (Exception error) {
            foreach (var p in plans) p.Layout?.Dispose();
            if (error is EndOfStreamException or OverflowException or DecoderFallbackException)
                throw new InvalidDataException("Invalid or truncated container directory.");
            throw;
        }
    }
    private static long HeaderSize(List<EntryPlan> entries) => checked(16L + entries.Count * 24L + entries.Sum(e => Encoding.UTF8.GetByteCount(e.Name) + 1L));
    public static long EstimateOutputSize(Stream input, NszLimits limits, CancellationToken cancellation = default)
    {
        var entries = Plan(input, limits, cancellation);
        try { return checked(HeaderSize(entries) + entries.Sum(e => e.Size)); }
        finally { foreach (var e in entries) e.Layout?.Dispose(); }
    }
    public static ConversionReport Convert(Stream input, Stream output, NszLimits limits,
        CancellationToken cancellation, Action<ConversionProgress> progress)
    {
        var entries = Plan(input, limits, cancellation);
        try
        {
            long total = checked(HeaderSize(entries) + entries.Sum(e => e.Size));
            long done = HeaderSize(entries);
            using var writer = new BinaryWriter(output, Encoding.UTF8, true);
            writer.Write("PFS0"u8); writer.Write(entries.Count);
            writer.Write(checked((int)(done - 16L - entries.Count * 24L))); writer.Write(0);
            long offset = 0; int stringOffset = 0;
            foreach (var e in entries)
            {
                writer.Write(offset); writer.Write(e.Size); writer.Write(stringOffset); writer.Write(0);
                offset = checked(offset + e.Size); stringOffset += Encoding.UTF8.GetByteCount(e.Name) + 1;
            }
            foreach (var e in entries) { writer.Write(Encoding.UTF8.GetBytes(e.Name)); writer.Write((byte)0); }
            var hashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            byte[] buffer = new byte[1 << 20];
            foreach (var e in entries)
            {
                cancellation.ThrowIfCancellationRequested();
                var slice = new BoundedReadStream(input, e.Source.Offset, e.Source.Size);
                if (e.Layout != null)
                {
                    string hash = NczDecoder.Decode(slice, output, e.Layout, limits, cancellation,
                        count => { done += count; progress(new(done, total, "converting")); });
                    ValidateHash(e.Name, hash);
                    hashes.Add(e.Name, hash);
                }
                else
                {
                    using var hash = e.Name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase) ? IncrementalHash.CreateHash(HashAlgorithmName.SHA256) : null;
                    long left = e.Size;
                    while (left > 0)
                    {
                        cancellation.ThrowIfCancellationRequested();
                        int count = (int)Math.Min(left, buffer.Length); slice.ReadExactly(buffer.AsSpan(0, count));
                        output.Write(buffer, 0, count); hash?.AppendData(buffer, 0, count);
                        left -= count; done += count; progress(new(done, total, "converting"));
                    }
                    if (hash != null) {
                        string digest = System.Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
                        ValidateHash(e.Name, digest); hashes.Add(e.Name, digest);
                    }
                }
            }
            cancellation.ThrowIfCancellationRequested();
            if (done != total) throw new InvalidDataException("Reconstructed container length mismatch.");
            return new ConversionReport(done, hashes);
        }
        catch (EndOfStreamException) { throw new InvalidDataException("Compressed input is truncated."); }
        catch (OverflowException) { throw new InvalidDataException("Input exceeds supported length limits."); }
        finally { foreach (var e in entries) e.Layout?.Dispose(); }
    }
    private static void ValidateHash(string name, string hash)
    {
        string id = name.Split('.')[0];
        if (id.Length != 32 || !id.All(Uri.IsHexDigit) || !hash.StartsWith(id, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("NCA content hash does not match its content ID.");
    }
}
