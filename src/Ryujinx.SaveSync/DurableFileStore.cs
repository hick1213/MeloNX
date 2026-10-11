namespace Ryujinx.SaveSync;

public interface IFileDurability
{
    void SyncFile(string path);
    void SyncDirectory(string path);
    void Replace(string source, string target);
}
internal sealed class DarwinFileDurability : IFileDurability
{
    public void SyncFile(string path) => DarwinDurability.SyncFile(path);
    public void SyncDirectory(string path) => DarwinDurability.SyncDirectory(path);
    public void Replace(string source, string target) => File.Move(source, target, true);
}
public sealed class DurableFileStore : IDurableStore
{
    private readonly IFileDurability _io;
    private readonly string? _boundary;
    public DurableFileStore() : this(new DarwinFileDurability()) { }
    public DurableFileStore(string boundary) : this(new DarwinFileDurability(), boundary) { }
    public DurableFileStore(IFileDurability io, string? boundary = null)
    { _io = io; _boundary = boundary is null ? null : Path.GetFullPath(boundary); }
    private void SyncHierarchy(string directory)
    {
        directory = Path.GetFullPath(directory);
        if (_boundary is not null && directory != _boundary && !directory.StartsWith(_boundary + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new SaveSyncException("malformedSnapshot");
        while (true)
        {
            _io.SyncDirectory(directory);
            if (_boundary is null || directory == _boundary) break;
            directory = Path.GetDirectoryName(directory) ?? throw new SaveSyncException("malformedSnapshot");
        }
    }
    public void WriteAtomic(string path, ReadOnlySpan<byte> bytes)
    {
        string parent = Path.GetDirectoryName(Path.GetFullPath(path))!;
        if (!Directory.Exists(parent)) throw new DirectoryNotFoundException();
        if (bytes.Length > SnapshotJson.MaxManifestBytes) throw new SaveSyncException("malformedSnapshot");
        // Detect unsupported directory durability before replacing anything.
        SyncHierarchy(parent);
        string temp = Path.Combine(parent, ".save-write-" + Guid.NewGuid());
        string old = path + ".previous";
        if (File.Exists(old)) throw new SaveSyncException("rollbackRequired");
        bool existed = File.Exists(path), published = false, acknowledged = false, restored = false;
        try
        {
            if (existed)
            {
                DarwinFileNodes.RequireRegular(path);
                File.Copy(path, old); _io.SyncFile(old); SyncHierarchy(parent);
            }
            using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { file.Write(bytes); file.Flush(true); }
            _io.Replace(temp, path); published = true;
            SyncHierarchy(parent);
            acknowledged = true;
        }
        catch
        {
            if (published)
            {
                // The previous journal stays available even if a second I/O
                // failure prevents restoring its directory entry.
                if (existed) _io.Replace(old, path);
                else File.Delete(path);
                SyncHierarchy(parent);
                restored = true;
            }
            throw;
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
            if (File.Exists(old) && (acknowledged || !published || restored))
            { File.Delete(old); SyncHierarchy(parent); }
        }
    }
    public void SyncTree(string root)
    {
        var directories = new List<string> { root };
        var pending = new Stack<string>(); pending.Push(root); int count = 0;
        while (pending.TryPop(out string? directory))
        {
            foreach (string path in Directory.EnumerateFileSystemEntries(directory))
            {
                if (++count > 300000) throw new SaveSyncException("malformedSnapshot");
                bool isDirectory = DarwinFileNodes.RequireFileOrDirectory(path);
                if (isDirectory) { pending.Push(path); directories.Add(path); }
                else _io.SyncFile(path);
            }
        }
        foreach (string directory in directories.OrderByDescending(p => p.Length)) _io.SyncDirectory(directory);
        string? parent = Path.GetDirectoryName(Path.GetFullPath(root));
        if (parent is not null) SyncHierarchy(parent);
    }
}
