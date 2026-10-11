namespace Ryujinx.SaveSync;

public sealed record SaveCreateControl(ulong OwnerId, long AccountSize, long AccountJournalSize,
    long DeviceSize, long DeviceJournalSize, uint Flags);
public sealed record SaveSelection(Guid Id, ulong TitleId, string LocalUserId,
    IReadOnlyList<SaveKey> Keys, SaveCreateControl? Control);
public sealed record SaveMapping(SaveKey Key, ulong LocalSaveDataId);
public sealed record SaveExportIdentity(string CloudUserID, Guid? Parent, Guid Generation, Guid InstallationID, string CreatedUTC);
public interface ISaveRepository
{
    SaveSelection Describe(ulong titleId, string gamePath, string currentUser);
    SaveSelection AuthorizeRestore(SaveSelection selection, SaveSnapshot snapshot);
    void AuthorizeRecovery(SaveSelection selection, IReadOnlyList<SaveKey> keys);
    bool Exists(SaveKey key);
    SaveMapping? FindMapping(SaveKey key);
    ILogicalSave OpenCommitted(SaveKey key);
    ILogicalSave OpenWritable(SaveKey key);
    SaveMapping CreateExact(SaveKey key, SaveCreateControl control);
    void DeleteExact(SaveKey key);
}
public interface IDurableStore
{
    void WriteAtomic(string path, ReadOnlySpan<byte> bytes);
    void SyncTree(string root);
}
