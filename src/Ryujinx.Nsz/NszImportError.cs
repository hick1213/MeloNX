namespace Ryujinx.Nsz;

public enum NszImportError { InsufficientSpace, WrongPackage, UnsupportedPackage, MissingKey, InvalidPackage, IoFailure }

public sealed class NszImportException(NszImportError code, string message) : IOException(message)
{
    public NszImportError Code { get; } = code;
}

public enum NszPackageKind { Application, Patch, AddOnContent, Unsupported }
public sealed record NszPackage(NszPackageKind Kind, ulong ApplicationId, ulong ContentId);
public interface INszPackageValidator
{
    NszPackage Validate(string path, CancellationToken cancellation);
}
public sealed record NszImportRequest(Guid Id, string Source, string TargetRoot,
    string OutputName, NszPackageKind ExpectedKind, ulong? ExpectedApplicationId);
public sealed record NszImportResult(Guid Id, string OutputPath, NszPackage Package);
