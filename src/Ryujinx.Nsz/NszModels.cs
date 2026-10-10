namespace Ryujinx.Nsz;

public sealed record NszLimits(int MaxEntries = 8192, int MaxSections = 64,
    int MaxBlockExponent = 26, int MaxBlocks = 1_048_576, int WindowLog = 27);
public sealed record ConversionProgress(long CompletedBytes, long TotalBytes, string Stage);
public sealed record ConversionReport(long BytesWritten, IReadOnlyDictionary<string, string> NcaHashes);
