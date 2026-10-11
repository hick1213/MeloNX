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
    public DurableFileStore() : this(new DarwinFileDurability()) { }
    public DurableFileStore(IFileDurability io) => _io = io;
    public void WriteAtomic(string path, ReadOnlySpan<byte> bytes)
    {
        string parent = Path.GetDirectoryName(Path.GetFullPath(path))!;
        if (!Directory.Exists(parent)) throw new DirectoryNotFoundException();
        if (bytes.Length > SnapshotJson.MaxManifestBytes) throw new SaveSyncException("malformedSnapshot");
        // Detect unsupported directory durability before replacing anything.
        _io.SyncDirectory(parent);
        string temp = Path.Combine(parent, ".save-write-" + Guid.NewGuid());
        string old = path + ".previous";
        if (File.Exists(old)) throw new SaveSyncException("rollbackRequired");
        bool existed = File.Exists(path), published = false, acknowledged = false, restored = false;
        try
        {
            if (existed)
            {
                DarwinFileNodes.RequireRegular(path);
                File.Copy(path, old); _io.SyncFile(old); _io.SyncDirectory(parent);
            }
            using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { file.Write(bytes); file.Flush(true); }
            _io.Replace(temp, path); published = true;
            _io.SyncDirectory(parent);
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
                _io.SyncDirectory(parent);
                restored = true;
            }
            throw;
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
            if (File.Exists(old) && (acknowledged || !published || restored)) File.Delete(old);
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
        if (parent is not null) _io.SyncDirectory(parent);
    }
}
