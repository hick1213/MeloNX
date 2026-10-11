using System.Runtime.InteropServices;
using NUnit.Framework;
using Ryujinx.SaveSync;

namespace Ryujinx.SaveSync.Tests;

public class SnapshotFileTests
{
    [Test]
    public void ExportCompletesShortReadsAndPreservesEmptyDirectory()
    {
        string root = Path.Combine(Path.GetTempPath(), "save-sync-export-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            using var logical = new ShortReadSave();
            var key = new SaveKey(0x100, "00000000000000000000000000000001", SaveKind.Account, 2);
            var generation = Guid.NewGuid();
            SaveRecordReference reference = SnapshotFiles.Export(root, key, generation, logical, CancellationToken.None);
            string payload = Path.Combine(root, Path.GetDirectoryName(reference.ManifestRelativePath)!, "payload");
            Assert.That(File.ReadAllBytes(Path.Combine(payload, "progress.bin")), Is.EqualTo(new byte[] { 1, 2, 3, 4 }));
            Assert.That(Directory.Exists(Path.Combine(payload, "empty/sub")), Is.True);
            var snapshot = new SaveSnapshot(1, generation, null, 0x100, key.UserId, "2026-01-01T00:00:00Z", Guid.NewGuid(), 4, [reference]);
            SnapshotFiles.Verify(root, snapshot, CancellationToken.None);
            File.WriteAllBytes(Path.Combine(payload, "progress.bin"), [1, 2, 3]);
            Assert.Throws<SaveSyncException>(() => SnapshotFiles.Verify(root, snapshot, CancellationToken.None));
        }
        finally { Directory.Delete(root, true); }
    }
    [Test]
    public void ScannerRejectsFifoBeforeAnyBlockingRead()
    {
        if (!OperatingSystem.IsMacOS()) Assert.Ignore("Darwin filesystem test");
        // The external volume cannot create FIFO nodes; this fixture contains no data.
        string root = Path.Combine("/private/var/tmp", "save-sync-fifo-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            if (MkFifo(Path.Combine(root, "pipe"), 0x180) != 0) Assert.Ignore("Test volume does not support FIFO nodes");
            Assert.Throws<SaveSyncException>(() => SnapshotFiles.Scan(root, CancellationToken.None).ToArray());
        }
        finally { Directory.Delete(root, true); }
    }
    [Test]
    public void OwnedRootAcceptsPlatformAliasOutsideItsBoundary()
    {
        if (!OperatingSystem.IsMacOS()) Assert.Ignore("Darwin filesystem test");
        string root = Path.Combine("/var/tmp", "save-sync-platform-alias-" + Guid.NewGuid());
        // Only a tiny directory is used here to exercise Apple's /var alias.
        Directory.CreateDirectory(root);
        try { Assert.That(SnapshotPaths.Contained(root, "file"), Does.EndWith("/file")); }
        finally { Directory.Delete(root); }
    }
    [DllImport("/usr/lib/libSystem.B.dylib", EntryPoint = "mkfifo", SetLastError = true)]
    private static extern int MkFifo([MarshalAs(UnmanagedType.LPUTF8Str)] string path, uint mode);

    private sealed class ShortReadSave : ILogicalSave
    {
        private readonly byte[] _bytes = [1, 2, 3, 4];
        public IEnumerable<SaveEntry> Entries() => [new("progress.bin", false, 4), new("empty", true, 0), new("empty/sub", true, 0)];
        public int Read(string path, long offset, Span<byte> buffer)
        {
            if (path != "progress.bin") throw new InvalidOperationException();
            if (offset >= _bytes.Length) return 0;
            buffer[0] = _bytes[(int)offset]; return 1;
        }
        public void ReplaceFrom(string path) => throw new InvalidOperationException();
        public void Commit() => throw new InvalidOperationException();
        public void Dispose() { }
    }
}
