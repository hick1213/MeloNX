namespace Ryujinx.Nsz;

public sealed record NszLimits(int MaxEntries = 8192, int MaxSections = 8192,
    int MaxBlockExponent = 26, int MaxBlocks = 1_048_576, int WindowLog = 27, int MaxTotalSections = 65536);
public sealed record ConversionProgress(long CompletedBytes, long TotalBytes, string Stage);
public sealed record ConversionReport(long BytesWritten, IReadOnlyDictionary<string, string> NcaHashes);
