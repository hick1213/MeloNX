using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Spl;
using LibHac.Tools.Es;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using Ryujinx.Nsz;

namespace Ryujinx.Library.Compression;

internal sealed class NszPackageValidator(KeySet ownedKeys) : INszPackageValidator, IDisposable
{
    public static KeySet Snapshot(KeySet source)
    {
        var copy = new KeySet(); copy.KeyStruct = source.KeyStruct; copy.SetMode(source.CurrentMode);
        foreach (var (rights, key) in source.ExternalKeySet.ToList()) copy.ExternalKeySet.Add(rights, key).ThrowIfFailure();
        return copy;
    }
    public NszPackage Validate(string path, CancellationToken cancellation)
    {
        try
        {
            cancellation.ThrowIfCancellationRequested();
            if (ownedKeys.HeaderKey.IsZeros()) throw new NszImportException(NszImportError.MissingKey, "NCA header key is unavailable.");
            using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
            var entries = Pfs0Directory.Read(input, new());
            foreach (var entry in entries.Where(e => e.Name.EndsWith(".tik", StringComparison.OrdinalIgnoreCase)))
            {
                cancellation.ThrowIfCancellationRequested();
                if (entry.Size is < 0x2c0 or > 0x600) throw new InvalidDataException("Invalid ticket size.");
                using var ticketStream = new BoundedReadStream(input, entry.Offset, entry.Size);
                var ticket = new Ticket(ticketStream); byte[] key = ticket.GetTitleKey(ownedKeys);
                if (key == null || key.Length != 16) throw new NszImportException(NszImportError.MissingKey, "Ticket key cannot be read with the installed keys.");
                try { ownedKeys.ExternalKeySet.Add(new RightsId(ticket.RightsId), new AccessKey(key)).ThrowIfFailure(); }
                finally { CryptographicOperations.ZeroMemory(key); }
            }
            var manifests = new List<NszContentManifest>();
            var contents = new Dictionary<string, (long Size, byte[] Hash, NcaContentType Type)>(StringComparer.OrdinalIgnoreCase);
            byte[] buffer = new byte[1 << 20];
            foreach (var entry in entries.Where(e => e.Name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase)))
            {
                cancellation.ThrowIfCancellationRequested();
                if (entry.Size < 0xc00) throw new InvalidDataException("NCA header is truncated.");
                using var slice = new BoundedReadStream(input, entry.Offset, entry.Size);
                using var storage = slice.AsStorage(keepOpen: true);
                var nca = new Nca(ownedKeys, storage);
                if (nca.Header.NcaSize != entry.Size) throw new InvalidDataException("NCA declared size is invalid.");
                if (nca.Header.ContentType == NcaContentType.Meta)
                {
                    using var fs = nca.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
                    foreach (var fileEntry in fs.EnumerateEntries("/", "*.cnmt"))
                    {
                        cancellation.ThrowIfCancellationRequested();
                        if (manifests.Count >= 64) throw new InvalidDataException("Too many content manifests.");
                        using var file = new UniqueRef<IFile>();
                        fs.OpenFile(ref file.Ref, fileEntry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                        using var cnmt = file.Get.AsStream();
                        var manifest = NszContentManifest.Read(cnmt, cancellation);
                        if (manifest.Package.ContentId != nca.Header.TitleId) throw new InvalidDataException("Metadata title identity is inconsistent.");
                        manifests.Add(manifest);
                    }
                }
                slice.Position = 0; using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                int read;
                while ((read = slice.Read(buffer)) != 0) { cancellation.ThrowIfCancellationRequested(); digest.AppendData(buffer, 0, read); }
                string id = entry.Name.Split('.')[0]; byte[] hash = digest.GetHashAndReset();
                if (id.Length != 32 || !Convert.ToHexString(hash).StartsWith(id, StringComparison.OrdinalIgnoreCase) || !contents.TryAdd(id, (entry.Size, hash, nca.Header.ContentType)))
                    throw new InvalidDataException("Invalid NCA content identity.");
            }
            NszPackage package = NszContentManifest.SelectPackage(manifests);
            foreach (var item in manifests[0].Contents)
            {
                cancellation.ThrowIfCancellationRequested();
                if (!contents.TryGetValue(item.ContentId, out var actual) || actual.Size != item.Size || !actual.Hash.AsSpan().SequenceEqual(item.Hash) ||
                    !NszContentManifest.ContentTypeMatches(item.Type, (byte)actual.Type))
                    throw new InvalidDataException("CNMT referenced content is missing or inconsistent.");
            }
            byte required = package.Kind == NszPackageKind.AddOnContent ? (byte)2 : (byte)1;
            if (!manifests[0].Contents.Any(e => e.Type == required))
                throw new NszImportException(NszImportError.UnsupportedPackage, "Package does not contain complete content for its role.");
            return package;
        }
        catch (MissingKeyException) { throw new NszImportException(NszImportError.MissingKey, "Required NCA key is unavailable."); }
        catch (EndOfStreamException) { throw new InvalidDataException("Package metadata is truncated."); }
    }
    public void Dispose() { ownedKeys.ExternalKeySet.Clear(); ownedKeys.KeyStruct = default; }
}
