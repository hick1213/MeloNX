using System.Security.Cryptography;

namespace Ryujinx.SaveSync;

public static class SnapshotFiles
{
    public static void RequireRegularFile(string path) => DarwinFileNodes.RequireRegular(path);
    public const int BufferSize = 1024 * 1024;
    public static SaveRecordReference Export(string root, SaveKey cloudKey, Guid generation, ILogicalSave save, CancellationToken ct)
    {
        SnapshotJson.ValidateKey(cloudKey);
        var entries = save.Entries().Take(100001).ToArray();
        if (entries.Length > 100000 || entries.Any(e => e.Length < 0)) throw new SaveSyncException("malformedSnapshot");
        var files = entries.Where(e => !e.IsDirectory).ToArray();
        var directories = entries.Where(e => e.IsDirectory).Select(e => e.Path).ToArray();
        var empty = EmptyDirectories(entries, ct);
        SnapshotPaths.ValidateEntries(files.Select(e => e.Path).ToArray(), empty);
        string manifestRelative = SnapshotPaths.RecordManifest(cloudKey, generation);
        Directory.CreateDirectory(root);
        string manifestPath = SnapshotPaths.Contained(root, manifestRelative);
        string payloadRoot = Path.Combine(Path.GetDirectoryName(manifestPath)!, "payload");
        Directory.CreateDirectory(payloadRoot);
        foreach (string dir in empty) { ct.ThrowIfCancellationRequested(); Directory.CreateDirectory(SnapshotPaths.Contained(payloadRoot, dir)); }
        var records = new List<SaveFileEntry>(); byte[] buffer = new byte[BufferSize]; long total = 0;
        foreach (SaveEntry file in files)
        {
            ct.ThrowIfCancellationRequested();
            string destination = SnapshotPaths.Contained(payloadRoot, file.Path);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            using var stream = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, BufferSize);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long position = 0;
            while (position < file.Length)
            {
                ct.ThrowIfCancellationRequested();
                int requested = (int)Math.Min(buffer.Length, file.Length - position);
                int read = save.Read(file.Path, position, buffer.AsSpan(0, requested));
                if (read <= 0 || read > requested) throw new SaveSyncException("restoreFailed");
                stream.Write(buffer, 0, read); hash.AppendData(buffer, 0, read); position += read;
            }
            if (save.Read(file.Path, position, buffer.AsSpan(0, 1)) != 0) throw new SaveSyncException("restoreFailed");
            stream.Flush(true);
            records.Add(new(file.Path, position, Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant()));
            total = checked(total + position);
        }
        var manifest = new SaveRecordManifest(1, generation, cloudKey, records, empty);
        byte[] bytes = SnapshotJson.Encode(manifest);
        File.WriteAllBytes(manifestPath, bytes);
        return new(cloudKey, manifestRelative, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), total);
    }

    public static void Verify(string root, SaveSnapshot snapshot, CancellationToken ct)
    {
        SnapshotJson.Validate(snapshot);
        int entryCount = 0;
        foreach (SaveRecordReference reference in snapshot.Records)
        {
            ct.ThrowIfCancellationRequested();
            string manifestPath = SnapshotPaths.Contained(root, reference.ManifestRelativePath);
            byte[] bytes = ReadManifest(manifestPath);
            if (Digest(bytes) != reference.ManifestSha256) throw new SaveSyncException("malformedSnapshot");
            SaveRecordManifest record = SnapshotJson.DecodeRecord(bytes);
            if (record.Key != reference.Key || record.Generation != snapshot.Generation) throw new SaveSyncException("malformedSnapshot");
            string payloadRoot = Path.Combine(Path.GetDirectoryName(manifestPath)!, "payload");
            var actual = Scan(payloadRoot, ct).ToArray();
            entryCount = checked(entryCount + actual.Length);
            if (entryCount > 100000) throw new SaveSyncException("malformedSnapshot");
            var actualFiles = actual.Where(e => !e.IsDirectory).ToDictionary(e => e.Path, StringComparer.Ordinal);
            if (actualFiles.Count != record.Files.Count) throw new SaveSyncException("malformedSnapshot");
            long total = 0;
            foreach (SaveFileEntry file in record.Files)
            {
                ct.ThrowIfCancellationRequested();
                if (!actualFiles.TryGetValue(file.Path, out var info) || info.Length != file.Length) throw new SaveSyncException("malformedSnapshot");
                using var stream = new FileStream(SnapshotPaths.Contained(payloadRoot, file.Path), FileMode.Open, FileAccess.Read, FileShare.Read, BufferSize);
                if (Hash(stream, ct) != file.Sha256 || stream.Length != file.Length) throw new SaveSyncException("malformedSnapshot");
                total = checked(total + file.Length);
            }
            var actualEmpty = EmptyDirectories(actual, ct).ToHashSet(StringComparer.Ordinal);
            if (!actualEmpty.SetEquals(record.EmptyDirectories) || total != reference.TotalBytes) throw new SaveSyncException("malformedSnapshot");
        }
    }
    public static byte[] ReadManifest(string path)
    {
        DarwinFileNodes.RequireRegular(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, BufferSize);
        if (stream.Length > SnapshotJson.MaxManifestBytes) throw new SaveSyncException("malformedSnapshot");
        using var output = new MemoryStream(); byte[] buffer = new byte[64 * 1024];
        int read;
        while ((read = stream.Read(buffer)) > 0)
        {
            if (output.Length + read > SnapshotJson.MaxManifestBytes) throw new SaveSyncException("malformedSnapshot");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }
    public static IEnumerable<SaveEntry> Scan(string root, CancellationToken ct)
    {
        if (!Directory.Exists(root) || (new DirectoryInfo(root).Attributes & FileAttributes.ReparsePoint) != 0) throw new SaveSyncException("malformedSnapshot");
        var pending = new Stack<string>(); pending.Push(root); int count = 0;
        while (pending.TryPop(out string? directory))
        {
            foreach (string path in Directory.EnumerateFileSystemEntries(directory))
            {
                ct.ThrowIfCancellationRequested();
                if (++count > 100000) throw new SaveSyncException("malformedSnapshot");
                string relative = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
                string safe = SnapshotPaths.Contained(root, relative);
                FileAttributes attrs = File.GetAttributes(safe);
                if ((attrs & (FileAttributes.ReparsePoint | FileAttributes.Device)) != 0) throw new SaveSyncException("malformedSnapshot");
                bool isDirectory = DarwinFileNodes.RequireFileOrDirectory(safe);
                yield return new(relative, isDirectory, isDirectory ? 0 : new FileInfo(safe).Length);
                if (isDirectory) pending.Push(safe);
            }
        }
    }
    private static string Digest(ReadOnlySpan<byte> bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static string[] EmptyDirectories(IReadOnlyList<SaveEntry> entries, CancellationToken ct)
    {
        var nonEmpty = new HashSet<string>(StringComparer.Ordinal);
        foreach (SaveEntry entry in entries)
        {
            ct.ThrowIfCancellationRequested();
            string path = entry.Path;
            for (int slash = path.LastIndexOf('/'); slash >= 0; slash = path.LastIndexOf('/'))
            {
                path = path[..slash]; nonEmpty.Add(path);
            }
        }
        return entries.Where(e => e.IsDirectory && !nonEmpty.Contains(e.Path)).Select(e => e.Path).ToArray();
    }
    private static string Hash(Stream stream, CancellationToken ct)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256); byte[] buffer = new byte[BufferSize]; int read;
        while ((read = stream.Read(buffer)) > 0) { ct.ThrowIfCancellationRequested(); hash.AppendData(buffer, 0, read); }
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }
}
