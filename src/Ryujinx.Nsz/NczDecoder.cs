using System.Security.Cryptography;

namespace Ryujinx.Nsz;

internal static class NczDecoder
{
    public static string Decode(Stream entry, Stream output, NczLayout layout, NszLimits limits,
        CancellationToken cancellation, Action<int> advanced)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[1 << 20];
        entry.Position = 0; entry.ReadExactly(buffer.AsSpan(0, 0x4000));
        cancellation.ThrowIfCancellationRequested();
        output.Write(buffer, 0, 0x4000); hash.AppendData(buffer, 0, 0x4000); advanced(0x4000);
        using var payload = new NczPayloadStream(entry, layout, limits, cancellation);
        foreach (var section in layout.Sections)
        {
            using var crypto = section.CryptoType is 3 or 4 ? new AesCtrTransform(section.Key, section.Counter) : null;
            long done = 0;
            while (done < section.Size)
            {
                cancellation.ThrowIfCancellationRequested();
                int count = (int)Math.Min(buffer.Length, section.Size - done);
                payload.ReadExactly(buffer.AsSpan(0, count));
                crypto?.Apply(buffer.AsSpan(0, count), section.Offset + done);
                output.Write(buffer, 0, count); hash.AppendData(buffer, 0, count); done += count; advanced(count);
            }
        }
        if (payload.ReadByte() != -1) throw new InvalidDataException("NCZ payload produced excessive output.");
        return System.Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }
}
