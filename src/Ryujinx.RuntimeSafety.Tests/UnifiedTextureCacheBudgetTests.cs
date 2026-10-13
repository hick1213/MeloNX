using NUnit.Framework;
using Ryujinx.Graphics.Gpu.Image;

namespace Ryujinx.RuntimeSafety.Tests
{
    public class UnifiedTextureCacheBudgetTests
    {
        private const ulong MiB = 1024 * 1024;
        private const ulong GiB = 1024 * MiB;

        [TestCase(11524 * MiB, 4 * GiB, 11524 * MiB / 16)]
        [TestCase(8 * GiB, 4 * GiB, 512 * MiB)]
        [TestCase(12 * GiB, 4 * GiB, 768 * MiB)]
        [TestCase(16 * GiB, 4 * GiB, 768 * MiB)]
        [TestCase(ulong.MaxValue, 4 * GiB, 768 * MiB)]
        [TestCase(2 * GiB, 4 * GiB, 256 * MiB)]
        [TestCase(0UL, 4 * GiB, 256 * MiB)]
        [TestCase(0UL, 8 * GiB, 512 * MiB)]
        public void ReportedHostHeapDeterminesBoundedCache(ulong heap, ulong fallback, ulong expected)
        {
            Assert.That(UnifiedTextureCacheBudget.Calculate(heap, fallback), Is.EqualTo(expected));
        }

        [Test]
        public void GuestRamDoesNotChangeKnownHostHeapBudget()
        {
            Assert.That(UnifiedTextureCacheBudget.Calculate(8 * GiB, 4 * GiB),
                Is.EqualTo(UnifiedTextureCacheBudget.Calculate(8 * GiB, 8 * GiB)));
        }
    }
}
