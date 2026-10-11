using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Ryujinx.SaveSync;

public static class SnapshotJson
{
    public const int MaxManifestBytes = 4 * 1024 * 1024;
    public static bool IsHex(string? value, int length) => value?.Length == length && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    public static SaveSnapshot DecodeSnapshot(ReadOnlySpan<byte> data)
    {
        try
        {
            CheckJson(data);
            var value = JsonSerializer.Deserialize(data, SaveJsonContext.Default.SaveSnapshot) ?? throw Malformed();
            Validate(value); return value;
        }
        catch (SaveSyncException) { throw; }
        catch (Exception e) when (e is JsonException or OverflowException or ArgumentException) { throw Malformed(); }
    }
    public static SaveRecordManifest DecodeRecord(ReadOnlySpan<byte> data)
    {
        try
        {
            CheckJson(data);
            var value = JsonSerializer.Deserialize(data, SaveJsonContext.Default.SaveRecordManifest) ?? throw Malformed();
            ValidateRecord(value); return value;
        }
        catch (SaveSyncException) { throw; }
        catch (Exception e) when (e is JsonException or OverflowException or ArgumentException) { throw Malformed(); }
    }
    public static byte[] Encode(SaveSnapshot value) { Validate(value); return Bounded(JsonSerializer.SerializeToUtf8Bytes(value, SaveJsonContext.Default.SaveSnapshot)); }
    public static byte[] Encode(SaveRecordManifest value) { ValidateRecord(value); return Bounded(JsonSerializer.SerializeToUtf8Bytes(value, SaveJsonContext.Default.SaveRecordManifest)); }
    private static byte[] Bounded(byte[] value) { if (value.Length > MaxManifestBytes) throw Malformed(); return value; }
    private static SaveSyncException Malformed() => new("malformedSnapshot");
    private static void CheckJson(ReadOnlySpan<byte> data)
    {
        if (data.Length > MaxManifestBytes) throw Malformed();
        var reader = new Utf8JsonReader(data, new JsonReaderOptions { MaxDepth = 64 });
        var objects = new Stack<HashSet<string>>();
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.StartObject) objects.Push(new(StringComparer.Ordinal));
            else if (reader.TokenType == JsonTokenType.EndObject) objects.Pop();
            else if (reader.TokenType == JsonTokenType.PropertyName && !objects.Peek().Add(reader.GetString()!)) throw Malformed();
        }
    }
    public static void ValidateKey(SaveKey key)
    {
        if (key is null || key.ProgramId == 0 || !Enum.IsDefined(key.Kind)) throw Malformed();
        if (key.Kind == SaveKind.Account && (!IsHex(key.UserId, 32) || key.UserId == new string('0', 32))) throw Malformed();
        if (key.Kind == SaveKind.Device && key.UserId != "shared") throw Malformed();
    }
    public static void Validate(SaveSnapshot value)
    {
        if (value.SchemaVersion != 1 || value.TitleID == 0 || value.Generation == Guid.Empty || value.Parent == value.Generation ||
            value.InstallationID == Guid.Empty || !IsHex(value.OwnerUserID, 32) || value.OwnerUserID == new string('0', 32) ||
            value.CreatedUTC is null || !value.CreatedUTC.EndsWith('Z') ||
            !DateTimeOffset.TryParse(value.CreatedUTC, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out _) ||
            value.TotalBytes < 0 || value.Records is null || value.Records.Count is < 1 or > 64) throw Malformed();
        var keys = new HashSet<SaveKey>(); long sum = 0;
        try
        {
            foreach (var reference in value.Records)
            {
                if (reference is null) throw Malformed();
                ValidateKey(reference.Key);
                if (reference.Key.ProgramId != value.TitleID || !keys.Add(reference.Key) ||
                    reference.Key.Kind == SaveKind.Account && reference.Key.UserId != value.OwnerUserID ||
                    reference.TotalBytes < 0 || !IsHex(reference.ManifestSha256, 64) ||
                    reference.ManifestRelativePath != SnapshotPaths.RecordManifest(reference.Key, value.Generation)) throw Malformed();
                sum = checked(sum + reference.TotalBytes);
            }
        }
        catch (OverflowException) { throw Malformed(); }
        if (sum != value.TotalBytes) throw Malformed();
    }
    public static void ValidateRecord(SaveRecordManifest value)
    {
        if (value.SchemaVersion != 1 || value.Generation == Guid.Empty || value.Files is null || value.EmptyDirectories is null) throw Malformed();
        ValidateKey(value.Key);
        SnapshotPaths.ValidateEntries(value.Files.Select(f => f?.Path ?? throw Malformed()).ToArray(), value.EmptyDirectories);
        long total = 0;
        try
        {
            foreach (var file in value.Files)
            {
                if (file.Length < 0 || !IsHex(file.Sha256, 64)) throw Malformed();
                total = checked(total + file.Length);
            }
        }
        catch (OverflowException) { throw Malformed(); }
    }
}

public sealed class HexIdConverter : JsonConverter<ulong>
{
    public override ulong Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String) throw new JsonException();
        string? value = reader.GetString();
        if (!SnapshotJson.IsHex(value, 16) || !ulong.TryParse(value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out ulong id)) throw new JsonException();
        return id;
    }
    public override void Write(Utf8JsonWriter writer, ulong value, JsonSerializerOptions options) => writer.WriteStringValue(value.ToString("x16", CultureInfo.InvariantCulture));
}

public sealed class SaveKindConverter : JsonConverter<SaveKind>
{
    public override SaveKind Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String) throw new JsonException();
        return reader.GetString() switch { "Account" => SaveKind.Account, "Device" => SaveKind.Device, _ => throw new JsonException() };
    }
    public override void Write(Utf8JsonWriter writer, SaveKind value, JsonSerializerOptions options) => writer.WriteStringValue(value.ToString());
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, Converters = new[] { typeof(HexIdConverter), typeof(SaveKindConverter) })]
[JsonSerializable(typeof(SaveSnapshot))]
[JsonSerializable(typeof(SaveRecordManifest))]
[JsonSerializable(typeof(RestoreJournal))]
[JsonSerializable(typeof(BindingIntent))]
public partial class SaveJsonContext : JsonSerializerContext;
