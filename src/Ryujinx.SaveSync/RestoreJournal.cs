using System.Text.Json;

namespace Ryujinx.SaveSync;

public enum RestoreStatus { Completed, RolledBack, RecoveryRequired }
public enum RestoreStage { BeforeFirstMutation, AfterCreate, AfterCommit, AfterLastCommit, AfterCompleted }
public sealed record BindingIntent(Guid AccountKey, string Container, ulong TitleId, string LocalUserId, string CloudUserId, Guid Generation);
public sealed record RestoreOutcome(RestoreStatus Status, Guid TransactionId, BindingIntent? CompletedBinding, IReadOnlySet<ulong> BlockedGames);
public sealed record RestoreSlot(SaveKey Key, bool OriginalExists, ulong? OriginalId, bool MayHaveChanged);
public sealed record RestoreJournal(int SchemaVersion, Guid TransactionId, SaveSelection Selection,
    string SnapshotRelativeRoot, string BackupRelativeRoot, SaveSnapshot? BackupManifest,
    IReadOnlyList<RestoreSlot> Slots, BindingIntent BindingIntent, bool Completed, bool RolledBack, bool BindingApplied)
{
    public RestoreJournal WithMayHaveChanged(SaveKey key) => this with { Slots = Slots.Select(s => s.Key == key ? s with { MayHaveChanged = true } : s).ToArray() };
    public RestoreJournal WithCompleted(BindingIntent intent) => this with { Completed = true, BindingIntent = intent };
    public byte[] Encode()
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(this, SaveJsonContext.Default.RestoreJournal);
        if (bytes.Length > 65536) throw new SaveSyncException("malformedSnapshot");
        return bytes;
    }
    public static RestoreJournal Decode(byte[] bytes)
    {
        if (bytes.Length > 65536) throw new SaveSyncException("malformedSnapshot");
        var journal = JsonSerializer.Deserialize(bytes, SaveJsonContext.Default.RestoreJournal) ?? throw new SaveSyncException("malformedSnapshot");
        if (journal.SchemaVersion != 1 || journal.TransactionId == Guid.Empty || journal.Selection is null || journal.Slots is null ||
            journal.Slots.Count is < 1 or > 64 || journal.BindingIntent is null || journal.Completed && journal.RolledBack ||
            journal.BindingIntent.TitleId != journal.Selection.TitleId || journal.BindingIntent.LocalUserId != journal.Selection.LocalUserId ||
            journal.BindingIntent.AccountKey == Guid.Empty || journal.BindingIntent.Generation == Guid.Empty ||
            !SnapshotJson.IsHex(journal.BindingIntent.CloudUserId, 32) || string.IsNullOrEmpty(journal.BindingIntent.Container) ||
            journal.BindingIntent.Container.Length > 255 || journal.BindingApplied && !journal.Completed || journal.Selection.Keys is null)
            throw new SaveSyncException("malformedSnapshot");
        SnapshotPaths.Validate(journal.SnapshotRelativeRoot); SnapshotPaths.Validate(journal.BackupRelativeRoot);
        if (journal.SnapshotRelativeRoot != $"staging/{journal.BindingIntent.Generation:D}" ||
            journal.BackupRelativeRoot != $"backups/{journal.Selection.TitleId:x16}/{journal.TransactionId:D}/logical")
            throw new SaveSyncException("malformedSnapshot");
        var keys = new HashSet<SaveKey>();
        foreach (var slot in journal.Slots)
        {
            SnapshotJson.ValidateKey(slot.Key);
            if (!keys.Add(slot.Key) || slot.Key.ProgramId != journal.Selection.TitleId ||
                slot.Key.Kind == SaveKind.Account && slot.Key.UserId != journal.Selection.LocalUserId ||
                slot.OriginalExists != slot.OriginalId.HasValue) throw new SaveSyncException("malformedSnapshot");
        }
        if (journal.Selection.Keys.Count != keys.Count || !journal.Selection.Keys.ToHashSet().SetEquals(keys) ||
            journal.Completed && journal.Slots.Any(s => !s.MayHaveChanged)) throw new SaveSyncException("malformedSnapshot");
        var originallyExisting = journal.Slots.Where(s => s.OriginalExists).Select(s => s.Key).ToHashSet();
        if (originallyExisting.Count == 0)
        {
            if (journal.BackupManifest is not null) throw new SaveSyncException("malformedSnapshot");
        }
        else
        {
            if (journal.BackupManifest is null) throw new SaveSyncException("malformedSnapshot");
            SnapshotJson.Validate(journal.BackupManifest);
            if (journal.BackupManifest.Generation != journal.TransactionId || journal.BackupManifest.TitleID != journal.Selection.TitleId ||
                journal.BackupManifest.OwnerUserID != journal.Selection.LocalUserId ||
                !journal.BackupManifest.Records.Select(r => r.Key).ToHashSet().SetEquals(originallyExisting)) throw new SaveSyncException("malformedSnapshot");
        }
        return journal;
    }
}

