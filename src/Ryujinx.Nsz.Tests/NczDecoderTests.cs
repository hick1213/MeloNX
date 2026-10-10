using System.Buffers.Binary;
using NUnit.Framework;
using ZstdSharp;

namespace Ryujinx.Nsz.Tests;

[TestFixture]
public class NczDecoderTests
{
    [Test]
    public void CtrUsesAbsoluteOffsetsIncludingPartialBlocks()
    {
        byte[] expected = new byte[20003], actual = Enumerable.Range(0, 20003).Select(i => (byte)(i % 239)).ToArray();
        NszFixtures.ReferenceCrypt(actual, expected, NszFixtures.Key, NszFixtures.Nonce, 0x6003);
        using var crypto = new AesCtrTransform(NszFixtures.Key, NszFixtures.Nonce);
        crypto.Apply(actual.AsSpan(0, 31), 0x6003);
        crypto.Apply(actual.AsSpan(31), 0x6003 + 31);
        Assert.That(actual, Is.EqualTo(expected));
    }
    [Test]
    public void ShortReadsDoNotTruncateOutput()
    {
        var f = NszFixtures.Build(blocked: true);
        using var output = new MemoryStream();
        NszConverter.Convert(new ShortReads(f.Nsz), output, new(), CancellationToken.None, _ => {});
        Assert.That(output.ToArray(), Is.EqualTo(f.ExpectedNsp));
    }
    [Test]
    public void MetadataPlanningCanBeCancelled()
    {
        var f = NszFixtures.Build(blocked: true); using var token = new CancellationTokenSource();
        token.Cancel();
        Assert.Throws<OperationCanceledException>(() => NszConverter.EstimateOutputSize(new MemoryStream(f.Nsz), new(), token.Token));
    }
    [Test]
    public void ConversionCancellationIsObservedBeforeSuccessfulReport()
    {
        var f = NszFixtures.Build(); using var token = new CancellationTokenSource();
        Assert.Throws<OperationCanceledException>(() => NszConverter.Convert(new MemoryStream(f.Nsz), new MemoryStream(), new(), token.Token, _ => token.Cancel()));
    }
    [TestCase("../bad.ncz")] [TestCase("/bad.ncz")] [TestCase("C:bad.ncz")]
    public void UnsafeContainerNamesAreRejected(string name)
    {
        byte[] container = NszFixtures.Pfs0((name, NszFixtures.Build().Ncz));
        Assert.Throws<InvalidDataException>(() => NszConverter.EstimateOutputSize(new MemoryStream(container), new()));
    }
    [TestCase("version")] [TestCase("count")] [TestCase("declaredSize")]
    [TestCase("storedSize")] [TestCase("exponent")] [TestCase("sectionCount")]
    public void RejectsMaliciousBlockMetadata(string field)
    {
        var f = NszFixtures.Build(blocked: true);
        const int b = 0x4000 + 16 + 64;
        switch (field)
        {
            case "version": f.Ncz[b + 8] = 99; break;
            case "count": BinaryPrimitives.WriteUInt32LittleEndian(f.Ncz.AsSpan(b + 12), uint.MaxValue); break;
            case "declaredSize": BinaryPrimitives.WriteUInt64LittleEndian(f.Ncz.AsSpan(b + 16), 999); break;
            case "storedSize": BinaryPrimitives.WriteUInt32LittleEndian(f.Ncz.AsSpan(b + 24), (1u << 14) + 1); break;
            case "exponent": f.Ncz[b + 11] = 27; break;
            case "sectionCount": BinaryPrimitives.WriteUInt64LittleEndian(f.Ncz.AsSpan(0x4000 + 8), ulong.MaxValue); break;
        }
        AssertBad(f, f.Ncz);
    }
    [Test]
    public void TrailingEmptyFrameCannotHideUnconsumedCompressedPayload()
    {
        var f = NszFixtures.Build(); using var compressor = new Compressor();
        byte[] bad = f.Ncz.Concat(compressor.Wrap(Array.Empty<byte>()).ToArray()).ToArray();
        AssertBad(f, bad);
    }
    [Test]
    public void TruncatedSolidStreamIsRejected()
    {
        var f = NszFixtures.Build(); AssertBad(f, f.Ncz[..^2]);
    }
    [Test]
    public void TruncatedBlockHeaderReturnsFormatFailure()
    {
        var f = NszFixtures.Build(blocked: true); AssertBad(f, f.Ncz[..(0x4000 + 16 + 64 + 8)]);
    }
    [Test]
    public void OverflowAndOverlappingEntriesAreRejected()
    {
        var f = NszFixtures.Build();
        BinaryPrimitives.WriteUInt64LittleEndian(f.Nsz.AsSpan(16), ulong.MaxValue);
        Assert.Throws<InvalidDataException>(() => NszConverter.EstimateOutputSize(new MemoryStream(f.Nsz), new()));
        f = NszFixtures.Build(); BinaryPrimitives.WriteUInt64LittleEndian(f.Nsz.AsSpan(16 + 24), 0);
        Assert.Throws<InvalidDataException>(() => NszConverter.EstimateOutputSize(new MemoryStream(f.Nsz), new()));
    }
    private static void AssertBad(NszFixtures.Fixture f, byte[] ncz)
    {
        byte[] container = NszFixtures.Pfs0((f.NcaName[..^4] + ".ncz", ncz));
        Assert.Throws<InvalidDataException>(() => NszConverter.Convert(new MemoryStream(container), new MemoryStream(), new(), CancellationToken.None, _ => {}));
    }
    private sealed class ShortReads(byte[] source) : MemoryStream(source)
    {
        public override int Read(Span<byte> buffer) => base.Read(buffer[..Math.Min(7, buffer.Length)]);
        public override int Read(byte[] buffer, int offset, int count) => base.Read(buffer, offset, Math.Min(7, count));
    }
}
