using System.Text;

namespace Ryujinx.SaveSync;

public static class SnapshotPaths
{
    public static void Validate(string path)
    {
        if (string.IsNullOrEmpty(path) || Encoding.UTF8.GetByteCount(path) > 1024 || path.Contains('\\') || path.Contains(':') || path.Contains('\0')) throw new SaveSyncException("malformedSnapshot");
        string[] parts = path.Split('/');
        if (parts.Length > 64 || parts.Any(p => p is "" or "." or "..")) throw new SaveSyncException("malformedSnapshot");
    }
    private static string Canonical(string path) => path.Normalize(NormalizationForm.FormC).ToLowerInvariant();
    public static void ValidateEntries(IReadOnlyList<string> files, IReadOnlyList<string> emptyDirectories)
    {
        if (files.Count > 100000 || emptyDirectories.Count > 100000 - files.Count) throw new SaveSyncException("malformedSnapshot");
        string[] paths = files.Concat(emptyDirectories).ToArray();
        var all = new HashSet<string>(StringComparer.Ordinal); var aliases = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string path in paths) { Validate(path); if (!all.Add(Canonical(path))) throw new SaveSyncException("malformedSnapshot"); }
        foreach (string path in paths)
        {
            string[] parts = path.Split('/');
            for (int end = 1; end <= parts.Length; end++)
            {
                string actual = string.Join('/', parts.Take(end)), canonical = Canonical(actual);
                if (end < parts.Length && all.Contains(canonical)) throw new SaveSyncException("malformedSnapshot");
                if (aliases.TryGetValue(canonical, out string? old) && old != actual) throw new SaveSyncException("malformedSnapshot");
                aliases[canonical] = actual;
                if (aliases.Count > 100000) throw new SaveSyncException("malformedSnapshot");
            }
        }
    }
    public static string RecordManifest(SaveKey key, Guid generation) => $"{key.ProgramId:x16}/{key.UserId}/{key.Kind}/{key.Index}/versions/{generation:D}/manifest.json";
    public static string GameManifest(ulong titleId, Guid generation) => $"{titleId:x16}/snapshots/{generation:D}/manifest.json";
    public static string Contained(string root, string relativePath)
    {
        Validate(relativePath);
        string fullRoot = Path.GetFullPath(root), candidate = fullRoot;
        // Platform ancestors such as Apple's /var may be aliases. The native
        // request boundary validates the app-owned hierarchy, while this method
        // rejects links in the owned root and every payload descendant.
        if ((new DirectoryInfo(fullRoot).Attributes & FileAttributes.ReparsePoint) != 0) throw new SaveSyncException("malformedSnapshot");
        foreach (string part in relativePath.Split('/'))
        {
            candidate = Path.Combine(candidate, part);
            var info = new FileInfo(candidate);
            if (info.LinkTarget is not null || (info.Exists && (info.Attributes & FileAttributes.ReparsePoint) != 0)) throw new SaveSyncException("malformedSnapshot");
            if (Directory.Exists(candidate) && (new DirectoryInfo(candidate).Attributes & FileAttributes.ReparsePoint) != 0) throw new SaveSyncException("malformedSnapshot");
        }
        string prefix = fullRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!Path.GetFullPath(candidate).StartsWith(prefix, StringComparison.Ordinal)) throw new SaveSyncException("malformedSnapshot");
        return candidate;
    }
}
