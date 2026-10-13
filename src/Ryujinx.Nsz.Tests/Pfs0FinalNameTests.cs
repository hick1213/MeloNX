using NUnit.Framework;
using System.Text;

namespace Ryujinx.Nsz.Tests;

public class Pfs0FinalNameTests
{
    private static MemoryStream Archive(string finalName, bool terminate = false, bool interiorOffset = false)
    {
        string first = new string('1', 32) + ".ncz";
        byte[] strings = Encoding.UTF8.GetBytes(first + "\0" + finalName + (terminate ? "\0" : ""));
        var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream, Encoding.UTF8, true);
        writer.Write("PFS0"u8); writer.Write(2); writer.Write(strings.Length); writer.Write(0);
        writer.Write(0L); writer.Write(1L); writer.Write(0); writer.Write(0);
        writer.Write(1L); writer.Write(1L); writer.Write(first.Length + 1 + (interiorOffset ? 1 : 0)); writer.Write(0);
        writer.Write(strings); writer.Write(new byte[2]); stream.Position = 0; return stream;
    }

    [Test]
    public void FinalNameMayEndAtStringTableBoundary()
    {
        string name = new string('2', 32) + ".cert";
        using var archive = Archive(name);
        Assert.That(Pfs0Directory.Read(archive, new NszLimits()).Last().Name, Is.EqualTo(name));
    }

    [Test]
    public void CanonicalTerminatedNamesStillWork()
    {
        using var archive = Archive("certificate.cert", true);
        Assert.That(Pfs0Directory.Read(archive, new NszLimits()).Last().Name, Is.EqualTo("certificate.cert"));
    }

    [Test]
    public void UnterminatedNameCannotStartInsideAnotherName()
    {
        using var archive = Archive("certificate.cert", interiorOffset: true);
        Assert.Throws<InvalidDataException>(() => Pfs0Directory.Read(archive, new NszLimits()));
    }

    [TestCase("../outside.cert")]
    [TestCase("sub\\outside.cert")]
    [TestCase("..")]
    public void UnterminatedNamesRemainFlat(string name)
    {
        using var archive = Archive(name);
        Assert.Throws<InvalidDataException>(() => Pfs0Directory.Read(archive, new NszLimits()));
    }

    [Test]
    public void UnterminatedNamesStillHaveByteLimit()
    {
        using var archive = Archive(new string('a', 256));
        Assert.Throws<InvalidDataException>(() => Pfs0Directory.Read(archive, new NszLimits()));
    }
}
