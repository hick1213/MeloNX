using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using ZstdSharp;

namespace Ryujinx.Nsz.Tests;

// Generated format vectors only: these headers are deliberately not valid games.
internal static class NszFixtures
{
    public sealed record Fixture(byte[] Nsz, byte[] ExpectedNsp, byte[] Ncz, byte[] OriginalNca, string NcaName);
    public static readonly byte[] Key = Convert.FromHexString("000102030405060708090a0b0c0d0e0f");
    public static readonly byte[] Nonce = Convert.FromHexString("10111213141516170000000000000000");

    public static Fixture Build(int firstOffset = 0x4000, bool blocked = false,
        bool rawLastBlock = false, bool exactMultiple = false, ulong cryptoType = 3, bool multipleSections = false)
    {
        int payloadSize = 0x20000 + (exactMultiple ? 0 : 37);
        byte[] plain = Enumerable.Range(0, 0x4000 + payloadSize).Select(i => (byte)(i % 251)).ToArray();
        byte[] original = plain.ToArray();
        var sections = multipleSections
            ? new[] { (Offset: firstOffset, Size: 0x18000 - firstOffset, Crypto: cryptoType), (Offset: 0x18000, Size: plain.Length - 0x18000, Crypto: 1UL) }
            : new[] { (Offset: firstOffset, Size: plain.Length - firstOffset, Crypto: cryptoType) };
        foreach (var section in sections)
        {
            int normalizedStart = Math.Max(section.Offset, 0x4000);
            int length = section.Offset + section.Size - normalizedStart;
            if (section.Crypto is 3 or 4)
                ReferenceCrypt(plain.AsSpan(normalizedStart, length), original.AsSpan(normalizedStart, length), Key, Nonce, normalizedStart);
        }
        string name = Convert.ToHexString(SHA256.HashData(original)).ToLowerInvariant()[..32];
        using var ncz = new MemoryStream();
        using var writer = new BinaryWriter(ncz, Encoding.UTF8, true);
        writer.Write(original, 0, 0x4000);
        writer.Write(Encoding.ASCII.GetBytes("NCZSECTN")); writer.Write((ulong)sections.Length);
        foreach (var section in sections)
        {
            writer.Write((ulong)section.Offset); writer.Write((ulong)section.Size);
            writer.Write(section.Crypto); writer.Write(0UL); writer.Write(Key); writer.Write(Nonce);
        }
        byte[] payload = plain[0x4000..];
        using var compressor = new Compressor(3);
        if (!blocked) writer.Write(compressor.Wrap(payload).ToArray());
        else
        {
            const int blockSize = 1 << 14;
            int count = (payload.Length + blockSize - 1) / blockSize;
            var blocks = new List<byte[]>();
            for (int i = 0; i < count; i++)
            {
                byte[] block = payload.Skip(i * blockSize).Take(blockSize).ToArray();
                byte[] packed = compressor.Wrap(block).ToArray();
                blocks.Add((rawLastBlock && i == count - 1) || packed.Length >= block.Length ? block : packed);
            }
            writer.Write(Encoding.ASCII.GetBytes("NCZBLOCK"));
            writer.Write((byte)2); writer.Write((byte)1); writer.Write((byte)0); writer.Write((byte)14);
            writer.Write((uint)count); writer.Write((ulong)payload.Length);
            foreach (byte[] block in blocks) writer.Write((uint)block.Length);
            foreach (byte[] block in blocks) writer.Write(block);
        }
        byte[] raw = Enumerable.Range(0, 2048).Select(i => (byte)(i % 97)).ToArray();
        string rawName = Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant()[..32] + ".nca";
        var input = new[] { (name + ".ncz", ncz.ToArray()), (rawName, raw), ("ticket.tik", new byte[] {1,2,3}), ("cert.cert", new byte[] {4,5}) };
        var expected = new[] { (name + ".nca", original), (rawName, raw), ("ticket.tik", new byte[] {1,2,3}), ("cert.cert", new byte[] {4,5}) };
        return new Fixture(Pfs0(input), Pfs0(expected), ncz.ToArray(), original, name + ".nca");
    }

    public static byte[] Pfs0(params (string Name, byte[] Data)[] entries)
    {
        using var strings = new MemoryStream();
        var stringOffsets = new List<int>();
        foreach (var e in entries)
        {
            stringOffsets.Add((int)strings.Position);
            strings.Write(Encoding.UTF8.GetBytes(e.Name)); strings.WriteByte(0);
        }
        using var result = new MemoryStream(); using var writer = new BinaryWriter(result, Encoding.UTF8, true);
        writer.Write(Encoding.ASCII.GetBytes("PFS0")); writer.Write(entries.Length);
        writer.Write((int)strings.Length); writer.Write(0);
        long offset = 0;
        for (int i = 0; i < entries.Length; i++)
        {
            writer.Write(offset); writer.Write((long)entries[i].Data.Length);
            writer.Write(stringOffsets[i]); writer.Write(0); offset += entries[i].Data.Length;
        }
        writer.Write(strings.ToArray());
        foreach (var e in entries) writer.Write(e.Data);
        return result.ToArray();
    }

    // Byte-position oracle, independent of the converter's chunk transform.
    public static void ReferenceCrypt(ReadOnlySpan<byte> input, Span<byte> output,
        byte[] key, byte[] nonce, long offset)
    {
        using var aes = Aes.Create(); aes.Key = key;
        byte[] counter = new byte[16]; nonce.AsSpan(0, 8).CopyTo(counter);
        long lastBlock = -1; byte[] stream = Array.Empty<byte>();
        for (int i = 0; i < input.Length; i++)
        {
            long block = (offset + i) / 16;
            if (block != lastBlock)
            {
                BinaryPrimitives.WriteUInt64BigEndian(counter.AsSpan(8), (ulong)block);
                stream = aes.EncryptEcb(counter, PaddingMode.None); lastBlock = block;
            }
            output[i] = (byte)(input[i] ^ stream[(int)((offset + i) % 16)]);
        }
    }
}
