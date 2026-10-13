using NUnit.Framework;
using Ryujinx.Graphics.Vulkan;

namespace Ryujinx.RuntimeSafety.Tests;

public class PipelineCacheStorageBudgetTests
{
    [Test]
    public void ActualDemonSlayerCacheCanBeRetainedOnKnownLargeAppleHeap()
    {
        long budget = PipelineCacheStorageBudget.GetMaximumSize(true, 11524UL * 1024 * 1024);
        Assert.That(PipelineCacheStorageBudget.IsSizeAllowed(187097842, budget), Is.True,
            "The driver returned this valid size on the iPad, but the old bound rejected saving it.");
    }

    [TestCase(true, 0UL)]
    [TestCase(true, 8UL * 1024 * 1024 * 1024)]
    [TestCase(true, 10UL * 1024 * 1024 * 1024 - 1)]
    [TestCase(false, 16UL * 1024 * 1024 * 1024)]
    public void UnknownSmallerAndNonAppleHeapsKeepPriorReadAndWriteBound(bool apple, ulong heap)
    {
        long budget = PipelineCacheStorageBudget.GetMaximumSize(apple, heap);
        Assert.That(PipelineCacheStorageBudget.IsSizeAllowed(128UL * 1024 * 1024, budget), Is.True);
        Assert.That(PipelineCacheStorageBudget.IsSizeAllowed(187097842, budget), Is.False);
    }

    [TestCase(10UL * 1024 * 1024 * 1024)]
    [TestCase(11524UL * 1024 * 1024)]
    [TestCase(ulong.MaxValue)]
    public void LargeAppleCacheStillHasFiniteReadAndWriteBound(ulong heap)
    {
        long budget = PipelineCacheStorageBudget.GetMaximumSize(true, heap);
        Assert.That(PipelineCacheStorageBudget.IsSizeAllowed(512UL * 1024 * 1024, budget), Is.True);
        Assert.That(PipelineCacheStorageBudget.IsSizeAllowed(512UL * 1024 * 1024 + 1, budget), Is.False);
        Assert.That(PipelineCacheStorageBudget.IsSizeAllowed(0, budget), Is.False);
        Assert.That(PipelineCacheStorageBudget.IsSizeAllowed(ulong.MaxValue, budget), Is.False);
    }
}
