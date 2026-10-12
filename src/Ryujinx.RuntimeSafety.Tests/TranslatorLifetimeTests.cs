using NUnit.Framework;
using Ryujinx.Cpu.LightningJit;
namespace Ryujinx.RuntimeSafety.Tests;
public class TranslatorLifetimeTests {
    [Test] public void LastExecutingThreadReleasesRequestedResourcesExactlyOnce() {
        var life = new TranslatorExecutionLifetime(); int releases = 0;
        Assert.That(life.TryEnter(), Is.True); Assert.That(life.TryEnter(), Is.True);
        life.RequestDispose(() => releases++); life.RequestDispose(() => releases++);
        Assert.That(releases, Is.Zero); Assert.That(life.TryEnter(), Is.False);
        life.Exit(() => releases++); Assert.That(releases, Is.Zero);
        life.Exit(() => releases++); Assert.That(releases, Is.EqualTo(1));
        life.RequestDispose(() => releases++); Assert.That(releases, Is.EqualTo(1));
    }
    [Test] public void DisposalRequestedFromInsideGuestCallbackDoesNotDeadlockOrFreeActiveCode() {
        var life = new TranslatorExecutionLifetime(); int releases = 0; bool returned = false;
        Assert.That(life.TryEnter(), Is.True);
        life.RequestDispose(() => releases++); returned = true;
        Assert.That(returned, Is.True); Assert.That(releases, Is.Zero);
        life.Exit(() => releases++); Assert.That(releases, Is.EqualTo(1));
    }
    [Test] public void CallbackFailureStillReturnsTheExecutionLease() {
        var life = new TranslatorExecutionLifetime(); int releases = 0;
        Assert.Throws<IOException>(() => {
            Assert.That(life.TryEnter(), Is.True);
            try { life.RequestDispose(() => releases++); throw new IOException(); }
            finally { life.Exit(() => releases++); }
        });
        Assert.That(releases, Is.EqualTo(1));
    }
    [Test] public void CacheInvalidationCannotAccessDisposedResources() {
        var life = new TranslatorExecutionLifetime(); int writes = 0;
        life.WhileAlive(() => writes++); life.RequestDispose(() => {}); life.WhileAlive(() => writes++);
        Assert.That(writes, Is.EqualTo(1));
    }
    [Test] public void CleanupFailureCannotSkipTableAndCodeLeaseRelease() {
        var order = new List<string>();
        Assert.Throws<IOException>(() => TranslatorExecutionLifetime.DisposeResources(
            () => { order.Add("stubs"); throw new IOException(); },
            () => order.Add("table"), () => order.Add("code")));
        Assert.That(order, Is.EqualTo(new[] { "stubs", "table", "code" }));
    }
}
