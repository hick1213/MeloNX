using NUnit.Framework;

namespace Ryujinx.Nsz.Tests;

[TestFixture]
public class Pfs0ConversionTests
{
    [TestCase(0x2000, false, false)] [TestCase(0x4000, false, true)]
    [TestCase(0x6000, false, false)] [TestCase(0x2000, true, false)]
    [TestCase(0x4000, true, true)] [TestCase(0x6000, true, false)]
    public void RestoresExactContainer(int firstOffset, bool blocked, bool exactMultiple)
    {
        var f = NszFixtures.Build(firstOffset, blocked, true, exactMultiple);
        using var result = new MemoryStream();
        var report = NszConverter.Convert(new MemoryStream(f.Nsz), result, new NszLimits(), CancellationToken.None, _ => {});
        Assert.That(result.ToArray(), Is.EqualTo(f.ExpectedNsp));
        Assert.That(report.BytesWritten, Is.EqualTo(f.ExpectedNsp.Length));
        Assert.That(NszConverter.EstimateOutputSize(new MemoryStream(f.Nsz), new()), Is.EqualTo(f.ExpectedNsp.Length));
    }
    [TestCase(1UL)] [TestCase(4UL)]
    public void HandlesPlaintextAndCtrSectionTypes(ulong cryptoType)
    {
        var f = NszFixtures.Build(cryptoType: cryptoType);
        using var result = new MemoryStream();
        NszConverter.Convert(new MemoryStream(f.Nsz), result, new(), CancellationToken.None, _ => {});
        Assert.That(result.ToArray(), Is.EqualTo(f.ExpectedNsp));
    }
    [Test]
    public void RejectsHashMismatchWithoutSuccessfulReport()
    {
        var f = NszFixtures.Build(); f.Nsz[^1] ^= 1;
        // Mutate encrypted original header inside the NCZ, keeping the expected content ID.
        f.Ncz[100] ^= 1;
        byte[] bad = NszFixtures.Pfs0((f.NcaName.Replace(".nca", ".ncz"), f.Ncz));
        Assert.Throws<InvalidDataException>(() => NszConverter.Convert(new MemoryStream(bad), new MemoryStream(), new(), CancellationToken.None, _ => {}));
    }
    [Test]
    public void RejectsDuplicateNormalizedNcaNames()
    {
        var f = NszFixtures.Build();
        byte[] bad = NszFixtures.Pfs0((f.NcaName.Replace(".nca", ".ncz"), f.Ncz), (f.NcaName, f.OriginalNca));
        Assert.Throws<InvalidDataException>(() => NszConverter.EstimateOutputSize(new MemoryStream(bad), new()));
    }
    [TestCase(false)] [TestCase(true)]
    public void MultipleSectionsPreservePlaintextAndEncryptedRanges(bool blocked)
    {
        var f = NszFixtures.Build(0x6000, blocked, true, false, multipleSections: true);
        using var output = new MemoryStream();
        NszConverter.Convert(new MemoryStream(f.Nsz), output, new(), CancellationToken.None, _ => {});
        Assert.That(output.ToArray(), Is.EqualTo(f.ExpectedNsp));
    }
    [Test]
    public void OrdinaryNcaCopyAlsoVerifiesItsContentId()
    {
        var f = NszFixtures.Build();
        int count = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(f.Nsz.AsSpan(4));
        int names = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(f.Nsz.AsSpan(8));
        long rawOffset = System.Buffers.Binary.BinaryPrimitives.ReadInt64LittleEndian(f.Nsz.AsSpan(16 + 24));
        f.Nsz[checked(16 + count * 24 + names + (int)rawOffset)] ^= 1;
        Assert.Throws<InvalidDataException>(() => NszConverter.Convert(new MemoryStream(f.Nsz), new MemoryStream(), new(), CancellationToken.None, _ => {}));
    }
}
