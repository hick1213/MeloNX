using NUnit.Framework;

namespace Ryujinx.Nsz.Tests;

public class NczSectionLimitTests
{
    private static MemoryStream Entry(int sections, int storedSections)
    {
        var stream = new MemoryStream(); stream.Write(new byte[0x4000]);
        using var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, true);
        writer.Write("NCZSECTN"u8); writer.Write((ulong)sections);
        for (int index = 0; index < storedSections; index++)
        {
            writer.Write(0x4000UL + (ulong)index); writer.Write(1UL);
            writer.Write(1UL); writer.Write(0UL); writer.Write(new byte[32]);
        }
        writer.Write(new byte[8]); stream.Position = 0; return stream;
    }

    [TestCase(71)]
    [TestCase(8192)]
    public void BoundedFragmentedSectionTablesAreAccepted(int count)
    {
        using var entry = Entry(count, count);
        using var layout = NczLayout.Parse(entry, new NszLimits(), default);
        Assert.That(layout.Sections.Count, Is.EqualTo(count));
        Assert.That(layout.OutputSize, Is.EqualTo(0x4000 + count));
    }

    [Test]
    public void AboveLimitStillFails()
    {
        using var entry = Entry(8193, 8193);
        Assert.Throws<InvalidDataException>(() => NczLayout.Parse(entry, new NszLimits(), default));
    }

    [Test]
    public void TruncatedTableStillFails()
    {
        using var entry = Entry(71, 70);
        Assert.Throws<InvalidDataException>(() => NczLayout.Parse(entry, new NszLimits(), default));
    }

    [Test]
    public void ExplicitLowerLimitIsHonored()
    {
        using var entry = Entry(71, 71);
        Assert.Throws<InvalidDataException>(() => NczLayout.Parse(entry, new NszLimits(MaxSections: 64), default));
    }

    private static MemoryStream Archive(int count, int sections)
    {
        var payloads = Enumerable.Range(0, count).Select(_ => Entry(sections, sections).ToArray()).ToArray();
        var names = Enumerable.Range(0, count).Select(i => new string((char)('1' + i), 32) + ".ncz").ToArray();
        byte[] strings = System.Text.Encoding.UTF8.GetBytes(string.Join("\0", names) + "\0");
        var stream = new MemoryStream(); using var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, true);
        writer.Write("PFS0"u8); writer.Write(count); writer.Write(strings.Length); writer.Write(0);
        long offset = 0; int nameOffset = 0;
        for (int i = 0; i < count; i++)
        {
            writer.Write(offset); writer.Write((long)payloads[i].Length); writer.Write(nameOffset); writer.Write(0);
            offset += payloads[i].Length; nameOffset += names[i].Length + 1;
        }
        writer.Write(strings); foreach (var payload in payloads) writer.Write(payload);
        stream.Position = 0; return stream;
    }

    [Test]
    public void IndividuallyValidTablesCannotExceedWholeJobBudget()
    {
        using var archive = Archive(2, 3);
        var error = Assert.Throws<NszImportException>(() => NszConverter.EstimateOutputSize(archive,
            new NszLimits(MaxSections: 8, MaxTotalSections: 5)));
        Assert.That(error!.Code, Is.EqualTo(NszImportError.UnsupportedPackage));
    }

    [Test]
    public void ExactWholeJobBudgetStillWorks()
    {
        using var archive = Archive(2, 3);
        Assert.That(NszConverter.EstimateOutputSize(archive, new NszLimits(MaxSections: 8, MaxTotalSections: 6)), Is.GreaterThan(0));
    }
}
