using System.Text.Json;
using System.Text.Json.Serialization;

namespace Ryujinx.SaveSync;

public sealed record SaveNativeRequest(int Version, Guid Id, string Operation, ulong TitleID, string? GamePath,
    Guid? SelectionID, string? SnapshotRoot, string? BindingIntentFile, SaveExportIdentity? ExportIdentity, Guid? TransactionID);
public sealed record SaveNativeSelection(Guid Id, ulong TitleID, string LocalUserID, IReadOnlyList<SaveKey> Keys, bool CanCreateMissing);
public sealed record SaveCompletedBinding(Guid TransactionID, BindingIntent Intent);
public sealed record SaveNativeResult(int Version, Guid Id, int Status, SaveNativeSelection? Selection,
    string? SnapshotRoot, SaveSnapshot? Snapshot, IReadOnlyList<SaveCompletedBinding> CompletedBindings,
    IReadOnlyList<ulong> BlockedGames, string? ErrorCode);
public sealed record SaveNativeProgress(string Phase, long Completed, long Total);

public static class SaveNativeJson
{
    public static SaveNativeRequest ParseRequest(ReadOnlySpan<byte> data)
    {
        try
        {
            if (data.Length > 65536) throw new SaveSyncException("invalid_request");
            var reader = new Utf8JsonReader(data, new JsonReaderOptions { MaxDepth = 32 });
            var objects = new Stack<HashSet<string>>();
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.StartObject) objects.Push(new(StringComparer.Ordinal));
                else if (reader.TokenType == JsonTokenType.EndObject) objects.Pop();
                else if (reader.TokenType == JsonTokenType.PropertyName && !objects.Peek().Add(reader.GetString()!)) throw new SaveSyncException("invalid_request");
            }
            var value = JsonSerializer.Deserialize(data, SaveJsonContext.Default.SaveNativeRequest) ?? throw new SaveSyncException("invalid_request");
            if (value.Version != 1 || value.Id == Guid.Empty || value.Operation is not ("describe" or "export" or "restore" or "recover" or "ack_binding")) throw new SaveSyncException("invalid_request");
            if (value.Operation == "describe" && (value.TitleID == 0 || string.IsNullOrEmpty(value.GamePath) || !Path.IsPathRooted(value.GamePath) || value.GamePath.Contains('\0') || value.GamePath.Length > 1024)) throw new SaveSyncException("invalid_request");
            if (value.Operation is "export" or "restore" && (value.SelectionID is null || value.SelectionID == Guid.Empty || string.IsNullOrEmpty(value.SnapshotRoot))) throw new SaveSyncException("invalid_request");
            if (value.Operation == "export" && value.ExportIdentity is null || value.Operation == "restore" && string.IsNullOrEmpty(value.BindingIntentFile) ||
                value.Operation == "ack_binding" && (value.TransactionID is null || value.TransactionID == Guid.Empty)) throw new SaveSyncException("invalid_request");
            return value;
        }
        catch (SaveSyncException) { throw; }
        catch (Exception e) when (e is JsonException or ArgumentException) { throw new SaveSyncException("invalid_request"); }
    }
    public static string Encode(SaveNativeResult result)
    {
        string json = JsonSerializer.Serialize(result, SaveJsonContext.Default.SaveNativeResult);
        if (System.Text.Encoding.UTF8.GetByteCount(json) > 65536) throw new SaveSyncException("invalid_result");
        return json;
    }
}

public static class SaveNativePaths
{
    public static BindingIntent ReadRestoreIntent(SaveNativeRequest request, string ownedRoot)
    {
        string staging = Path.GetFullPath(Path.Combine(ownedRoot, "staging"));
        string snapshot = Path.GetFullPath(request.SnapshotRoot ?? throw new SaveSyncException("invalid_request"));
        string relative = Path.GetRelativePath(staging, snapshot);
        if (!Guid.TryParseExact(relative, "D", out Guid generation) || generation == Guid.Empty ||
            snapshot != Path.Combine(staging, generation.ToString("D")) ||
            Path.GetFullPath(request.BindingIntentFile ?? throw new SaveSyncException("invalid_request")) != Path.Combine(snapshot, "binding-intent.json"))
            throw new SaveSyncException("invalid_request");
        string path = SnapshotPaths.Contained(ownedRoot, $"staging/{generation:D}/binding-intent.json");
        SnapshotFiles.RequireRegularFile(path);
        if (new FileInfo(path).Length > 65536) throw new SaveSyncException("invalid_request");
        byte[] data = SnapshotFiles.ReadManifest(path);
        if (data.Length > 65536) throw new SaveSyncException("invalid_request");
        SnapshotJson.CheckJson(data);
        BindingIntent intent = JsonSerializer.Deserialize(data, SaveJsonContext.Default.BindingIntent) ?? throw new SaveSyncException("invalid_request");
        if (intent.Generation != generation || intent.AccountKey == Guid.Empty || intent.TitleId == 0 ||
            string.IsNullOrEmpty(intent.Container) || intent.Container.Length > 255 ||
            !SnapshotJson.IsHex(intent.LocalUserId, 32) || !SnapshotJson.IsHex(intent.CloudUserId, 32)) throw new SaveSyncException("invalid_request");
        return intent;
    }
}
