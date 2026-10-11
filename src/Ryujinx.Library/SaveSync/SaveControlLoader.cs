#nullable enable
using System;
using System.IO;
using System.Runtime.InteropServices;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Ns;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using Ryujinx.SaveSync;

namespace Ryujinx.Library.SaveSync;

public static class SaveControlLoader
{
    public static SaveCreateControl? FromNacp(in ApplicationControlProperty control)
    {
        if (control.UserAccountSaveDataSize < 0 || control.UserAccountSaveDataJournalSize < 0 ||
            control.DeviceSaveDataSize < 0 || control.DeviceSaveDataJournalSize < 0) throw new SaveSyncException("malformedSnapshot");
        if (control.SaveDataOwnerId == 0) return null;
        return new(control.SaveDataOwnerId, control.UserAccountSaveDataSize, control.UserAccountSaveDataJournalSize,
            control.DeviceSaveDataSize, control.DeviceSaveDataJournalSize, 0);
    }
    public static SaveCreateControl? Load(string path, ulong programId, KeySet ownedKeys)
    {
        string extension = System.IO.Path.GetExtension(path).ToLowerInvariant();
        if (extension is not (".nsp" or ".pfs0" or ".xci" or ".nca")) return null;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var storage = stream.AsStorage();
        if (extension == ".nca")
        {
            var nca = new Nca(ownedKeys, storage);
            return ReadControl(nca, programId);
        }
        IFileSystem container;
        if (extension == ".xci") container = new Xci(ownedKeys, storage).OpenPartition(XciPartitionType.Secure);
        else { var pfs = new PartitionFileSystem(); pfs.Initialize(storage).ThrowIfFailure(); container = pfs; }
        using (container)
        {
            SaveCreateControl? found = null; int count = 0;
            foreach (var entry in container.EnumerateEntries("/", "*.nca"))
            {
                if (++count > 100000) throw new SaveSyncException("malformedSnapshot");
                using var file = new UniqueRef<IFile>();
                container.OpenFile(ref file.Ref, entry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                using var ncaStorage = file.Get.AsStorage();
                var value = ReadControl(new Nca(ownedKeys, ncaStorage), programId);
                if (value is null) continue;
                if (found is not null) throw new SaveSyncException("identityMismatch");
                found = value;
            }
            return found;
        }
    }
    private static SaveCreateControl? ReadControl(Nca nca, ulong programId)
    {
        if (nca.Header.ContentType != NcaContentType.Control || nca.Header.TitleId != programId) return null;
        using var fs = nca.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        using var file = new UniqueRef<IFile>();
        fs.OpenFile(ref file.Ref, "/control.nacp".ToU8Span(), OpenMode.Read).ThrowIfFailure();
        int size = Marshal.SizeOf<ApplicationControlProperty>(); byte[] bytes = new byte[size]; long position = 0;
        while (position < size)
        {
            file.Get.Read(out long read, position, bytes.AsSpan((int)position), ReadOption.None).ThrowIfFailure();
            if (read <= 0 || read > size - position) throw new SaveSyncException("malformedSnapshot");
            position += read;
        }
        var control = MemoryMarshal.Read<ApplicationControlProperty>(bytes);
        return FromNacp(in control);
    }
}
