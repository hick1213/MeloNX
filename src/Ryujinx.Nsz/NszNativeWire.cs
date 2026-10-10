using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Ryujinx.Nsz;

public static class NszRequestJson
{
    public static NszImportRequest Parse(string json)
    {
        if (Encoding.UTF8.GetByteCount(json) > 65536) throw new ArgumentException("Import request exceeds its size limit.");
        try
        {
            using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new ArgumentException("Invalid import request.");
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var field in root.EnumerateObject())
                if (!seen.Add(field.Name) || field.Name is not ("version" or "id" or "source" or "targetRoot" or "outputName" or "kind" or "applicationId"))
                    throw new ArgumentException("Unknown or duplicate request field.");
            if (root.GetProperty("version").GetInt32() != 1 || !Guid.TryParseExact(root.GetProperty("id").GetString(), "D", out var id) || id == Guid.Empty)
                throw new ArgumentException("Unsupported import request version or identifier.");
            var kind = (NszPackageKind)root.GetProperty("kind").GetInt32();
            if (!Enum.IsDefined(kind) || kind == NszPackageKind.Unsupported) throw new ArgumentException("Invalid import intent.");
            ulong? applicationId = null;
            if (root.TryGetProperty("applicationId", out var application) && application.ValueKind != JsonValueKind.Null)
            {
                string value = application.GetString()!;
                if (value.Length != 16 || !ulong.TryParse(value, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var parsed) || parsed == 0)
                    throw new ArgumentException("Invalid title ID.");
                applicationId = parsed;
            }
            if (kind != NszPackageKind.Application && applicationId == null) throw new ArgumentException("Content import requires a selected game.");
            string source = root.GetProperty("source").GetString()!, target = root.GetProperty("targetRoot").GetString()!, name = root.GetProperty("outputName").GetString()!;
            if (!Path.IsPathFullyQualified(source) || !Path.IsPathFullyQualified(target) || !source.EndsWith(".nsz", StringComparison.OrdinalIgnoreCase) || string.IsNullOrWhiteSpace(name))
                throw new ArgumentException("Invalid import paths.");
            return new(id, source, target, name, kind, applicationId);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or NullReferenceException or OverflowException)
        { throw new ArgumentException("Invalid import request."); }
    }
}

public static class NszUtf8Buffers
{
    private static readonly ConcurrentDictionary<nint, byte> Allocations = new();
    public static nint Allocate(string value)
    {
        if (Encoding.UTF8.GetByteCount(value) > 65536) throw new ArgumentException("Native string exceeds its size limit.");
        nint pointer = Marshal.StringToCoTaskMemUTF8(value); Allocations.TryAdd(pointer, 0); return pointer;
    }
    public static bool Owns(nint pointer) => Allocations.ContainsKey(pointer);
    public static void Free(nint pointer)
    {
        if (Allocations.TryRemove(pointer, out _)) Marshal.FreeCoTaskMem(pointer);
    }
}
