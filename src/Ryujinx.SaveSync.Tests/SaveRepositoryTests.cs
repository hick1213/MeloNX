using LibHac;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Fs.Shim;
using LibHac.Fs.Impl;
using LibHac.FsSrv;
using LibHac.FsSrv.Impl;
using LibHac.FsSystem;
using LibHac.Ncm;
using NUnit.Framework;
using Ryujinx.Library.SaveSync;
using Ryujinx.SaveSync;
using FsPath = LibHac.Fs.Path;

namespace Ryujinx.SaveSync.Tests;

public class SaveRepositoryTests
{
    [Test]
    public void NonNormalIndexMetadataCannotBeSelectedAsCommittedSave()
    {
        var info = new SaveDataInfo { ProgramId = new ProgramId(0x100), Type = SaveDataType.Account,
            UserId = new LibHac.Fs.UserId(0, 1), Index = 0, Rank = SaveDataRank.Primary,
            State = (SaveDataState)255 };
        Assert.Throws<SaveSyncException>(() => LibHacSaveRepository.SelectKey(info, 0x100, "00000000000000000000000000000001"));
    }
    [Test]
    public void SameLogicalKeyCanMapToDifferentPhysicalIdsOnAnotherDevice()
    {
        using var a = SaveRepositoryFixture.Create([], false);
        a.CreateSave(new SaveKey(0x200, a.LocalUserId, SaveKind.Account, 0));
        a.CreateSave(new SaveKey(a.TitleId, a.LocalUserId, SaveKind.Account, 0));
        using var b = SaveRepositoryFixture.Create([0], false);
        var left = a.Repository.Describe(a.TitleId, "fixture", a.LocalUserId).Keys.Single();
        var right = b.Repository.Describe(b.TitleId, "fixture", b.LocalUserId).Keys.Single();
        Assert.That(left, Is.EqualTo(right));
        Assert.That(a.Repository.FindMapping(left)!.LocalSaveDataId, Is.Not.EqualTo(b.Repository.FindMapping(right)!.LocalSaveDataId));
    }
    [Test]
    public void SecondaryRankDoesNotBecomeCommittedPrimaryExport()
    {
        using var f = SaveRepositoryFixture.Create([0], false);
        f.CreateSave(new SaveKey(f.TitleId, f.LocalUserId, SaveKind.Account, 2), SaveDataRank.Secondary);
        var selection = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        Assert.That(selection.Keys.Select(k => k.Index), Is.EqualTo(new ushort[] { 0 }));
    }
    [Test]
    public void UnfinishedExtraDataStageBlocksLogicalMount()
    {
        using var f = SaveRepositoryFixture.Create([0], false);
        var selection = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        string transient = System.IO.Path.Combine(f.PhysicalDir(selection.Keys.Single()), "ExtraData_");
        File.WriteAllBytes(transient, [1]);
        Assert.Throws<SaveSyncException>(() => f.Repository.OpenCommitted(selection.Keys.Single()));
        Assert.That(File.ReadAllBytes(transient), Is.EqualTo(new byte[] { 1 }));
    }
    [Test]
    public void LowSpaceFailsBeforeMountOrCreatingBackup()
    {
        using var f = SaveRepositoryFixture.Create([0], false);
        var selection = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        f.AvailableBytes = 16 * 1024 * 1024;
        Assert.Throws<SaveSyncException>(() => f.Repository.OpenCommitted(selection.Keys.Single()));
        Assert.That(Directory.Exists(System.IO.Path.Combine(f.OwnedRoot, "backups")), Is.False);
    }
    [Test]
    public void EnumerationFindsAccountDeviceAndNonzeroIndexWithoutOtherUser()
    {
        using var f = SaveRepositoryFixture.Create([0, 2], true);
        f.CreateSave(new SaveKey(f.TitleId, "00000000000000000000000000000002", SaveKind.Account, 0));
        SaveSelection selection = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        Assert.That(selection.Keys.Where(k => k.Kind == SaveKind.Account).Select(k => k.Index), Is.EquivalentTo(new ushort[] { 0, 2 }));
        Assert.That(selection.Keys.Single(k => k.Kind == SaveKind.Device).UserId, Is.EqualTo("shared"));
        Assert.That(selection.Keys.Where(k => k.Kind == SaveKind.Account).All(k => k.UserId == f.LocalUserId), Is.True);
    }
    [Test]
    public void AuthorizeRestoreMapsCloudUserAndKeepsNonzeroIndex()
    {
        using var f = SaveRepositoryFixture.Create([0, 2], true);
        SaveSelection selection = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        SaveSelection mapped = f.Repository.AuthorizeRestore(selection, f.SnapshotForOtherUser());
        Assert.That(mapped.Keys.Where(k => k.Kind == SaveKind.Account).Select(k => k.Index), Is.EquivalentTo(new ushort[] { 0, 2 }));
        Assert.That(mapped.Keys.Where(k => k.Kind == SaveKind.Account).All(k => k.UserId == f.LocalUserId), Is.True);
        Assert.That(mapped.Keys.Single(k => k.Kind == SaveKind.Device).UserId, Is.EqualTo("shared"));
    }
    [Test]
    public void ExactCreateDoesNotCreateBcatOrTemporaryOrReplaceProgramIdWithOwner()
    {
        using var f = SaveRepositoryFixture.Create([], false);
        var original = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        var mapped = f.Repository.AuthorizeRestore(original, f.SnapshotForOtherUser(accountIndexes: [2], device: false));
        var created = f.Repository.CreateExact(mapped.Keys.Single(), f.Control);
        Assert.That(created.Key.ProgramId, Is.EqualTo(f.TitleId));
        Assert.That(f.AllInfos().Select(i => i.Type), Is.EqualTo(new[] { SaveDataType.Account }));
        Assert.That(f.AllInfos().Single().Index, Is.EqualTo(2));
        Assert.That(f.AllInfos().Single().ProgramId.Value, Is.EqualTo(f.TitleId));
    }
    [Test]
    public void LogicalRestoreTruncatesAndRemovesExtraEntriesThenCommitPersists()
    {
        using var f = SaveRepositoryFixture.Create([0], false);
        var selection = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        var key = selection.Keys.Single();
        string oldRoot = f.Payload("old", new Dictionary<string, byte[]> { ["file"] = [1, 2, 3, 4, 5], ["extra"] = [9] });
        using (var save = f.Repository.OpenWritable(key)) { save.ReplaceFrom(oldRoot); save.Commit(); }
        string fresh = f.Payload("new", new Dictionary<string, byte[]> { ["file"] = [6], ["extra/child"] = [7] });
        Directory.CreateDirectory(System.IO.Path.Combine(fresh, "empty/sub"));
        using (var save = f.Repository.OpenWritable(key)) { save.ReplaceFrom(fresh); save.Commit(); }
        using var read = f.Repository.OpenCommitted(key);
        Assert.That(read.Entries().Single(e => e.Path == "file").Length, Is.EqualTo(1));
        Assert.That(read.Entries().Any(e => e.Path == "extra" && e.IsDirectory), Is.True);
        byte[] bytes = new byte[8]; Assert.That(read.Read("file", 0, bytes), Is.EqualTo(1)); Assert.That(bytes[0], Is.EqualTo(6));
        Assert.That(read.Entries().Any(e => e.Path == "empty/sub" && e.IsDirectory), Is.True);
    }
    [Test]
    public void ReadOnlyMountBacksUpWorkingStateBeforeLibHacDiscardsIt()
    {
        using var f = SaveRepositoryFixture.Create([0], false);
        var selection = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        string dir = f.PhysicalDir(selection.Keys.Single());
        Directory.CreateDirectory(System.IO.Path.Combine(dir, "1"));
        File.WriteAllBytes(System.IO.Path.Combine(dir, "1", "uncommitted"), [8, 9]);
        using var read = f.Repository.OpenCommitted(selection.Keys.Single());
        Assert.That(Directory.EnumerateFiles(f.OwnedRoot, "uncommitted", SearchOption.AllDirectories).Any(), Is.True);
        Assert.That(read.Entries().Any(e => e.Path == "uncommitted"), Is.False);
        Assert.That(f.Durable.Synced.Count, Is.GreaterThan(0));
    }
    [Test]
    public void FailedPreopenDurabilityLeavesWorkingDataUntouched()
    {
        using var f = SaveRepositoryFixture.Create([0], false);
        var selection = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        string dir = f.PhysicalDir(selection.Keys.Single());
        Directory.CreateDirectory(System.IO.Path.Combine(dir, "1"));
        string working = System.IO.Path.Combine(dir, "1", "uncommitted"); File.WriteAllBytes(working, [8, 9]);
        f.Durable.Fail = true;
        Assert.Throws<IOException>(() => f.Repository.OpenCommitted(selection.Keys.Single()));
        Assert.That(File.ReadAllBytes(working), Is.EqualTo(new byte[] { 8, 9 }));
    }
    [Test]
    public void OnlyWorkingDirectoryCannotBeUploadedAsCommittedSave()
    {
        using var f = SaveRepositoryFixture.Create([0], false);
        var selection = f.Repository.Describe(f.TitleId, "fixture", f.LocalUserId);
        string dir = f.PhysicalDir(selection.Keys.Single());
        Directory.Delete(System.IO.Path.Combine(dir, "0"), true);
        Directory.CreateDirectory(System.IO.Path.Combine(dir, "1"));
        Assert.Throws<SaveSyncException>(() => f.Repository.OpenCommitted(selection.Keys.Single()));
        Assert.That(Directory.Exists(System.IO.Path.Combine(dir, "0")), Is.False);
    }
}

internal sealed class TrackingDurable : IDurableStore
{
    public List<string> Synced { get; } = [];
    public bool Fail { get; set; }
    public void WriteAtomic(string path, ReadOnlySpan<byte> bytes) { if (Fail) throw new IOException(); File.WriteAllBytes(path, bytes.ToArray()); }
    public void SyncTree(string root) { if (Fail) throw new IOException(); Synced.Add(root); }
}

internal sealed class SaveRepositoryFixture : IDisposable
{
    public string Root { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "save-repository-test-" + Guid.NewGuid());
    public string OwnedRoot => System.IO.Path.Combine(Root, "SaveSync/v1");
    public ulong TitleId => 0x100;
    public string LocalUserId => "00000000000000000000000000000001";
    public SaveCreateControl Control { get; } = new(0x999, 0x4000, 0x4000, 0x4000, 0x4000, 0);
    public LibHacSaveRepository Repository { get; }
    public TrackingDurable Durable { get; } = new();
    public long AvailableBytes { get; set; } = long.MaxValue;
    private readonly LocalFileSystem _rootFs;
    private readonly FileSystemClient _fs;
    private SaveRepositoryFixture(ushort[] indexes, bool device)
    {
        Directory.CreateDirectory(OwnedRoot);
        string nand = System.IO.Path.Combine(Root, "nand"); Directory.CreateDirectory(nand);
        _rootFs = new LocalFileSystem();
        _rootFs.Initialize(nand, LocalFileSystem.PathMode.DefaultCaseSensitivity, true).ThrowIfFailure();
        var horizon = new Horizon(new HorizonConfiguration());
        var serverClient = horizon.CreatePrivilegedHorizonClient();
        var server = new FileSystemServer(serverClient);
        var keys = new KeySet();
        RandomDataGenerator random = Random.Shared.NextBytes;
        var defaults = DefaultFsServerObjects.GetDefaultEmulatedCreators(_rootFs, keys, server, random);
        defaults.FsCreators.EncryptedFileSystemCreator = new Ryujinx.HLE.FileSystem.EncryptedFileSystemCreator();
        var config = new FileSystemServerConfig { ExternalKeySet = keys.ExternalKeySet, FsCreators = defaults.FsCreators,
            StorageDeviceManagerFactory = defaults.StorageDeviceManagerFactory, RandomGenerator = random };
        FileSystemServerInitializer.InitializeWithConfig(serverClient, server, config);
        server.SetDebugFlagEnabled(true);
        _fs = horizon.CreatePrivilegedHorizonClient().Fs;
        foreach (ushort index in indexes) CreateSave(new(TitleId, LocalUserId, SaveKind.Account, index));
        if (device) CreateSave(new(TitleId, "shared", SaveKind.Device, 0));
        Repository = new LibHacSaveRepository(_fs, System.IO.Path.Combine(nand, "bis/user/save"), OwnedRoot, Durable, (_, _) => Control, () => AvailableBytes);
    }
    public static SaveRepositoryFixture Create(ushort[] accountIndexes, bool device) => new(accountIndexes, device);
    public void CreateSave(SaveKey key, SaveDataRank rank = SaveDataRank.Primary)
    {
        var user = key.Kind == SaveKind.Device ? default : new LibHac.Fs.UserId(Convert.ToUInt64(key.UserId[..16], 16), Convert.ToUInt64(key.UserId[16..], 16));
        SaveDataAttribute.Make(out var attribute, new ProgramId(key.ProgramId), key.Kind == SaveKind.Account ? SaveDataType.Account : SaveDataType.Device, user, 0, key.Index, rank).ThrowIfFailure();
        SaveDataCreationInfo.Make(out var info, 0x4000, 0x4000, Control.OwnerId, SaveDataFlags.None, SaveDataSpaceId.User).ThrowIfFailure();
        var meta = new SaveDataMetaInfo { Type = SaveDataMetaType.Thumbnail, Size = 0x40060 };
        using var proxy = _fs.Impl.GetFileSystemProxyServiceObject();
        proxy.Get.CreateSaveDataFileSystem(in attribute, in info, in meta).ThrowIfFailure();
    }
    public SaveDataInfo[] AllInfos()
    {
        using var iterator = new UniqueRef<SaveDataIterator>();
        _fs.OpenSaveDataIterator(ref iterator.Ref, SaveDataSpaceId.User).ThrowIfFailure();
        var all = new List<SaveDataInfo>(); var page = new SaveDataInfo[16];
        while (true) { iterator.Get.ReadSaveDataInfo(out long count, page).ThrowIfFailure(); if (count == 0) break; all.AddRange(page.Take((int)count)); }
        return all.ToArray();
    }
    public string PhysicalDir(SaveKey key)
    {
        var info = AllInfos().Single(i => i.ProgramId.Value == key.ProgramId && i.Index == key.Index && i.Type == (key.Kind == SaveKind.Account ? SaveDataType.Account : SaveDataType.Device));
        return System.IO.Path.Combine(Root, "nand/bis/user/save", info.SaveDataId.ToString("x16"));
    }
    public SaveSnapshot SnapshotForOtherUser(ushort[]? accountIndexes = null, bool device = true)
    {
        Guid generation = Guid.NewGuid();
        var keys = (accountIndexes ?? new ushort[] { 0, 2 }).Select(index => new SaveKey(TitleId, "00000000000000000000000000000002", SaveKind.Account, index)).ToList();
        if (device) keys.Add(new(TitleId, "shared", SaveKind.Device, 0));
        var refs = keys.Select(k => new SaveRecordReference(k, SnapshotPaths.RecordManifest(k, generation), new string('a', 64), 0)).ToArray();
        return new(1, generation, null, TitleId, "00000000000000000000000000000002", "2026-01-01T00:00:00Z", Guid.NewGuid(), 0, refs);
    }
    public string Payload(string name, Dictionary<string, byte[]> files)
    {
        string path = System.IO.Path.Combine(Root, name); Directory.CreateDirectory(path);
        foreach (var file in files) { string target = System.IO.Path.Combine(path, file.Key); Directory.CreateDirectory(System.IO.Path.GetDirectoryName(target)!); File.WriteAllBytes(target, file.Value); }
        return path;
    }
    public void Dispose() { _rootFs.Dispose(); Directory.Delete(Root, true); }
}
