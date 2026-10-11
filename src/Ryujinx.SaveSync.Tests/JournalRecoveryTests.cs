using NUnit.Framework;
using Ryujinx.SaveSync;

namespace Ryujinx.SaveSync.Tests;

public class JournalRecoveryTests
{
    [Test]
    public void JournalCannotRedirectBackupOrChangeCapturedSlotScope()
    {
        using var f = new RestoreFixture();
        var run = f.Transaction((stage, _) => { if (stage == RestoreStage.AfterCommit) throw new SimulatedInterruption(); });
        Assert.Throws<SimulatedInterruption>(() => run.Run(f.Selection, f.SnapshotRoot, f.Intent));
        string path = Directory.GetFiles(Path.Combine(f.Nand.OwnedRoot, "transactions"), "*.json").Single();
        var journal = RestoreJournal.Decode(File.ReadAllBytes(path));
        var changed = journal with { BackupRelativeRoot = "staging/" + f.Snapshot.Generation.ToString("D") };
        Assert.Throws<SaveSyncException>(() => RestoreJournal.Decode(changed.Encode()));
        changed = journal with { Selection = journal.Selection with { Keys = [] } };
        Assert.Throws<SaveSyncException>(() => RestoreJournal.Decode(changed.Encode()));
    }
    [Test]
    public void AppliedBindingIsAcknowledgedDurablyAndNotOfferedAgain()
    {
        using var f = new RestoreFixture();
        var run = f.Transaction(); var result = run.Run(f.Selection, f.SnapshotRoot, f.Intent);
        run.CompleteBinding(result.TransactionId);
        Assert.That(f.Transaction().RecoverIncomplete().Single().CompletedBinding, Is.Null);
    }
    [Test]
    public void KnownJournalRecoversInterruptedPhysicalCommitWithoutUploadingWorkingData()
    {
        using var f = new RestoreFixture();
        var run = f.Transaction((phase, _) => { if (phase == RestoreStage.AfterCommit) throw new SimulatedInterruption(); });
        Assert.Throws<SimulatedInterruption>(() => run.Run(f.Selection, f.SnapshotRoot, f.Intent));
        string raw = f.Nand.PhysicalDir(f.Selection.Keys.First());
        Directory.Move(Path.Combine(raw, "0"), Path.Combine(raw, "_"));
        Assert.That(f.Transaction().RecoverIncomplete().Single().Status, Is.EqualTo(RestoreStatus.RolledBack));
        Assert.That(f.Bytes(), Is.EqualTo(new byte[] { 8, 8, 8 }));
    }
}
