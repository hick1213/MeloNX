using System.Buffers.Binary;
using NUnit.Framework;

namespace Ryujinx.Nsz.Tests;

[TestFixture]
public class NszPackageRoutingTests
{
    [TestCase(0x80, NszPackageKind.Application, 0x100UL)]
    [TestCase(0x81, NszPackageKind.Patch, 0x180UL)]
    [TestCase(0x82, NszPackageKind.AddOnContent, 0x101UL)]
    public void UsesCnmtApplicationRelationshipWithoutGameInfo(byte type, NszPackageKind kind, ulong contentId)
    {
        using var input = new MemoryStream(Cnmt(type, contentId));
        var manifest = NszContentManifest.Read(input, CancellationToken.None);
        Assert.That(manifest.Package, Is.EqualTo(new NszPackage(kind, 0x100, contentId)));
        Assert.That(manifest.Contents.Single().ContentId, Is.EqualTo(new string('1', 32)));
        Assert.That(manifest.Contents.Single().Size, Is.EqualTo(123));
    }
    [Test]
    public void RejectsMixedAndEmptyMetadataRole()
    {
        var application = NszContentManifest.Read(new MemoryStream(Cnmt(0x80, 0x100)), default);
        var patch = NszContentManifest.Read(new MemoryStream(Cnmt(0x81, 0x180)), default);
        Assert.Throws<NszImportException>(() => NszContentManifest.SelectPackage([application, patch]));
        Assert.Throws<NszImportException>(() => NszContentManifest.SelectPackage([]));
    }
    [Test]
    public void RejectsUnboundedCountsTruncationAndLegacyHeadersBeforeAllocation()
    {
        byte[] bytes = Cnmt(0x81, 0x180); BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(0x10), 65535);
        Assert.Throws<InvalidDataException>(() => NszContentManifest.Read(new MemoryStream(bytes), default));
        Assert.Throws<InvalidDataException>(() => NszContentManifest.Read(new MemoryStream(Cnmt(0x81, 0x180)[..60]), default));
        bytes = Cnmt(0x80, 0x100); bytes[0x1c] = 1;
        Assert.Throws<NszImportException>(() => NszContentManifest.Read(new MemoryStream(bytes), default));
    }
    [Test]
    public void RejectsMaliciousPatchExtendedCountsBeforeDownstreamParser()
    {
        // Subsequent existing patch loaders may invoke LibHac's full parser after import.
        byte[] bytes = Cnmt(0x81, 0x180); Array.Fill(bytes, (byte)0xff, 0x70, 24);
        Assert.Throws<InvalidDataException>(() => NszContentManifest.Read(new MemoryStream(bytes), default));
    }
    [Test]
    public void BoundsFragmentCountsAndDeclaredExtendedLength()
    {
        byte[] basic = Cnmt(0x81, 0x180); const int start = 0x70;
        const int length = 0x1c + 0x28 + 0x34 + 0x38 + 4;
        byte[] bytes = new byte[start + length + 32]; basic.AsSpan(0, start).CopyTo(bytes);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(0x2c), length);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(start + 8), 1);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(start + 12), 1);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(start + 20), 1);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(start + 0x1c + 0x18), 1);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(start + 0x1c + 0x20), 1);
        BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(start + 0x1c + 0x28 + 0x2c), 1);
        Assert.That(NszContentManifest.Read(new MemoryStream(bytes), default).Package.Kind, Is.EqualTo(NszPackageKind.Patch));
        var badLength = bytes.ToArray(); badLength[0x2c]++;
        Assert.Throws<InvalidDataException>(() => NszContentManifest.Read(new MemoryStream(badLength), default));
        var negativeFragments = bytes.ToArray();
        BinaryPrimitives.WriteInt16LittleEndian(negativeFragments.AsSpan(start + 0x1c + 0x28 + 0x2c), -1);
        Assert.Throws<InvalidDataException>(() => NszContentManifest.Read(new MemoryStream(negativeFragments), default));
        Assert.Throws<InvalidDataException>(() => NszContentManifest.Read(new MemoryStream(bytes[..^1]), default));
    }
    [Test]
    public void MetadataCancellationAndUnsupportedKindsHaveStructuredFailures()
    {
        using var cts = new CancellationTokenSource(); cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => NszContentManifest.Read(new MemoryStream(Cnmt(0x80, 0x100)), cts.Token));
        var error = Assert.Throws<NszImportException>(() => NszContentManifest.Read(new MemoryStream(Cnmt(0x83, 0x100)), default));
        Assert.That(error!.Code, Is.EqualTo(NszImportError.UnsupportedPackage));
    }
    [Test]
    public void RejectsDuplicateContentIds()
    {
        byte[] one = Cnmt(0x80, 0x100); byte[] two = new byte[0x30 + 0x70 + 32];
        Assert.That(NszContentManifest.Read(new MemoryStream(one), default).Contents.Count, Is.EqualTo(1));
        one.AsSpan(0, 0x68).CopyTo(two); one.AsSpan(0x30, 0x38).CopyTo(two.AsSpan(0x68));
        BinaryPrimitives.WriteUInt16LittleEndian(two.AsSpan(0x10), 2);
        Assert.Throws<InvalidDataException>(() => NszContentManifest.Read(new MemoryStream(two), default));
    }
    [TestCase(0, 1, true)] [TestCase(1, 0, true)] [TestCase(2, 4, true)]
    [TestCase(2, 5, true)] [TestCase(3, 2, true)] [TestCase(4, 3, true)]
    [TestCase(5, 3, true)] [TestCase(6, 4, true)] [TestCase(2, 0, false)]
    [TestCase(1, 2, false)] [TestCase(7, 4, false)]
    public void ContentRoleMatchesActualNcaHeader(int cnmt, int nca, bool expected)
    {
        Assert.That(NszContentManifest.ContentTypeMatches((byte)cnmt, (byte)nca), Is.EqualTo(expected));
    }
    [Test]
    public void RejectsValidManifestWithExtraUnrelatedControlNca()
    {
        var manifest = NszContentManifest.Read(new MemoryStream(Cnmt(0x80, 0x100)), default);
        string payload = manifest.Contents[0].ContentId, meta = new('2', 32), extraControl = new('3', 32);
        Assert.DoesNotThrow(() => NszContentManifest.ValidateIncludedNcas(manifest, meta, [payload, meta]));
        var error = Assert.Throws<NszImportException>(() => NszContentManifest.ValidateIncludedNcas(manifest, meta, [payload, meta, extraControl]));
        Assert.That(error!.Code, Is.EqualTo(NszImportError.UnsupportedPackage));
        Assert.That(NszContentManifest.TitleMatches(manifest.Package, 0, 0x200), Is.False);
        Assert.That(NszContentManifest.TitleMatches(manifest.Package, 1, 0x101), Is.True);
    }
    internal static byte[] Cnmt(byte type, ulong title)
    {
        int table = type == 0x81 ? 0x18 : 0x10;
        int extension = type == 0x81 ? 0x1c : 0;
        int content = 0x20 + table;
        byte[] result = new byte[content + 0x38 + extension + 32];
        BinaryPrimitives.WriteUInt64LittleEndian(result, title); result[0xc] = type;
        BinaryPrimitives.WriteUInt16LittleEndian(result.AsSpan(0xe), (ushort)table);
        BinaryPrimitives.WriteUInt16LittleEndian(result.AsSpan(0x10), 1);
        BinaryPrimitives.WriteUInt64LittleEndian(result.AsSpan(0x20), 0x100);
        if (type == 0x81) BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(0x2c), (uint)extension);
        Array.Fill(result, (byte)0x11, content + 0x20, 16);
        BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(content + 0x30), 123); result[content + 0x36] = type == 0x82 ? (byte)2 : (byte)1;
        return result;
    }
}
