using System.Runtime.InteropServices;
using NUnit.Framework;
using Ryujinx.Cpu.LightningJit;
using Ryujinx.Cpu.LightningJit.Cache;
namespace Ryujinx.RuntimeSafety.Tests;
public class JitCacheOwnershipTests {
    [OneTimeSetUp] public void Initialize() => DualMappedNoWxCache.InitMemoryCache();
    [Test] public void ConcurrentContextsCannotOverwriteEachOthersCode() {
        using var a = new DualMappedNoWxCache(new Translator()); using var b = new DualMappedNoWxCache(new Translator());
        nint first = a.MapPageAligned([0x11, 0x22, 0x33, 0x44]);
        nint second = b.MapPageAligned([0xaa, 0xbb, 0xcc, 0xdd]);
        Assert.That(second, Is.Not.EqualTo(first)); Assert.That(Marshal.ReadByte(first), Is.EqualTo(0x11));
    }
    [Test] public void ReleasingOneContextReturnsOnlyItsOwnCodeRanges() {
        var a = new DualMappedNoWxCache(new Translator()); using var b = new DualMappedNoWxCache(new Translator());
        nint first = a.MapPageAligned([0x11]); nint second = b.MapPageAligned([0x22]);
        a.Dispose(); a.Dispose(); using var next = new DualMappedNoWxCache(new Translator());
        nint reused = next.MapPageAligned([0x33]);
        Assert.That(reused, Is.EqualTo(first)); Assert.That(reused, Is.Not.EqualTo(second)); Assert.That(Marshal.ReadByte(second), Is.EqualTo(0x22));
    }
    [Test] public void ReleasedContextCannotWriteIntoReusedCode() {
        var cache = new DualMappedNoWxCache(new Translator()); cache.MapPageAligned([0x11]); cache.Dispose();
        Assert.Throws<ObjectDisposedException>(() => cache.MapPageAligned([0x22]));
    }
    [Test] public void ParallelContextsReceiveDisjointCodePages() {
        var addresses = new System.Collections.Concurrent.ConcurrentBag<nint>();
        var contexts = Enumerable.Range(0, 32).Select(_ => new DualMappedNoWxCache(new Translator())).ToArray();
        try {
            Parallel.ForEach(contexts, cache => addresses.Add(cache.MapPageAligned([0x11, 0x22])));
            Assert.That(addresses.Distinct().Count(), Is.EqualTo(contexts.Length));
        } finally { foreach (var cache in contexts) cache.Dispose(); }
    }
    [Test] public void RepeatedContextExitReturnsCodeSpaceForTheNextRun() {
        nint? previous = null;
        for (int i = 0; i < 100; i++) {
            using var cache = new DualMappedNoWxCache(new Translator());
            var pointer = cache.MapPageAligned([0x11]);
            if (previous.HasValue) Assert.That(pointer, Is.EqualTo(previous.Value));
            previous = pointer;
        }
    }
}
