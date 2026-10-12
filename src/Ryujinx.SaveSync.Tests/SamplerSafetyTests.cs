using NUnit.Framework;
using Ryujinx.Graphics.GAL;
namespace Ryujinx.SaveSync.Tests;
public class SamplerSafetyTests {
    [TestCase(0f)] [TestCase(0.5f)] [TestCase(-1f)] [TestCase(float.NaN)] [TestCase(float.PositiveInfinity)]
    public void InvalidAnisotropyCannotReachTheRenderer(float requested) {
        var info = new SamplerCreateInfo(default, default, false, default, default, default, default, default, default, 0, 0, 0, requested);
        Assert.That(info.MaxAnisotropy, Is.EqualTo(1f));
    }
    [TestCase(1f)] [TestCase(2f)] [TestCase(16f)]
    public void ValidAnisotropyIsPreserved(float requested) {
        var info = new SamplerCreateInfo(default, default, false, default, default, default, default, default, default, 0, 0, 0, requested);
        Assert.That(info.MaxAnisotropy, Is.EqualTo(requested));
    }
}
