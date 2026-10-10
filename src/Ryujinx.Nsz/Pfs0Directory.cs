using System.Text;

namespace Ryujinx.Nsz;

internal sealed record Pfs0Entry(string Name, long Offset, long Size);
internal static class Pfs0Directory
{
    public static IReadOnlyList<Pfs0Entry> Read(Stream source, NszLimits limits)
    {
        if (!source.CanSeek || source.Length < 16) throw new InvalidDataException("NSZ must be a seekable PFS0 container.");
        source.Position = 0;
        using var reader = new BinaryReader(source, Encoding.UTF8, true);
        if (!ReadBytes(reader, 4).AsSpan().SequenceEqual("PFS0"u8)) throw new InvalidDataException("Invalid PFS0 header.");
        uint count = reader.ReadUInt32(), stringsLength = reader.ReadUInt32(); reader.ReadUInt32();
        if (count == 0 || count > limits.MaxEntries || stringsLength == 0 || stringsLength > 16 * 1024 * 1024)
            throw new InvalidDataException("PFS0 directory exceeds resource limits.");
        long dataStart = checked(16L + count * 24L + stringsLength);
        if (dataStart > source.Length) throw new InvalidDataException("Truncated PFS0 directory.");
        var raw = new (long Offset, long Size, uint Name)[count];
        for (int i = 0; i < count; i++)
        {
            raw[i] = (ReadLength(reader), ReadLength(reader), reader.ReadUInt32()); reader.ReadUInt32();
        }
        byte[] strings = ReadBytes(reader, checked((int)stringsLength));
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var entries = new List<Pfs0Entry>(raw.Length);
        foreach (var e in raw)
        {
            if (e.Name >= strings.Length || e.Offset > source.Length - dataStart || e.Size > source.Length - dataStart - e.Offset)
                throw new InvalidDataException("PFS0 entry exceeds container bounds.");
            int end = Array.IndexOf(strings, (byte)0, (int)e.Name);
            if (end < 0 || end - e.Name > 255) throw new InvalidDataException("Invalid PFS0 filename.");
            string name = new UTF8Encoding(false, true).GetString(strings, (int)e.Name, end - (int)e.Name);
            ValidateName(name);
            string normalized = name.EndsWith(".ncz", StringComparison.OrdinalIgnoreCase) ? name[..^4] + ".nca" : name;
            if (!names.Add(normalized)) throw new InvalidDataException("Duplicate normalized PFS0 filename.");
            entries.Add(new Pfs0Entry(name, checked(dataStart + e.Offset), e.Size));
        }
        long previousEnd = dataStart;
        foreach (var entry in entries.OrderBy(e => e.Offset))
        {
            if (entry.Offset < previousEnd) throw new InvalidDataException("Overlapping PFS0 entries.");
            previousEnd = checked(entry.Offset + entry.Size);
        }
        return entries;
    }
    public static void ValidateName(string name)
    {
        if (string.IsNullOrEmpty(name) || name is "." or ".." || name.IndexOfAny(['/', '\\', ':', '\0']) >= 0 || name.Any(char.IsControl))
            throw new InvalidDataException("PFS0 entries must use flat filenames.");
    }
    internal static long ReadLength(BinaryReader reader)
    {
        ulong value = reader.ReadUInt64();
        if (value > long.MaxValue) throw new InvalidDataException("Input length exceeds supported range.");
        return (long)value;
    }
    internal static byte[] ReadBytes(BinaryReader reader, int length)
    {
        byte[] bytes = reader.ReadBytes(length);
        if (bytes.Length != length) throw new InvalidDataException("Truncated input.");
        return bytes;
    }
}
