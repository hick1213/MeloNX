using NUnit.Framework;
using Ryujinx.Library;

namespace Ryujinx.SaveSync.Tests;

public class EmulationShutdownTests
{
    [Test]
    public void StopBeforeExecutionCannotRestartTheStoppedWindow()
    {
        var shutdown = new EmulationShutdown();
        shutdown.RequestStop(() => { }, () => { }, () => { });
        Assert.That(shutdown.TryStart(), Is.False);
        Assert.That(shutdown.IsActive, Is.False);
    }
    [Test]
    public void PausedRendererIsWokenAndCompletionFollowsFinalization()
    {
        var shutdown = new EmulationShutdown();
        Assert.That(shutdown.TryStart(), Is.True);
        using var paused = new ManualResetEventSlim(false);
        using var entered = new ManualResetEventSlim(false);
        using var ended = new ManualResetEventSlim(false);
        bool finalized = false, inputWoken = false, cancelled = false;
        var worker = new Thread(() => EmulationShutdown.RunRender(() => {
            entered.Set(); paused.Wait();
            if (shutdown.StopRequested) return;
            Assert.Fail("Paused renderer resumed without stop");
        }, () => finalized = true, () => { Assert.That(finalized, Is.True); ended.Set(); }));
        worker.Start(); Assert.That(entered.Wait(2000), Is.True);
        shutdown.RequestStop(() => paused.Set(), () => inputWoken = true, () => cancelled = true);
        Assert.That(ended.Wait(2000), Is.True); Assert.That(worker.Join(2000), Is.True);
        Assert.That(inputWoken && cancelled, Is.True); Assert.That(shutdown.IsActive, Is.False);
    }
    [Test]
    public void RepeatedStopDoesNotTouchAlreadyClosedWakeHandles()
    {
        var shutdown = new EmulationShutdown();
        shutdown.RequestStop(() => { }, () => { }, () => { });
        Assert.DoesNotThrow(() => shutdown.RequestStop(() => throw new ObjectDisposedException("pause"),
            () => throw new ObjectDisposedException("input"), () => throw new ObjectDisposedException("gpu")));
    }
    [Test]
    public void StopWhileWindowIsNotYetPublishedAppliesToThatRunOnly()
    {
        var session = new EmulationRunSession();
        var oldWindow = new EmulationShutdown();
        session.RequestStop(); session.PublishWindow(() => oldWindow.RequestStop(() => { }, () => { }, () => { }));
        Assert.That(oldWindow.TryStart(), Is.False);
        var next = new EmulationRunSession(); var newWindow = new EmulationShutdown();
        next.PublishWindow(() => newWindow.RequestStop(() => { }, () => { }, () => { }));
        Assert.That(next.StopRequested, Is.False); Assert.That(newWindow.TryStart(), Is.True);
    }
    [Test]
    public void RendererFailureStillAcknowledgesEndAfterCleanup()
    {
        var order = new List<string>();
        Assert.Throws<IOException>(() => EmulationShutdown.RunRender(() => throw new IOException("render"),
            () => order.Add("cleanup"), () => order.Add("ended")));
        Assert.That(order, Is.EqualTo(new[] { "cleanup", "ended" }));
    }
}
