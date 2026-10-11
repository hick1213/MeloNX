using LibHac.Ns;
using NUnit.Framework;
using Ryujinx.Library.SaveSync;
using Ryujinx.SaveSync;

namespace Ryujinx.SaveSync.Tests;

public class SaveContextTests
{
    [Test]
    public void CanonicalProgramRequiresUniqueBaseAndNeverUsesControlOwner()
    {
        Assert.That(SaveControlLoader.CanonicalProgram([new(0x100, false, true), new(0x900, true, true), new(0x101, false, true), new(0x999, false, false)]), Is.EqualTo(0x100UL));
        Assert.Throws<SaveSyncException>(() => SaveControlLoader.CanonicalProgram([new(0x999, false, false)]));
        Assert.Throws<SaveSyncException>(() => SaveControlLoader.CanonicalProgram([new(0x100, false, true), new(0x200, false, true)]));
        Assert.Throws<SaveSyncException>(() => SaveControlLoader.RequireProgram(0x999, 0x100));
        SaveControlLoader.RequireProgram(0x100, 0x100);
    }
    [Test]
    public void MissingControlDoesNotBypassProgramIdentityForExistingSaves()
    {
        using var f = SaveRepositoryFixture.Create([0], false);
        var valid = f.NewRepository(f.Durable, (requested, _) => {
            SaveControlLoader.RequireProgram(requested, f.TitleId); return null;
        });
        var selection = valid.Describe(f.TitleId, "confirmed-program-without-control", f.LocalUserId);
        Assert.That(selection.Keys.Count, Is.EqualTo(1)); Assert.That(selection.Control, Is.Null);
        Assert.That(selection.Keys.Single().ProgramId, Is.EqualTo(f.TitleId));
        var wrong = f.NewRepository(f.Durable, (requested, _) => {
            SaveControlLoader.RequireProgram(requested, f.TitleId + 0x1000); return null;
        });
        Assert.Throws<SaveSyncException>(() => wrong.Describe(f.TitleId, "different-program-without-control", f.LocalUserId));
        Assert.Throws<SaveSyncException>(() => wrong.OpenCommitted(selection.Keys.Single()));
    }
    [Test]
    public void ControlUsesOwnerFieldWithoutReplacingSelectedProgramId()
    {
        var control = new ApplicationControlProperty { SaveDataOwnerId = 0x999,
            UserAccountSaveDataSize = 0x4000, UserAccountSaveDataJournalSize = 0x8000,
            DeviceSaveDataSize = 0x4000, DeviceSaveDataJournalSize = 0x4000 };
        SaveCreateControl? result = SaveControlLoader.FromNacp(in control);
        Assert.That(result!.OwnerId, Is.EqualTo(0x999UL));
        Assert.That(result.AccountJournalSize, Is.EqualTo(0x8000));
        control.UserAccountSaveDataSize = -1;
        Assert.Throws<SaveSyncException>(() => SaveControlLoader.FromNacp(in control));
    }
    [Test]
    public void ExportBindsCloudIdentityAndParentButReadsOnlyCapturedLocalUser()
    {
        using var f = SaveRepositoryFixture.Create([0, 2], true);
        var context = new SaveContext(f.Repository, () => f.LocalUserId, f.OwnedRoot, f.Durable, () => long.MaxValue);
        var selection = context.ReadCurrentSaveSelection(f.TitleId, "fixture");
        Guid generation = Guid.NewGuid(), parent = Guid.NewGuid();
        var identity = new SaveExportIdentity("00000000000000000000000000000002", parent, generation, Guid.NewGuid(), "2026-01-01T00:00:00Z");
        string root = Path.Combine(f.OwnedRoot, "staging", generation.ToString("D"));
        SaveSnapshot snapshot = context.ExportSelection(selection, identity, root, CancellationToken.None);
        Assert.That(snapshot.OwnerUserID, Is.EqualTo("00000000000000000000000000000002"));
        Assert.That(snapshot.Parent, Is.EqualTo(parent));
        Assert.That(snapshot.Records.Where(r => r.Key.Kind == SaveKind.Account).All(r => r.Key.UserId == identity.CloudUserID), Is.True);
        Assert.That(snapshot.Records.Single(r => r.Key.Kind == SaveKind.Device).Key.UserId, Is.EqualTo("shared"));
        SnapshotFiles.Verify(root, snapshot, CancellationToken.None);
        string json = System.Text.Encoding.UTF8.GetString(SnapshotJson.Encode(snapshot));
        Assert.That(json, Does.Not.Contain("saveDataId").IgnoreCase);
    }
    [Test]
    public void UserSwitchInvalidatesCapturedSelectionBeforeExport()
    {
        using var f = SaveRepositoryFixture.Create([0], false);
        string user = f.LocalUserId;
        var context = new SaveContext(f.Repository, () => user, f.OwnedRoot, f.Durable, () => long.MaxValue);
        var selection = context.ReadCurrentSaveSelection(f.TitleId, "fixture");
        user = "00000000000000000000000000000002";
        var identity = new SaveExportIdentity(selection.LocalUserId, null, Guid.NewGuid(), Guid.NewGuid(), "2026-01-01T00:00:00Z");
        Assert.Throws<SaveSyncException>(() => context.ExportSelection(selection, identity,
            Path.Combine(f.OwnedRoot, "staging", identity.Generation.ToString("D")), CancellationToken.None));
    }
}
