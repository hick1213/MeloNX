#nullable enable
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Threading;
using System.Globalization;
using System.Security.Cryptography;
using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Fs.Impl;
using LibHac.Fs.Shim;
using LibHac.Ncm;
using LibHac.Tools.FsSystem;
using Ryujinx.SaveSync;
using FsPath = LibHac.Fs.Path;
using HostPath = System.IO.Path;

namespace Ryujinx.Library.SaveSync;

public sealed class LibHacSaveRepository : ISaveRepository
{
    private readonly FileSystemClient _fs;
    private readonly string _physicalRoot;
    private readonly string _ownedRoot;
    private readonly IDurableStore _durable;
    private readonly Func<ulong, string, SaveCreateControl?> _loadControl;
    private readonly Func<long> _availableSpace;
    private readonly HashSet<SaveKey> _allowed = [];
    private readonly Dictionary<SaveKey, ulong> _known = [];
    private readonly HashSet<ulong> _preopened = [];
    private SaveSelection? _selection;
    private bool _recovering;
    public LibHacSaveRepository(FileSystemClient fs, string userSaveRoot, string ownedRoot,
        IDurableStore durable, Func<ulong, string, SaveCreateControl?> loadControl, Func<long>? availableSpace = null)
    { _fs = fs; _physicalRoot = userSaveRoot; _ownedRoot = ownedRoot; _durable = durable; _loadControl = loadControl; _availableSpace = availableSpace ?? (() => SaveSpace.Available(ownedRoot)); }

    public SaveSelection Describe(ulong titleId, string gamePath, string currentUser)
    {
        SnapshotJson.ValidateKey(new SaveKey(titleId, currentUser, SaveKind.Account, 0));
        _allowed.Clear(); _known.Clear(); _preopened.Clear(); _recovering = false;
        foreach (SaveDataInfo info in Enumerate())
        {
            var key = SelectKey(info, titleId, currentUser);
            if (key is null) continue;
            if (!_allowed.Add(key) || !_known.TryAdd(key, info.SaveDataId)) throw new SaveSyncException("identityMismatch");
        }
        if (_allowed.Count > 64) throw new SaveSyncException("malformedSnapshot");
        _selection = new SaveSelection(Guid.NewGuid(), titleId, currentUser,
            _allowed.OrderBy(k => k.Kind).ThenBy(k => k.Index).ToArray(), _loadControl(titleId, gamePath));
        return _selection;
    }
    public SaveSelection AuthorizeRestore(SaveSelection selection, SaveSnapshot snapshot)
    {
        SnapshotJson.Validate(snapshot);
        if (_selection?.Id != selection.Id || selection.TitleId != snapshot.TitleID ||
            _selection.LocalUserId != selection.LocalUserId) throw new SaveSyncException("identityMismatch");
        var keys = snapshot.Records.Select(r => r.Key.Kind == SaveKind.Account ? r.Key with { UserId = selection.LocalUserId } : r.Key).ToArray();
        _allowed.Clear(); _allowed.UnionWith(keys);
        _selection = selection with { Keys = keys };
        return _selection;
    }
    public bool Exists(SaveKey key) => FindMapping(key) is not null;
    public void AuthorizeRecovery(SaveSelection selection, IReadOnlyList<SaveKey> keys)
    {
        if (_selection?.Id != selection.Id || keys.Count is < 1 or > 64 || keys.Distinct().Count() != keys.Count)
            throw new SaveSyncException("identityMismatch");
        foreach (var key in keys)
        {
            SnapshotJson.ValidateKey(key);
            if (key.ProgramId != selection.TitleId || key.Kind == SaveKind.Account && key.UserId != selection.LocalUserId)
                throw new SaveSyncException("identityMismatch");
        }
        _allowed.Clear(); _allowed.UnionWith(keys); _selection = selection with { Keys = keys }; _recovering = true;
    }
    public SaveMapping? FindMapping(SaveKey key)
    {
        AuthorizeKey(key);
        SaveDataInfo? found = FindInfo(key);
        if (found is null) { if (_known.ContainsKey(key)) throw new SaveSyncException("identityMismatch"); return null; }
        if (_known.TryGetValue(key, out ulong expected) && found.Value.SaveDataId != expected) throw new SaveSyncException("identityMismatch");
        return new(key, found.Value.SaveDataId);
    }
    public ILogicalSave OpenCommitted(SaveKey key) => Open(key, readOnly: true);
    public ILogicalSave OpenWritable(SaveKey key) => Open(key, readOnly: false);
    private ILogicalSave Open(SaveKey key, bool readOnly)
    {
        var mapping = FindMapping(key) ?? throw new SaveSyncException("noSave");
        BackupBeforeOpen(mapping);
        var attribute = Attribute(key);
        using var proxy = _fs.Impl.GetFileSystemProxyServiceObject();
        using var service = new SharedRef<LibHac.FsSrv.Sf.IFileSystem>();
        Result result = readOnly ? proxy.Get.OpenReadOnlySaveDataFileSystem(ref service.Ref, SaveDataSpaceId.User, in attribute) :
            proxy.Get.OpenSaveDataFileSystem(ref service.Ref, SaveDataSpaceId.User, in attribute);
        result.ThrowIfFailure();
        using var filesystem = new SharedRef<IFileSystem>();
        service.Get.GetImpl(ref filesystem.Ref).ThrowIfFailure();
        return new LogicalSave(in filesystem, readOnly);
    }
    public SaveMapping CreateExact(SaveKey key, SaveCreateControl control)
    {
        AuthorizeKey(key);
        if (_selection?.Control != control || control.OwnerId == 0 || FindInfo(key) is not null) throw new SaveSyncException("identityMismatch");
        long size = key.Kind == SaveKind.Account ? control.AccountSize : control.DeviceSize;
        long journal = key.Kind == SaveKind.Account ? control.AccountJournalSize : control.DeviceJournalSize;
        if (size <= 0 || journal < 0) throw new SaveSyncException("noSave");
        var attribute = Attribute(key);
        SaveDataCreationInfo.Make(out var creation, size, journal, control.OwnerId, (SaveDataFlags)control.Flags, SaveDataSpaceId.User).ThrowIfFailure();
        // The shipped LibHac policy is internal; Account/Device use its SDK
        // thumbnail metadata contract (0x40060), with reserved fields zeroed.
        var meta = new SaveDataMetaInfo { Type = SaveDataMetaType.Thumbnail, Size = 0x40060 };
        using var proxy = _fs.Impl.GetFileSystemProxyServiceObject();
        proxy.Get.CreateSaveDataFileSystem(in attribute, in creation, in meta).ThrowIfFailure();
        SaveDataInfo info = FindInfo(key) ?? throw new SaveSyncException("restoreFailed");
        _known[key] = info.SaveDataId;
        return new(key, info.SaveDataId);
    }
    public void DeleteExact(SaveKey key)
    {
        var mapping = FindMapping(key);
        if (mapping is null) return;
        _fs.Impl.DeleteSaveData(SaveDataSpaceId.User, mapping.LocalSaveDataId).ThrowIfFailure();
        _known.Remove(key); _preopened.Remove(mapping.LocalSaveDataId);
    }
    private void AuthorizeKey(SaveKey key)
    {
        SnapshotJson.ValidateKey(key);
        if (_selection is null || !_allowed.Contains(key) || key.ProgramId != _selection.TitleId ||
            key.Kind == SaveKind.Account && key.UserId != _selection.LocalUserId) throw new SaveSyncException("identityMismatch");
    }
    private SaveDataInfo? FindInfo(SaveKey key)
    {
        SaveDataInfo? found = null;
        foreach (SaveDataInfo info in Enumerate())
        {
            if (SelectKey(info, key.ProgramId, _selection!.LocalUserId) != key) continue;
            if (found is not null) throw new SaveSyncException("rollbackRequired");
            found = info;
        }
        return found;
    }
    private IEnumerable<SaveDataInfo> Enumerate()
    {
        using var iterator = new UniqueRef<SaveDataIterator>();
        _fs.OpenSaveDataIterator(ref iterator.Ref, SaveDataSpaceId.User).ThrowIfFailure();
        var page = new SaveDataInfo[16]; int total = 0;
        while (true)
        {
            iterator.Get.ReadSaveDataInfo(out long count, page).ThrowIfFailure();
            if (count < 0 || count > page.Length || (total += (int)count) > 100000) throw new SaveSyncException("malformedSnapshot");
            if (count == 0) yield break;
            for (int i = 0; i < count; i++) yield return page[i];
        }
    }
    private static SaveKey ToKey(SaveDataInfo info) => new(info.ProgramId.Value,
        info.Type == SaveDataType.Account ? info.UserId.ToString().ToLowerInvariant() : "shared",
        info.Type == SaveDataType.Account ? SaveKind.Account : SaveKind.Device, info.Index);
    internal static SaveKey? SelectKey(SaveDataInfo info, ulong titleId, string currentUser)
    {
        if (info.ProgramId.Value != titleId || info.Rank != SaveDataRank.Primary ||
            info.Type is not (SaveDataType.Account or SaveDataType.Device)) return null;
        if (info.Type == SaveDataType.Account && info.UserId.ToString().ToLowerInvariant() != currentUser) return null;
        if (info.State != SaveDataState.Normal) throw new SaveSyncException("rollbackRequired");
        return ToKey(info);
    }
    private static SaveDataAttribute Attribute(SaveKey key)
    {
        var user = key.Kind == SaveKind.Device ? default : new LibHac.Fs.UserId(
            ulong.Parse(key.UserId[..16], NumberStyles.HexNumber, CultureInfo.InvariantCulture),
            ulong.Parse(key.UserId[16..], NumberStyles.HexNumber, CultureInfo.InvariantCulture));
        SaveDataAttribute.Make(out var result, new ProgramId(key.ProgramId), key.Kind == SaveKind.Account ? SaveDataType.Account : SaveDataType.Device,
            user, 0, key.Index, SaveDataRank.Primary).ThrowIfFailure();
        return result;
    }
    private void BackupBeforeOpen(SaveMapping mapping)
    {
        if (_preopened.Contains(mapping.LocalSaveDataId)) return;
        string raw = HostPath.Combine(_physicalRoot, mapping.LocalSaveDataId.ToString("x16"));
        if (!_recovering && (!Directory.Exists(HostPath.Combine(raw, "0")) ||
            Directory.Exists(HostPath.Combine(raw, "_")) || File.Exists(HostPath.Combine(raw, "_")) ||
            Directory.Exists(HostPath.Combine(raw, "ExtraData_")) || File.Exists(HostPath.Combine(raw, "ExtraData_"))))
            throw new SaveSyncException("rollbackRequired");
        if (_recovering && !Directory.Exists(HostPath.Combine(raw, "0")) && !Directory.Exists(HostPath.Combine(raw, "1")))
            throw new SaveSyncException("rollbackRequired");
        long required = 0, workspace = 0;
        foreach (string name in new[] { "0", "1", "ExtraData0", "ExtraData1", "_", "ExtraData_" })
        {
            string path = HostPath.Combine(raw, name);
            if (Directory.Exists(path))
            {
                foreach (var file in SnapshotFiles.Scan(path, CancellationToken.None).Where(e => !e.IsDirectory))
                { required = checked(required + file.Length); if (name == "0") workspace = checked(workspace + file.Length); }
            }
            else if (File.Exists(path)) required = checked(required + new FileInfo(path).Length);
        }
        SaveSpace.Require(_availableSpace(), checked(required + workspace));
        string backup = HostPath.Combine(_ownedRoot, "backups", mapping.Key.ProgramId.ToString("x16"), Guid.NewGuid().ToString("D"), "preopen", mapping.LocalSaveDataId.ToString("x16"));
        Directory.CreateDirectory(backup);
        foreach (string name in new[] { "0", "1", "ExtraData0", "ExtraData1", "_", "ExtraData_" })
        {
            string source = HostPath.Combine(raw, name), target = HostPath.Combine(backup, name);
            if (Directory.Exists(source))
            {
                Directory.CreateDirectory(target);
                foreach (var entry in SnapshotFiles.Scan(source, CancellationToken.None))
                {
                    string destination = SnapshotPaths.Contained(target, entry.Path);
                    if (entry.IsDirectory) Directory.CreateDirectory(destination);
                    else { SaveSpace.Require(_availableSpace(), entry.Length); Directory.CreateDirectory(HostPath.GetDirectoryName(destination)!); CopyRawFile(SnapshotPaths.Contained(source, entry.Path), destination); }
                }
            }
            else if (File.Exists(source)) CopyRawFile(source, target);
        }
        _durable.SyncTree(backup);
        _preopened.Add(mapping.LocalSaveDataId);
    }
    private static void CopyRawFile(string source, string target)
    {
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, SnapshotFiles.BufferSize);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[SnapshotFiles.BufferSize];
        using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, SnapshotFiles.BufferSize))
        {
            int read;
            while ((read = input.Read(buffer)) > 0) { hash.AppendData(buffer, 0, read); output.Write(buffer, 0, read); }
            output.Flush(true);
        }
        byte[] expected = hash.GetHashAndReset();
        using var copied = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.Read, SnapshotFiles.BufferSize);
        if (!CryptographicOperations.FixedTimeEquals(expected, SHA256.HashData(copied))) throw new SaveSyncException("restoreFailed");
    }

    private sealed class LogicalSave : ILogicalSave
    {
        private SharedRef<IFileSystem> _logical;
        private readonly bool _readOnly;
        public LogicalSave(in SharedRef<IFileSystem> logical, bool readOnly) { _logical.SetByCopy(in logical); _readOnly = readOnly; }
        public IEnumerable<SaveEntry> Entries()
        {
            int total = 0;
            foreach (var entry in _logical.Get.EnumerateEntries("/", "*", SearchOptions.RecurseSubdirectories))
            {
                if (++total > 100000) throw new SaveSyncException("malformedSnapshot");
                string relative = entry.FullPath.TrimStart('/'); SnapshotPaths.Validate(relative);
                yield return new(relative, entry.Type == DirectoryEntryType.Directory, entry.Size);
            }
        }
        public int Read(string path, long offset, Span<byte> buffer)
        {
            SnapshotPaths.Validate(path);
            using var file = new UniqueRef<IFile>();
            _logical.Get.OpenFile(ref file.Ref, ("/" + path).ToU8Span(), OpenMode.Read).ThrowIfFailure();
            file.Get.Read(out long read, offset, buffer, ReadOption.None).ThrowIfFailure();
            return checked((int)read);
        }
        public void ReplaceFrom(string localPayload)
        {
            if (_readOnly) throw new SaveSyncException("restoreFailed");
            var entries = SnapshotFiles.Scan(localPayload, CancellationToken.None).ToArray();
            using var rootPath = new FsPath(); rootPath.InitializeWithNormalization("/"u8).ThrowIfFailure();
            _logical.Get.CleanDirectoryRecursively(in rootPath).ThrowIfFailure();
            foreach (var directory in entries.Where(e => e.IsDirectory).OrderBy(e => e.Path.Count(c => c == '/')))
            {
                using var path = new FsPath(); path.InitializeWithNormalization(("/" + directory.Path).ToU8Span()).ThrowIfFailure();
                _logical.Get.CreateDirectory(in path).ThrowIfFailure();
            }
            byte[] buffer = new byte[SnapshotFiles.BufferSize];
            foreach (var entry in entries.Where(e => !e.IsDirectory))
            {
                string path = "/" + entry.Path;
                using var filePath = new FsPath(); filePath.InitializeWithNormalization(path.ToU8Span()).ThrowIfFailure();
                _logical.Get.CreateFile(in filePath, entry.Length).ThrowIfFailure();
                using var target = new UniqueRef<IFile>();
                _logical.Get.OpenFile(ref target.Ref, path.ToU8Span(), OpenMode.Write).ThrowIfFailure();
                target.Get.SetSize(entry.Length).ThrowIfFailure();
                using var source = new FileStream(SnapshotPaths.Contained(localPayload, entry.Path), FileMode.Open, FileAccess.Read, FileShare.Read, SnapshotFiles.BufferSize);
                long offset = 0; int read;
                while ((read = source.Read(buffer)) > 0) { target.Get.Write(offset, buffer.AsSpan(0, read), WriteOption.None).ThrowIfFailure(); offset += read; }
                if (offset != entry.Length) throw new SaveSyncException("malformedSnapshot");
                target.Get.Flush().ThrowIfFailure();
            }
        }
        public void Commit() { if (_readOnly) throw new SaveSyncException("restoreFailed"); _logical.Get.Commit().ThrowIfFailure(); }
        public void Dispose() => _logical.Destroy();
    }
}
