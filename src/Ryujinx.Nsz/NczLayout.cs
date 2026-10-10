using System.Security.Cryptography;
using System.Text;

namespace Ryujinx.Nsz;

internal sealed record NczSection(long Offset, long Size, ulong CryptoType, byte[] Key, byte[] Counter);
internal sealed record NczBlockInfo(int Exponent, int Count, long TableOffset, long DataOffset);
internal sealed record NczLayout(IReadOnlyList<NczSection> Sections, long PayloadSize,
    long PayloadOffset, NczBlockInfo? Blocks) : IDisposable
{
    public long OutputSize => checked(0x4000 + PayloadSize);
    public static NczLayout Parse(Stream entry, NszLimits limits, CancellationToken cancellation)
    {
        if (entry.Length < 0x4000 + 16 + 64) throw new InvalidDataException("Truncated NCZ header.");
        entry.Position = 0x4000;
        using var reader = new BinaryReader(entry, Encoding.UTF8, true);
        if (!Pfs0Directory.ReadBytes(reader, 8).AsSpan().SequenceEqual("NCZSECTN"u8)) throw new InvalidDataException("Missing NCZ sections.");
        long count = Pfs0Directory.ReadLength(reader);
        if (count == 0 || count > limits.MaxSections || count > (entry.Length - entry.Position) / 64)
            throw new InvalidDataException("Invalid NCZ section count.");
        var sections = new List<NczSection>();
        long previousEnd = 0x4000;
        try
        {
            for (int i = 0; i < count; i++)
            {
                cancellation.ThrowIfCancellationRequested();
                long offset = Pfs0Directory.ReadLength(reader), size = Pfs0Directory.ReadLength(reader);
                ulong crypto = reader.ReadUInt64(); reader.ReadUInt64();
                byte[] key = Pfs0Directory.ReadBytes(reader, 16), counter = Pfs0Directory.ReadBytes(reader, 16);
                if (size == 0 || size > long.MaxValue - offset || crypto > 4) throw new InvalidDataException("Invalid NCZ section.");
                long end = offset + size;
                if (i == 0 && offset > 0x4000)
                    sections.Add(new NczSection(0x4000, offset - 0x4000, 1, new byte[16], new byte[16]));
                long normalizedOffset = Math.Max(offset, 0x4000);
                if (i != 0 && offset != previousEnd) throw new InvalidDataException("NCZ sections must be contiguous.");
                if (end <= normalizedOffset) throw new InvalidDataException("NCZ section contains no payload.");
                sections.Add(new NczSection(normalizedOffset, end - normalizedOffset, crypto, key, counter));
                previousEnd = end;
            }
            long payloadSize = sections.Sum(s => checked(s.Size));
            long payloadOffset = entry.Position;
            NczBlockInfo? blocks = null;
            byte[] magic = reader.ReadBytes(8);
            entry.Position = payloadOffset;
            if (magic.AsSpan().SequenceEqual("NCZBLOCK"u8))
            {
                entry.Position += 8;
                byte version = reader.ReadByte(), type = reader.ReadByte(), reserved = reader.ReadByte(), exponent = reader.ReadByte();
                uint blockCount = reader.ReadUInt32(); long declaredSize = Pfs0Directory.ReadLength(reader);
                if (version != 2 || type != 1 || reserved != 0 || exponent < 14 || exponent > limits.MaxBlockExponent)
                    throw new InvalidDataException("Unsupported NCZ block header or resource requirement.");
                long blockSize = 1L << exponent;
                long expectedCount = payloadSize / blockSize + (payloadSize % blockSize == 0 ? 0 : 1);
                long table = entry.Position;
                if (declaredSize != payloadSize || blockCount != expectedCount || blockCount > limits.MaxBlocks || blockCount > (entry.Length - table) / 4)
                    throw new InvalidDataException("Inconsistent NCZ block directory.");
                long storedTotal = 0;
                for (int i = 0; i < blockCount; i++)
                {
                    cancellation.ThrowIfCancellationRequested();
                    uint stored = reader.ReadUInt32(); long expected = Math.Min(blockSize, payloadSize - i * blockSize);
                    if (stored == 0 || stored > expected) throw new InvalidDataException("Invalid NCZ stored block length.");
                    storedTotal = checked(storedTotal + stored);
                }
                long dataOffset = entry.Position;
                if (storedTotal != entry.Length - dataOffset) throw new InvalidDataException("NCZ block data has invalid boundaries.");
                blocks = new NczBlockInfo(exponent, checked((int)blockCount), table, dataOffset);
                payloadOffset = dataOffset;
            }
            if (payloadSize <= 0 || payloadOffset >= entry.Length) throw new InvalidDataException("NCZ has no payload.");
            return new NczLayout(sections, payloadSize, payloadOffset, blocks);
        }
        catch { foreach (var s in sections) { CryptographicOperations.ZeroMemory(s.Key); CryptographicOperations.ZeroMemory(s.Counter); } throw; }
    }
    public void Dispose()
    {
        foreach (var s in Sections) { CryptographicOperations.ZeroMemory(s.Key); CryptographicOperations.ZeroMemory(s.Counter); }
    }
}
