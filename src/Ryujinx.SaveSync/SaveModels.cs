using System.Text.Json.Serialization;

namespace Ryujinx.SaveSync;

public enum SaveKind { Account, Device }
public sealed record SaveKey(
    [property: JsonPropertyName("programID")] ulong ProgramId,
    [property: JsonPropertyName("userID")] string UserId,
    [property: JsonPropertyName("type")] SaveKind Kind, ushort Index);
public sealed record SaveFileEntry(string Path, long Length, string Sha256);
public sealed record SaveRecordManifest(int SchemaVersion, Guid Generation, SaveKey Key,
    IReadOnlyList<SaveFileEntry> Files, IReadOnlyList<string> EmptyDirectories);
public sealed record SaveRecordReference(SaveKey Key, string ManifestRelativePath, string ManifestSha256, long TotalBytes);
public sealed record SaveSnapshot(int SchemaVersion, Guid Generation, Guid? Parent, ulong TitleID,
    string OwnerUserID, string CreatedUTC, Guid InstallationID, long TotalBytes, IReadOnlyList<SaveRecordReference> Records);
public sealed class SaveSyncException : Exception
{
    public string Code { get; }
    public SaveSyncException(string code) : base(code) => Code = code;
}

public sealed record SaveEntry(string Path, bool IsDirectory, long Length);
public interface ILogicalSave : IDisposable
{
    IEnumerable<SaveEntry> Entries();
    int Read(string path, long offset, Span<byte> buffer);
    void ReplaceFrom(string localPayload);
    void Commit();
}
