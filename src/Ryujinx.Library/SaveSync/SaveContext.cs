#nullable enable
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Threading;
using Ryujinx.SaveSync;

namespace Ryujinx.Library.SaveSync;

public sealed class SaveContext
{
    public ISaveRepository Repository { get; }
    public string OwnedRoot { get; }
    private readonly Func<string> _currentUser;
    private readonly IDurableStore _durable;
    private readonly Func<long> _space;
    private SaveSelection? _captured;
    private string? _gamePath;
    private Dictionary<SaveKey, ulong?> _mappings = [];
    public SaveContext(ISaveRepository repository, Func<string> currentUser, string ownedRoot,
        IDurableStore durable, Func<long>? availableSpace = null)
    { Repository = repository; _currentUser = currentUser; OwnedRoot = ownedRoot; _durable = durable; _space = availableSpace ?? (() => SaveSpace.Available(ownedRoot)); }

    public SaveSelection ReadCurrentSaveSelection(ulong titleId, string gamePath)
    {
        SaveSelection selection = Repository.Describe(titleId, gamePath, _currentUser());
        _captured = selection; _gamePath = gamePath;
        _mappings = selection.Keys.ToDictionary(k => k, k => Repository.FindMapping(k)?.LocalSaveDataId);
        return selection;
    }
    public SaveSelection ValidateCurrentSelection(SaveSelection selection)
    {
        if (_captured?.Id != selection.Id || _currentUser() != selection.LocalUserId || _gamePath is null) throw new SaveSyncException("identityMismatch");
        SaveSelection fresh = Repository.Describe(selection.TitleId, _gamePath, selection.LocalUserId);
        if (!fresh.Keys.ToHashSet().SetEquals(selection.Keys) || fresh.Control != selection.Control) throw new SaveSyncException("identityMismatch");
        foreach (SaveKey key in fresh.Keys)
            if (!_mappings.TryGetValue(key, out ulong? id) || Repository.FindMapping(key)?.LocalSaveDataId != id) throw new SaveSyncException("identityMismatch");
        return fresh;
    }
    public SaveSnapshot ExportSelection(SaveSelection selection, SaveExportIdentity identity, string localRoot, CancellationToken ct)
    {
        SaveSelection fresh = ValidateCurrentSelection(selection);
        if (fresh.Keys.Count == 0) throw new SaveSyncException("noSave");
        string expectedRoot = Path.GetFullPath(Path.Combine(OwnedRoot, "staging", identity.Generation.ToString("D")));
        if (Path.GetFullPath(localRoot) != expectedRoot || identity.Generation == Guid.Empty || identity.Parent == identity.Generation ||
            !SnapshotJson.IsHex(identity.CloudUserID, 32) || identity.InstallationID == Guid.Empty) throw new SaveSyncException("malformedSnapshot");
        long total = 0;
        // Logical opens are guarded by their own pre-open raw backup and space
        // checks; account/device logical content stays under the same local lease.
        foreach (SaveKey key in fresh.Keys)
        {
            ct.ThrowIfCancellationRequested();
            using var save = Repository.OpenCommitted(key);
            foreach (var entry in save.Entries()) if (!entry.IsDirectory) total = checked(total + entry.Length);
        }
        SaveSpace.Require(_space(), checked(total * 2));
        Directory.CreateDirectory(localRoot);
        var refs = new List<SaveRecordReference>();
        foreach (SaveKey key in fresh.Keys)
        {
            ct.ThrowIfCancellationRequested(); SaveSpace.Require(_space(), total);
            using var save = Repository.OpenCommitted(key);
            var cloudKey = key.Kind == SaveKind.Account ? key with { UserId = identity.CloudUserID } : key;
            refs.Add(SnapshotFiles.Export(localRoot, cloudKey, identity.Generation, save, ct));
        }
        var snapshot = new SaveSnapshot(1, identity.Generation, identity.Parent, selection.TitleId,
            identity.CloudUserID, identity.CreatedUTC, identity.InstallationID, total, refs);
        SnapshotFiles.Verify(localRoot, snapshot, ct);
        string manifest = SnapshotPaths.Contained(localRoot, SnapshotPaths.GameManifest(snapshot.TitleID, snapshot.Generation));
        Directory.CreateDirectory(Path.GetDirectoryName(manifest)!);
        _durable.WriteAtomic(manifest, SnapshotJson.Encode(snapshot)); _durable.SyncTree(localRoot);
        return snapshot;
    }
}
