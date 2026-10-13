using NUnit.Framework;
using Ryujinx.Graphics.Gpu.Image;

namespace Ryujinx.RuntimeSafety.Tests
{
    public class UnifiedTextureCacheBudgetTests
    {
        private const ulong MiB = 1024 * 1024;
        private const ulong GiB = 1024 * MiB;

        [TestCase(11524 * MiB, 4 * GiB, 1024 * MiB)]
        [TestCase(8 * GiB, 4 * GiB, 512 * MiB)]
        [TestCase(10 * GiB, 4 * GiB, 1024 * MiB)]
        [TestCase(10 * GiB - 1, 4 * GiB, 640 * MiB - 1)]
        [TestCase(12 * GiB, 4 * GiB, 1024 * MiB)]
        [TestCase(16 * GiB, 4 * GiB, 1024 * MiB)]
        [TestCase(ulong.MaxValue, 4 * GiB, 1024 * MiB)]
        [TestCase(2 * GiB, 4 * GiB, 256 * MiB)]
        [TestCase(4 * GiB, 4 * GiB, 256 * MiB)]
        [TestCase(6 * GiB, 4 * GiB, 384 * MiB)]
        [TestCase(0UL, 4 * GiB, 256 * MiB)]
        [TestCase(0UL, 8 * GiB, 512 * MiB)]
        [TestCase(0UL, 16 * GiB, 768 * MiB)]
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

        [TestCase(11524 * MiB, 4 * GiB, 256, 256 * MiB)]
        [TestCase(11524 * MiB, 4 * GiB, 512, 512 * MiB)]
        [TestCase(11524 * MiB, 4 * GiB, 768, 768 * MiB)]
        [TestCase(11524 * MiB, 4 * GiB, 1024, 1024 * MiB)]
        [TestCase(11524 * MiB, 4 * GiB, 1536, 1536 * MiB)]
        [TestCase(11524 * MiB, 4 * GiB, 2048, 2048 * MiB)]
        [TestCase(4 * GiB, 4 * GiB, 2048, 1024 * MiB)]
        [TestCase(2 * GiB, 4 * GiB, 2048, 512 * MiB)]
        [TestCase(0UL, 4 * GiB, 2048, 1024 * MiB)]
        [TestCase(0UL, 0UL, 2048, 256 * MiB)]
        [TestCase(ulong.MaxValue, 4 * GiB, 2048, 2048 * MiB)]
        [TestCase(11524 * MiB, 4 * GiB, 3072, 3072 * MiB)]
        [TestCase(11524 * MiB, 4 * GiB, 4096, 4096 * MiB)]
        [TestCase(10 * GiB, 4 * GiB, 4096, 4096 * MiB)]
        [TestCase(10 * GiB - 1, 4 * GiB, 4096, 2048 * MiB)]
        [TestCase(8 * GiB, 4 * GiB, 4096, 2048 * MiB)]
        [TestCase(4 * GiB, 4 * GiB, 4096, 1024 * MiB)]
        [TestCase(0UL, 16 * GiB, 4096, 2048 * MiB)]
        [TestCase(ulong.MaxValue, 4 * GiB, 4096, 4096 * MiB)]
        public void ManualBudgetHonorsChoiceWithinDeviceLimit(ulong heap, ulong fallback, int requestedMiB, ulong expected)
        {
            Assert.That(UnifiedTextureCacheBudget.Calculate(heap, fallback, requestedMiB), Is.EqualTo(expected));
        }

        [TestCase(0)]
        [TestCase(-1)]
        [TestCase(int.MinValue)]
        [TestCase(1)]
        [TestCase(255)]
        [TestCase(4097)]
        [TestCase(int.MaxValue)]
        public void AutomaticAndInvalidChoicesKeepExistingPolicy(int requestedMiB)
        {
            Assert.That(UnifiedTextureCacheBudget.Calculate(11524 * MiB, 4 * GiB, requestedMiB), Is.EqualTo(1024 * MiB));
            Assert.That(UnifiedTextureCacheBudget.Calculate(0, 4 * GiB, requestedMiB), Is.EqualTo(256 * MiB));
        }
    }
}
