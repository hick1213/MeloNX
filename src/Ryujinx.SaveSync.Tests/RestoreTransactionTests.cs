using NUnit.Framework;
using Ryujinx.Library.SaveSync;
using Ryujinx.SaveSync;

namespace Ryujinx.SaveSync.Tests;

public class RestoreTransactionTests
{
    [Test]
    public void PhysicalSaveSynchronizationPrecedesCompletedPublication()
    {
        using var f = new RestoreFixture();
        var durable = new CompletedSyncOrder(f.Nand.Durable, () => {
            foreach (var key in f.Selection.Keys)
                Assert.That(f.Nand.Durable.Synced, Does.Contain(f.Nand.PhysicalDir(key)));
        });
        var transaction = new SaveRestoreTransaction(f.Nand.Repository, durable, f.Nand.OwnedRoot, () => long.MaxValue);
        Assert.That(transaction.Run(f.Selection, f.SnapshotRoot, f.Intent).Status, Is.EqualTo(RestoreStatus.Completed));
    }
    [Test]
    public void PhysicalSynchronizationFailureCannotPublishCompletedOrRolledBack()
    {
        using var f = new RestoreFixture();
        f.Nand.Durable.FailSyncPath = path => path.Contains("/bis/user/save/", StringComparison.Ordinal);
        var result = f.Transaction().Run(f.Selection, f.SnapshotRoot, f.Intent);
        Assert.That(result.Status, Is.EqualTo(RestoreStatus.RecoveryRequired));
        Assert.That(result.CompletedBinding, Is.Null);
        string journal = Directory.GetFiles(Path.Combine(f.Nand.OwnedRoot, "transactions"), "*.json").Single();
        var value = RestoreJournal.Decode(File.ReadAllBytes(journal));
        Assert.That(value.Completed, Is.False); Assert.That(value.RolledBack, Is.False);
    }
    [Test]
    public void FailedCompletedJournalWriteRollsBackWithoutBinding()
    {
        using var f = new RestoreFixture();
        var durable = new CompletedWriteFailure(f.Nand.Durable);
        var run = new SaveRestoreTransaction(f.Nand.Repository, durable, f.Nand.OwnedRoot, () => long.MaxValue);
        var result = run.Run(f.Selection, f.SnapshotRoot, f.Intent);
        Assert.That(result.Status, Is.EqualTo(RestoreStatus.RolledBack));
        Assert.That(result.CompletedBinding, Is.Null);
        Assert.That(f.Bytes(), Is.EqualTo(new byte[] { 8, 8, 8 }));
    }
    [Test]
    public void RecoveryDoesNotDependOnIncomingStagingAfterMutation()
    {
        using var f = new RestoreFixture();
        var run = f.Transaction((stage, _) => { if (stage == RestoreStage.AfterCommit) throw new SimulatedInterruption(); });
        Assert.Throws<SimulatedInterruption>(() => run.Run(f.Selection, f.SnapshotRoot, f.Intent));
        Directory.Delete(f.SnapshotRoot, true);
        Assert.That(f.Transaction().RecoverIncomplete().Single().Status, Is.EqualTo(RestoreStatus.RolledBack));
        Assert.That(f.Bytes(), Is.EqualTo(new byte[] { 8, 8, 8 }));
    }
    [Test]
    public void RollbackFailureBlocksGameAndLaterReplayCanRecover()
    {
        using var f = new RestoreFixture(); SaveRestoreTransaction? run = null;
        run = f.Transaction((phase, _) => { if (phase == RestoreStage.AfterCommit) { f.Nand.Durable.Fail = true; run!.RequestSafeStop(); } });
        var result = run.Run(f.Selection, f.SnapshotRoot, f.Intent);
        Assert.That(result.Status, Is.EqualTo(RestoreStatus.RecoveryRequired));
        Assert.That(result.BlockedGames, Is.EquivalentTo(new[] { f.Nand.TitleId }));
        f.Nand.Durable.Fail = false;
        Assert.That(f.Transaction().RecoverIncomplete().Single().Status, Is.EqualTo(RestoreStatus.RolledBack));
        Assert.That(f.Bytes(), Is.EqualTo(new byte[] { 8, 8, 8 }));
    }
    [Test]
    public void InterruptedAfterFinalCommitRollsBackEveryMayHaveChangedRecord()
    {
        using var f = new RestoreFixture();
        var run = f.Transaction((phase, _) => { if (phase == RestoreStage.AfterLastCommit) throw new SimulatedInterruption(); });
        Assert.Throws<SimulatedInterruption>(() => run.Run(f.Selection, f.SnapshotRoot, f.Intent));
        var recovery = f.Transaction().RecoverIncomplete();
        Assert.That(recovery.Single().Status, Is.EqualTo(RestoreStatus.RolledBack));
        Assert.That(f.Bytes(), Is.EqualTo(new byte[] { 8, 8, 8 }));
        Assert.That(recovery.Single().CompletedBinding, Is.Null);
        Assert.That(f.Transaction().RecoverIncomplete().Single().Status, Is.EqualTo(RestoreStatus.RolledBack));
    }
    [Test]
    public void CompletedBeforeBindingReplaysBindingWithoutRollingBackSave()
    {
        using var f = new RestoreFixture();
        var run = f.Transaction((phase, _) => { if (phase == RestoreStage.AfterCompleted) throw new SimulatedInterruption(); });
        Assert.Throws<SimulatedInterruption>(() => run.Run(f.Selection, f.SnapshotRoot, f.Intent));
        var recovery = f.Transaction().RecoverIncomplete().Single();
        Assert.That(recovery.Status, Is.EqualTo(RestoreStatus.Completed));
        Assert.That(recovery.CompletedBinding!.Generation, Is.EqualTo(f.Snapshot.Generation));
        Assert.That(f.Bytes(), Is.EqualTo(new byte[] { 1, 2, 3 }));
    }
    [Test]
    public void MissingRecordCreatedBeforeInterruptionIsLegallyRemoved()
    {
        using var f = new RestoreFixture(missingIndex: true);
        var run = f.Transaction((phase, key) => { if (phase == RestoreStage.AfterCreate && key!.Index == 2) throw new SimulatedInterruption(); });
        Assert.Throws<SimulatedInterruption>(() => run.Run(f.Selection, f.SnapshotRoot, f.Intent));
        Assert.That(f.Nand.AllInfos().Count(i => i.Type == LibHac.Fs.SaveDataType.Account), Is.EqualTo(2));
        Assert.That(f.Transaction().RecoverIncomplete().Single().Status, Is.EqualTo(RestoreStatus.RolledBack));
        Assert.That(f.Nand.AllInfos().Count(i => i.Type == LibHac.Fs.SaveDataType.Account), Is.EqualTo(1));
    }
    [Test]
    public void BackupDurabilityFailureDoesNotMutateAnySave()
    {
        using var f = new RestoreFixture();
        f.Nand.Durable.Fail = true;
        Assert.Throws<IOException>(() => f.Transaction().Run(f.Selection, f.SnapshotRoot, f.Intent));
        f.Nand.Durable.Fail = false;
        Assert.That(f.Bytes(), Is.EqualTo(new byte[] { 8, 8, 8 }));
    }
    [Test]
    public void CancelBeforeMutationKeepsOriginalSave()
    {
        using var f = new RestoreFixture();
        var run = f.Transaction(); run.RequestSafeStop();
        RestoreOutcome result = run.Run(f.Selection, f.SnapshotRoot, f.Intent);
        Assert.That(result.Status, Is.EqualTo(RestoreStatus.RolledBack));
        Assert.That(f.Bytes(), Is.EqualTo(new byte[] { 8, 8, 8 }));
    }
    [Test]
    public void CancelAfterFirstCommitSafelyRollsBackAllRecords()
    {
        using var f = new RestoreFixture(); SaveRestoreTransaction? run = null;
        run = f.Transaction((phase, _) => { if (phase == RestoreStage.AfterCommit) run!.RequestSafeStop(); });
        Assert.That(run.Run(f.Selection, f.SnapshotRoot, f.Intent).Status, Is.EqualTo(RestoreStatus.RolledBack));
        Assert.That(f.Bytes(), Is.EqualTo(new byte[] { 8, 8, 8 }));
    }
}

internal sealed class CompletedWriteFailure(IDurableStore inner) : IDurableStore
{
    public void SyncTree(string root) => inner.SyncTree(root);
    public void SyncFile(string path) => inner.SyncFile(path);
    public void SyncDirectory(string path) => inner.SyncDirectory(path);
    public void WriteAtomic(string path, ReadOnlySpan<byte> bytes)
    {
        if (path.Contains("transactions") && System.Text.Encoding.UTF8.GetString(bytes).Contains("\"completed\":true")) throw new IOException("Injected completed write failure");
        inner.WriteAtomic(path, bytes);
    }
}

internal sealed class SimulatedInterruption : Exception;
internal sealed class RestoreFixture : IDisposable
{
    public SaveRepositoryFixture Nand { get; }
    public SaveSelection Selection { get; }
    public SaveSnapshot Snapshot { get; }
    public string SnapshotRoot { get; }
    public BindingIntent Intent { get; }
    public RestoreFixture(bool missingIndex = false)
    {
        Nand = SaveRepositoryFixture.Create(missingIndex ? [0] : [0, 2], true);
        Selection = Nand.Repository.Describe(Nand.TitleId, "fixture", Nand.LocalUserId);
        string old = Nand.Payload("original", new() { ["file"] = [8] });
        foreach (SaveKey key in Selection.Keys) using (var save = Nand.Repository.OpenWritable(key)) { save.ReplaceFrom(old); save.Commit(); }
        Guid generation = Guid.NewGuid();
        SnapshotRoot = Path.Combine(Nand.OwnedRoot, "staging", generation.ToString("D")); Directory.CreateDirectory(SnapshotRoot);
        var keys = new[] { new SaveKey(Nand.TitleId, Nand.LocalUserId, SaveKind.Account, 0),
            new SaveKey(Nand.TitleId, Nand.LocalUserId, SaveKind.Account, 2), new SaveKey(Nand.TitleId, "shared", SaveKind.Device, 0) };
        var records = new List<SaveRecordReference>();
        for (int index = 0; index < keys.Length; index++)
        {
            string payload = Nand.Payload("incoming" + index, new() { ["file"] = [(byte)(index + 1)] });
            using var logical = new DiskLogicalSave(payload);
            records.Add(SnapshotFiles.Export(SnapshotRoot, keys[index], generation, logical, CancellationToken.None));
        }
        Snapshot = new(1, generation, null, Nand.TitleId, Nand.LocalUserId, "2026-01-01T00:00:00Z", Guid.NewGuid(), 3, records);
        string manifest = SnapshotPaths.Contained(SnapshotRoot, SnapshotPaths.GameManifest(Nand.TitleId, generation));
        Directory.CreateDirectory(Path.GetDirectoryName(manifest)!); File.WriteAllBytes(manifest, SnapshotJson.Encode(Snapshot));
        Intent = new(Guid.NewGuid(), "iCloud.com.hick.MeloNX", Nand.TitleId, Nand.LocalUserId, Nand.LocalUserId, generation);
    }
    public SaveRestoreTransaction Transaction(Action<RestoreStage, SaveKey?>? observer = null) => new(Nand.Repository, Nand.Durable, Nand.OwnedRoot, () => long.MaxValue, observer);
    public byte[] Bytes()
    {
        var selection = Nand.Repository.Describe(Nand.TitleId, "fixture", Nand.LocalUserId);
        return selection.Keys.OrderBy(k => k.Kind).ThenBy(k => k.Index).Select(key => { using var save = Nand.Repository.OpenCommitted(key); byte[] b = new byte[1]; save.Read("file", 0, b); return b[0]; }).ToArray();
    }
    public void Dispose() => Nand.Dispose();
}
internal sealed class DiskLogicalSave(string root) : ILogicalSave
{
    public IEnumerable<SaveEntry> Entries() => SnapshotFiles.Scan(root, CancellationToken.None);
    public int Read(string path, long offset, Span<byte> buffer) { using var file = File.OpenRead(Path.Combine(root, path)); file.Position = offset; return file.Read(buffer); }
    public void ReplaceFrom(string path) => throw new InvalidOperationException();
    public void Commit() => throw new InvalidOperationException();
    public void Dispose() { }
}

internal sealed class CompletedSyncOrder(IDurableStore inner, Action assertSynced) : IDurableStore
{
    public void SyncTree(string root) => inner.SyncTree(root);
    public void SyncFile(string path) => inner.SyncFile(path);
    public void SyncDirectory(string path) => inner.SyncDirectory(path);
    public void WriteAtomic(string path, ReadOnlySpan<byte> bytes)
    {
        if (path.Contains("transactions") && System.Text.Encoding.UTF8.GetString(bytes).Contains("\"completed\":true")) assertSynced();
        inner.WriteAtomic(path, bytes);
    }
}
