using System.Security.Cryptography;

namespace Ryujinx.SaveSync;

public sealed class SaveRestoreTransaction
{
    private readonly ISaveRepository _repository;
    private readonly IDurableStore _durable;
    private readonly string _root;
    private readonly Func<long> _space;
    private readonly Action<RestoreStage, SaveKey?>? _observer;
    private bool _notifying;
    private int _stop;
    public SaveRestoreTransaction(ISaveRepository repository, IDurableStore durable, string ownedRoot,
        Func<long>? availableSpace = null, Action<RestoreStage, SaveKey?>? observer = null)
    { _repository = repository; _durable = durable; _root = Path.GetFullPath(ownedRoot); _space = availableSpace ?? (() => SaveSpace.Available(ownedRoot)); _observer = observer; }
    public void RequestSafeStop() => Interlocked.Exchange(ref _stop, 1);
    private bool Stopping => Volatile.Read(ref _stop) != 0;
    private static RestoreOutcome Outcome(RestoreStatus status, Guid id, BindingIntent? intent = null, ulong? blocked = null) => new(status, id, intent, blocked.HasValue ? new HashSet<ulong> { blocked.Value } : new HashSet<ulong>());
    private void Notify(RestoreStage stage, SaveKey? key = null)
    {
        // Notifications are progress boundaries. An observer failure leaves the
        // durable journal for restart recovery, rather than claiming completion.
        _notifying = true; _observer?.Invoke(stage, key); _notifying = false;
    }
    public RestoreOutcome Run(SaveSelection selection, string snapshotRoot, BindingIntent bindingIntent)
    {
        if (Stopping) return Outcome(RestoreStatus.RolledBack, Guid.Empty);
        string expected = Path.Combine(_root, "staging", bindingIntent.Generation.ToString("D"));
        if (Path.GetFullPath(snapshotRoot) != expected) throw new SaveSyncException("malformedSnapshot");
        string manifestPath = SnapshotPaths.Contained(snapshotRoot, SnapshotPaths.GameManifest(selection.TitleId, bindingIntent.Generation));
        SaveSnapshot snapshot = SnapshotJson.DecodeSnapshot(SnapshotFiles.ReadManifest(manifestPath));
        if (snapshot.TitleID != selection.TitleId || snapshot.Generation != bindingIntent.Generation || snapshot.OwnerUserID != bindingIntent.CloudUserId ||
            bindingIntent.LocalUserId != selection.LocalUserId || bindingIntent.AccountKey == Guid.Empty || string.IsNullOrEmpty(bindingIntent.Container) ||
            bindingIntent.Container.Length > 255) throw new SaveSyncException("identityMismatch");
        SnapshotFiles.Verify(snapshotRoot, snapshot, CancellationToken.None);
        selection = _repository.AuthorizeRestore(selection, snapshot);
        Guid transaction = Guid.NewGuid();
        string backupRelative = $"backups/{selection.TitleId:x16}/{transaction:D}/logical";
        string backupRoot = Path.Combine(_root, backupRelative);
        Directory.CreateDirectory(backupRoot);
        var slots = selection.Keys.Select(key => { var mapping = _repository.FindMapping(key); return new RestoreSlot(key, mapping is not null, mapping?.LocalSaveDataId, false); }).ToArray();
        long originalBytes = 0;
        foreach (var slot in slots.Where(s => s.OriginalExists))
        {
            using var save = _repository.OpenCommitted(slot.Key);
            foreach (var entry in save.Entries()) if (!entry.IsDirectory) originalBytes = checked(originalBytes + entry.Length);
        }
        SaveSpace.Require(_space(), checked(originalBytes * 2 + snapshot.TotalBytes * 2));
        var backupRefs = new List<SaveRecordReference>();
        foreach (var slot in slots.Where(s => s.OriginalExists))
        {
            if (Stopping) return Outcome(RestoreStatus.RolledBack, transaction);
            using var save = _repository.OpenCommitted(slot.Key);
            backupRefs.Add(SnapshotFiles.Export(backupRoot, slot.Key, transaction, save, CancellationToken.None));
        }
        SaveSnapshot? backup = backupRefs.Count == 0 ? null : new SaveSnapshot(1, transaction, null, selection.TitleId,
            selection.LocalUserId, DateTime.UtcNow.ToString("O"), Guid.NewGuid(), originalBytes, backupRefs);
        if (backup is not null)
        {
            SnapshotFiles.Verify(backupRoot, backup, CancellationToken.None);
            string backupManifest = SnapshotPaths.Contained(backupRoot, SnapshotPaths.GameManifest(selection.TitleId, transaction));
            Directory.CreateDirectory(Path.GetDirectoryName(backupManifest)!); _durable.WriteAtomic(backupManifest, SnapshotJson.Encode(backup));
        }
        _durable.SyncTree(backupRoot);
        string directory = Path.Combine(_root, "transactions"); Directory.CreateDirectory(directory);
        string journalPath = Path.Combine(directory, transaction.ToString("D") + ".json");
        var journal = new RestoreJournal(1, transaction, selection, Path.GetRelativePath(_root, snapshotRoot), backupRelative,
            backup, slots, bindingIntent, false, false, false);
        _durable.WriteAtomic(journalPath, journal.Encode());
        try
        {
            Notify(RestoreStage.BeforeFirstMutation);
            foreach (var slot in journal.Slots.ToArray())
            {
                if (Stopping) return Rollback(journal, journalPath);
                SaveSpace.Require(_space(), snapshot.TotalBytes);
                journal = journal.WithMayHaveChanged(slot.Key); _durable.WriteAtomic(journalPath, journal.Encode());
                if (!slot.OriginalExists)
                {
                    _repository.CreateExact(slot.Key, selection.Control ?? throw new SaveSyncException("noSave"));
                    Notify(RestoreStage.AfterCreate, slot.Key);
                }
                SaveRecordReference reference = snapshot.Records.Single(r => r.Key.Kind == slot.Key.Kind && r.Key.Index == slot.Key.Index);
                string payload = Path.Combine(Path.GetDirectoryName(SnapshotPaths.Contained(snapshotRoot, reference.ManifestRelativePath))!, "payload");
                using (var save = _repository.OpenWritable(slot.Key)) { save.ReplaceFrom(payload); save.Commit(); }
                Notify(RestoreStage.AfterCommit, slot.Key);
            }
            if (Stopping) return Rollback(journal, journalPath);
            Notify(RestoreStage.AfterLastCommit);
            journal = journal.WithCompleted(bindingIntent); _durable.WriteAtomic(journalPath, journal.Encode());
            Notify(RestoreStage.AfterCompleted);
            return Outcome(RestoreStatus.Completed, transaction, bindingIntent);
        }
        catch (Exception) when (!_notifying) { return Rollback(journal with { Completed = false }, journalPath); }
    }
    public IReadOnlyList<RestoreOutcome> RecoverIncomplete()
    {
        string directory = Path.Combine(_root, "transactions");
        if (!Directory.Exists(directory)) return [];
        var results = new List<RestoreOutcome>();
        foreach (string previous in Directory.EnumerateFiles(directory, "*.json.previous"))
        {
            string target = previous[..^".previous".Length];
            RestoreJournal prior = RestoreJournal.Decode(SnapshotFiles.ReadManifest(previous));
            if (Path.GetFileName(target) != prior.TransactionId.ToString("D") + ".json") throw new SaveSyncException("malformedSnapshot");
            File.Move(previous, target, true); _durable.SyncTree(directory);
        }
        foreach (string path in Directory.EnumerateFiles(directory, "*.json"))
        {
            RestoreJournal journal = RestoreJournal.Decode(SnapshotFiles.ReadManifest(path));
            if (Path.GetFileName(path) != journal.TransactionId.ToString("D") + ".json") throw new SaveSyncException("malformedSnapshot");
            if (journal.Completed) { results.Add(Outcome(RestoreStatus.Completed, journal.TransactionId, journal.BindingApplied ? null : journal.BindingIntent)); continue; }
            if (journal.RolledBack) { results.Add(Outcome(RestoreStatus.RolledBack, journal.TransactionId)); continue; }
            results.Add(Rollback(journal, path));
        }
        return results;
    }
    public void CompleteBinding(Guid transactionId)
    {
        if (transactionId == Guid.Empty) throw new SaveSyncException("malformedSnapshot");
        string path = Path.Combine(_root, "transactions", transactionId.ToString("D") + ".json");
        var journal = RestoreJournal.Decode(SnapshotFiles.ReadManifest(path));
        if (!journal.Completed || journal.TransactionId != transactionId) throw new SaveSyncException("rollbackRequired");
        if (!journal.BindingApplied) _durable.WriteAtomic(path, (journal with { BindingApplied = true }).Encode());
    }
    private RestoreOutcome Rollback(RestoreJournal journal, string journalPath)
    {
        try
        {
            SaveSelection local = _repository.Describe(journal.Selection.TitleId, "", journal.Selection.LocalUserId);
            _repository.AuthorizeRecovery(local, journal.Slots.Select(s => s.Key).ToArray());
            string backupRoot = SnapshotPaths.Contained(_root, journal.BackupRelativeRoot);
            if (journal.BackupManifest is not null) SnapshotFiles.Verify(backupRoot, journal.BackupManifest, CancellationToken.None);
            foreach (var slot in journal.Slots.Where(s => s.MayHaveChanged))
            {
                if (!slot.OriginalExists) { _repository.DeleteExact(slot.Key); continue; }
                var mapping = _repository.FindMapping(slot.Key);
                if (mapping?.LocalSaveDataId != slot.OriginalId) throw new SaveSyncException("identityMismatch");
                var reference = journal.BackupManifest!.Records.Single(r => r.Key == slot.Key);
                string recordPath = SnapshotPaths.Contained(backupRoot, reference.ManifestRelativePath);
                string payload = Path.Combine(Path.GetDirectoryName(recordPath)!, "payload");
                using (var save = _repository.OpenWritable(slot.Key)) { save.ReplaceFrom(payload); save.Commit(); }
                VerifyLogical(slot.Key, SnapshotJson.DecodeRecord(SnapshotFiles.ReadManifest(recordPath)));
            }
            journal = journal with { RolledBack = true, Completed = false };
            _durable.WriteAtomic(journalPath, journal.Encode());
            return Outcome(RestoreStatus.RolledBack, journal.TransactionId);
        }
        catch { return Outcome(RestoreStatus.RecoveryRequired, journal.TransactionId, blocked: journal.Selection.TitleId); }
    }
    private void VerifyLogical(SaveKey key, SaveRecordManifest expected)
    {
        using var save = _repository.OpenCommitted(key);
        var entries = save.Entries().ToArray();
        var files = entries.Where(e => !e.IsDirectory).ToDictionary(e => e.Path, StringComparer.Ordinal);
        if (files.Count != expected.Files.Count) throw new SaveSyncException("restoreFailed");
        byte[] buffer = new byte[SnapshotFiles.BufferSize];
        foreach (var file in expected.Files)
        {
            if (!files.TryGetValue(file.Path, out var actual) || actual.Length != file.Length) throw new SaveSyncException("restoreFailed");
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256); long position = 0;
            while (position < file.Length)
            {
                int requested = (int)Math.Min(buffer.Length, file.Length - position);
                int read = save.Read(file.Path, position, buffer.AsSpan(0, requested));
                if (read <= 0 || read > requested) throw new SaveSyncException("restoreFailed");
                hash.AppendData(buffer, 0, read); position += read;
            }
            if (save.Read(file.Path, position, buffer.AsSpan(0, 1)) != 0 || Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant() != file.Sha256)
                throw new SaveSyncException("restoreFailed");
        }
        var empty = entries.Where(e => e.IsDirectory && !entries.Any(c => c.Path.StartsWith(e.Path + "/", StringComparison.Ordinal))).Select(e => e.Path).ToHashSet(StringComparer.Ordinal);
        if (!empty.SetEquals(expected.EmptyDirectories)) throw new SaveSyncException("restoreFailed");
    }
}
