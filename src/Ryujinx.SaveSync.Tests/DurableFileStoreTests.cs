using NUnit.Framework;
using Ryujinx.SaveSync;

namespace Ryujinx.SaveSync.Tests;

public class DurableFileStoreTests
{
    [Test]
    public void AcknowledgedWriteMakesPreviousDeletionAndOwnedAncestorEntriesDurable()
    {
        string root = Path.Combine(Path.GetTempPath(), "save-parent-sync-" + Guid.NewGuid());
        string parent = Path.Combine(root, "SaveSync", "v1", "transactions");
        Directory.CreateDirectory(parent);
        try
        {
            string journal = Path.Combine(parent, "journal.json"); File.WriteAllText(journal, "old");
            var io = new RecordingIO();
            new DurableFileStore(io, root).WriteAtomic(journal, "new"u8);
            Assert.That(io.Calls, Does.Contain(root));
            Assert.That(io.Calls, Does.Contain(Path.Combine(root, "SaveSync")));
            Assert.That(io.Calls[^1], Is.EqualTo(root));
            Assert.That(io.PreviousPresentAtSync[^1], Is.False);
        }
        finally { Directory.Delete(root, true); }
    }
    [Test]
    public void SecondIoFailureCannotDeleteLastPreviousJournal()
    {
        string root = Path.Combine(Path.GetTempPath(), "save-durable-double-fault-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            string journal = Path.Combine(root, "journal.json"); File.WriteAllText(journal, "old");
            var store = new DurableFileStore(new DoubleFailureIO());
            Assert.Throws<IOException>(() => store.WriteAtomic(journal, "new"u8));
            Assert.That(File.ReadAllText(journal + ".previous"), Is.EqualTo("old"));
        }
        finally { Directory.Delete(root, true); }
    }
    [Test]
    public void AtomicWriteReplacesWholeJournalAndSyncsBackupTree()
    {
        string root = Path.Combine(Path.GetTempPath(), "save-durable-test-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            string journal = Path.Combine(root, "journal.json"); File.WriteAllText(journal, "long old journal");
            var store = new DurableFileStore(); store.WriteAtomic(journal, "new"u8); store.SyncTree(root);
            Assert.That(File.ReadAllText(journal), Is.EqualTo("new"));
            Assert.That(Directory.GetFiles(root).Select(Path.GetFileName), Is.EquivalentTo(new[] { "journal.json" }));
        }
        finally { Directory.Delete(root, true); }
    }
    [Test]
    public void AtomicWriteToMissingParentDoesNotCreateUnacknowledgedJournal()
    {
        string root = Path.Combine(Path.GetTempPath(), "save-durable-missing-" + Guid.NewGuid());
        string journal = Path.Combine(root, "journal.json");
        Assert.Throws<DirectoryNotFoundException>(() => new DurableFileStore().WriteAtomic(journal, "new"u8));
        Assert.That(File.Exists(journal), Is.False);
    }
}

internal sealed class DoubleFailureIO : IFileDurability
{
    private int _directories;
    public void SyncFile(string path) { }
    public void SyncDirectory(string path) { if (++_directories == 3) throw new IOException("Injected post-rename error"); }
    public void Replace(string source, string target)
    {
        if (source.EndsWith(".previous", StringComparison.Ordinal)) throw new IOException("Injected journal rollback error");
        File.Move(source, target, true);
    }
}

internal sealed class RecordingIO : IFileDurability
{
    public List<string> Calls { get; } = [];
    public List<bool> PreviousPresentAtSync { get; } = [];
    public void SyncFile(string path) { }
    public void SyncDirectory(string path) { Calls.Add(path); PreviousPresentAtSync.Add(Directory.EnumerateFiles(path, "*.previous").Any()); }
    public void Replace(string source, string target) => File.Move(source, target, true);
}
