using LibHac.Tools.FsSystem.NcaUtils;
using NUnit.Framework;
using Ryujinx.Library.Compression;

namespace Ryujinx.Nsz.Tests;

public class NszReferencedContentTests
{
    private static readonly string ProgramId = new('1', 32);
    private static readonly string ControlId = new('2', 32);
    private static readonly string DeltaId = new('3', 32);
    private static byte[] Hash(byte value) => Enumerable.Repeat(value, 32).ToArray();

    private static NszContentManifest Manifest(NszPackageKind kind = NszPackageKind.Patch) => new(
        new(kind, 0x1000, kind == NszPackageKind.Patch ? 0x1800UL : 0x1000UL),
        [new(ProgramId, 100, 1, Hash(1)), new(ControlId, 200, 3, Hash(2)), new(DeltaId, 300, 6, Hash(3))]);

    private static Dictionary<string, (long Size, byte[] Hash, NcaContentType Type, ulong TitleId)> Contents(bool delta = false)
    {
        var values = new Dictionary<string, (long, byte[], NcaContentType, ulong)>
        {
            [ProgramId] = (100, Hash(1), NcaContentType.Program, 0x1000),
            [ControlId] = (200, Hash(2), NcaContentType.Control, 0x1000)
        };
        if (delta) values[DeltaId] = (300, Hash(3), NcaContentType.Data, 0x1800);
        return values;
    }

    [Test]
    public void CompletePatchMayOmitDeltaFragment()
    {
        Assert.DoesNotThrow(() => NszPackageValidator.ValidateReferencedContents(Manifest(), Contents(), default));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void MissingRequiredProgramOrControlStillFails(bool removeControl)
    {
        var contents = Contents(); contents.Remove(removeControl ? ControlId : ProgramId);
        Assert.Throws<InvalidDataException>(() => NszPackageValidator.ValidateReferencedContents(Manifest(), contents, default));
    }

    [Test]
    public void PresentDeltaIsValidated()
    {
        Assert.DoesNotThrow(() => NszPackageValidator.ValidateReferencedContents(Manifest(), Contents(true), default));
    }

    [TestCase("hash")]
    [TestCase("size")]
    [TestCase("type")]
    [TestCase("title")]
    public void CorruptPresentDeltaStillFails(string field)
    {
        var contents = Contents(true);
        contents[DeltaId] = (field == "size" ? 301 : 300, field == "hash" ? Hash(9) : Hash(3),
            field == "type" ? NcaContentType.Control : NcaContentType.Data, field == "title" ? 0x9999UL : 0x1800UL);
        Assert.Throws<InvalidDataException>(() => NszPackageValidator.ValidateReferencedContents(Manifest(), contents, default));
    }

    [TestCase(NszPackageKind.Application)]
    [TestCase(NszPackageKind.AddOnContent)]
    public void OtherRolesCannotOmitReferencedContent(NszPackageKind kind)
    {
        Assert.Throws<InvalidDataException>(() => NszPackageValidator.ValidateReferencedContents(Manifest(kind), Contents(), default));
    }

    [Test]
    public void ExtraUnreferencedContentStillFails()
    {
        Assert.Throws<NszImportException>(() => NszContentManifest.ValidateIncludedNcas(Manifest(), new('4', 32),
            [ProgramId, ControlId, DeltaId, new('5', 32)]));
    }

    [Test]
    public void CancellationStillPrecedesOptionalContent()
    {
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        var manifest = Manifest(); manifest = manifest with { Contents = [manifest.Contents.Last()] };
        Assert.Throws<OperationCanceledException>(() => NszPackageValidator.ValidateReferencedContents(manifest, Contents(), cancellation.Token));
    }

    [Test]
    public void MatchingHashPrefixDoesNotAcceptCorruptTail()
    {
        var contents = Contents(true); var hash = Hash(3); hash[^1] ^= 1;
        contents[DeltaId] = (300, hash, NcaContentType.Data, 0x1800);
        Assert.That(hash.AsSpan(0, 16).SequenceEqual(Manifest().Contents.Last().Hash.AsSpan(0, 16)), Is.True);
        Assert.Throws<InvalidDataException>(() => NszPackageValidator.ValidateReferencedContents(Manifest(), contents, default));
    }
}
