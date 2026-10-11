using System.Reflection;
using NUnit.Framework;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;

namespace Ryujinx.SaveSync.Tests;

public class ThreadedRendererShutdownTests
{
    [Test]
    public void DisposeAfterGpuWorkEndsWaitsForBackendBeforeClosingEvents()
    {
        IRenderer renderer = DispatchProxy.Create<IRenderer, FakeRenderer>();
        var fake = (FakeRenderer)renderer;
        var threaded = new ThreadedRenderer(renderer);
        using var gpuEnded = new ManualResetEventSlim(false);
        Exception? failure = null;
        var backend = new Thread(() => {
            try { threaded.RunLoop(() => gpuEnded.Set()); }
            catch (Exception error) { failure = error; }
        });
        backend.Start(); Assert.That(gpuEnded.Wait(2000), Is.True);
        threaded.Dispose();
        Assert.That(backend.Join(2000), Is.True);
        Assert.That(failure, Is.Null);
        Assert.That(fake.DisposeCount, Is.EqualTo(1));
    }
    [Test]
    public void MainLoopFailureStopsGpuAndJoinsRealBackendBeforeReturning()
    {
        IRenderer renderer = DispatchProxy.Create<IRenderer, FakeRenderer>();
        var fake = (FakeRenderer)renderer;
        var threaded = new ThreadedRenderer(renderer);
        using var stop = new ManualResetEventSlim(false);
        using var entered = new ManualResetEventSlim(false);
        using var gpuEnded = new ManualResetEventSlim(false);
        Exception? failure = null;
        var backend = new Thread(() => {
            try { threaded.RunLoop(() => { entered.Set(); stop.Wait(); gpuEnded.Set(); }); }
            catch (Exception error) { failure = error; }
        });
        backend.Start(); Assert.That(entered.Wait(2000), Is.True);
        bool guestDisposed = false, joined = false;
        Assert.Throws<IOException>(() => Ryujinx.Library.EmulationShutdown.RunMainLoop(
            () => throw new IOException("main loop"), () => stop.Set(),
            () => Assert.That(gpuEnded.Wait(2000), Is.True),
            () => guestDisposed = true,
            () => { Assert.That(guestDisposed, Is.True); threaded.Dispose(); },
            () => joined = backend.Join(2000)));
        Assert.That(joined, Is.True); Assert.That(failure, Is.Null);
        Assert.That(fake.DisposeCount, Is.EqualTo(1));
    }
    public class FakeRenderer : DispatchProxy
    {
        public int DisposeCount;
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            if (method!.Name == "Dispose") DisposeCount++;
            return method.ReturnType == typeof(void) ? null : method.ReturnType.IsValueType ? Activator.CreateInstance(method.ReturnType) : null;
        }
    }
}
