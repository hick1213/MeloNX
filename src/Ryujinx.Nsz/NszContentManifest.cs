using System.Buffers.Binary;

namespace Ryujinx.Nsz;

public sealed record NszContentEntry(string ContentId, long Size, byte Type, byte[] Hash, byte IdOffset = 0);
public sealed record NszContentManifest(NszPackage Package, IReadOnlyList<NszContentEntry> Contents)
{
    // Validate bounds before downstream LibHac parsers can allocate extended patch arrays.
    public static NszContentManifest Read(Stream input, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        if (!input.CanSeek || input.Length < 0x40 || input.Length > 4 * 1024 * 1024)
            throw new InvalidDataException("CNMT length exceeds supported limits.");
        byte[] header = new byte[0x20]; input.Position = 0; input.ReadExactly(header);
        ulong titleId = BinaryPrimitives.ReadUInt64LittleEndian(header);
        NszPackageKind kind = header[0xc] switch { 0x80 => NszPackageKind.Application, 0x81 => NszPackageKind.Patch, 0x82 => NszPackageKind.AddOnContent, _ => NszPackageKind.Unsupported };
        if (kind == NszPackageKind.Unsupported || BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0x1c)) != 0)
            throw new NszImportException(NszImportError.UnsupportedPackage, "CNMT format or content type is unsupported.");
        int table = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(0xe));
        int count = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(0x10));
        int metaCount = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(0x12));
        long end = checked(0x20L + table + count * 0x38L + metaCount * 0x10L);
        if (table < 12 || count is < 1 or > 8192 || metaCount > 8192 || end > input.Length - 32)
            throw new InvalidDataException("CNMT directory exceeds supported limits.");
        if (kind == NszPackageKind.Patch) ValidatePatchExtension(input, table, end, cancellation);
        input.Position = 0x20;
        Span<byte> relation = stackalloc byte[8]; input.ReadExactly(relation);
        ulong applicationId = kind == NszPackageKind.Application ? titleId : BinaryPrimitives.ReadUInt64LittleEndian(relation);
        if (titleId == 0 || applicationId == 0) throw new InvalidDataException("CNMT title identity is invalid.");
        input.Position = 0x20 + table;
        var entries = new List<NszContentEntry>(count); var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        byte[] raw = new byte[0x38];
        for (int i = 0; i < count; i++)
        {
            cancellation.ThrowIfCancellationRequested(); input.ReadExactly(raw);
            string id = Convert.ToHexString(raw.AsSpan(0x20, 16)).ToLowerInvariant();
            long size = BinaryPrimitives.ReadUInt32LittleEndian(raw.AsSpan(0x30)) | ((long)BinaryPrimitives.ReadUInt16LittleEndian(raw.AsSpan(0x34)) << 32);
            if (size <= 0 || raw[0x36] > 6 || !ids.Add(id))
                throw new InvalidDataException("CNMT content entry is invalid.");
            entries.Add(new(id, size, raw[0x36], raw[..32], raw[0x37]));
        }
        return new(new(kind, applicationId, titleId), entries);
    }
    private static void ValidatePatchExtension(Stream input, int table, long start, CancellationToken cancellation)
    {
        if (table < 0x18 || start > input.Length - 0x1c - 32)
            throw new InvalidDataException("Patch extended header is truncated.");
        Span<byte> size = stackalloc byte[4]; input.Position = 0x2c; input.ReadExactly(size);
        uint declared = BinaryPrimitives.ReadUInt32LittleEndian(size);
        Span<byte> header = stackalloc byte[0x1c]; input.Position = start; input.ReadExactly(header);
        Span<int> counts = stackalloc int[6]; int totalCount = 0;
        for (int i = 0; i < 6; i++)
        {
            counts[i] = BinaryPrimitives.ReadInt32LittleEndian(header[(i * 4)..]);
            if (counts[i] is < 0 or > 8192) throw new InvalidDataException("Patch extended count exceeds supported limits.");
            totalCount = checked(totalCount + counts[i]);
        }
        if (totalCount > 8192) throw new InvalidDataException("Patch extended object count exceeds supported limits.");
        long fixedSize = checked(0x1cL + 0x38L * counts[0] + 0x28L * counts[1] + 0x28L * counts[2] +
            0x34L * counts[3] + 0x18L * counts[4] + 0x38L * counts[5]);
        if (fixedSize > input.Length - start - 32) throw new InvalidDataException("Patch extended entries are truncated.");
        long fragmentStart = checked(start + 0x1c + 0x38L * counts[0] + 0x28L * counts[1] + 0x28L * counts[2]);
        Span<byte> field = stackalloc byte[2]; int fragments = 0;
        for (int i = 0; i < counts[3]; i++)
        {
            cancellation.ThrowIfCancellationRequested();
            input.Position = fragmentStart + i * 0x34L + 0x2c; input.ReadExactly(field);
            int count = BinaryPrimitives.ReadInt16LittleEndian(field);
            if (count < 0) throw new InvalidDataException("Patch fragment count is negative.");
            fragments = checked(fragments + count);
            if (fragments > 8192) throw new InvalidDataException("Patch fragment map exceeds supported limits.");
        }
        long actual = checked(fixedSize + 4L * fragments);
        if (actual != declared || start + actual + 32 != input.Length)
            throw new InvalidDataException("Patch extended length is inconsistent.");
    }
    public static NszPackage SelectPackage(IReadOnlyList<NszContentManifest> manifests)
    {
        if (manifests.Count != 1)
            throw new NszImportException(NszImportError.UnsupportedPackage, "Package has no unique content role.");
        return manifests[0].Package;
    }
    public static bool ContentTypeMatches(byte cnmtType, byte ncaType) => cnmtType switch
    {
        0 => ncaType == 1, 1 => ncaType == 0, 2 => ncaType is 4 or 5,
        3 => ncaType == 2, 4 or 5 => ncaType == 3, 6 => ncaType == 4, _ => false
    };
    public static void ValidateIncludedNcas(NszContentManifest manifest, string metadataId, IEnumerable<string> includedIds)
    {
        var allowed = manifest.Contents.Select(e => e.ContentId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        allowed.Add(metadataId);
        if (includedIds.Any(id => !allowed.Contains(id)))
            throw new NszImportException(NszImportError.UnsupportedPackage, "Package contains unreferenced or unrelated NCA content.");
    }
    public static bool TitleMatches(NszPackage package, byte idOffset, ulong ncaTitleId)
    {
        if (idOffset > 15 || package.ContentId > ulong.MaxValue - idOffset || package.ApplicationId > ulong.MaxValue - idOffset) return false;
        return ncaTitleId == package.ContentId + idOffset ||
            (package.Kind == NszPackageKind.Patch && ncaTitleId == package.ApplicationId + idOffset);
    }
}
