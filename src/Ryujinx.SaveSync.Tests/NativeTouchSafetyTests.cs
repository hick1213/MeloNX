using NUnit.Framework;
using Ryujinx.Common.Configuration;
using Ryujinx.Library;
namespace Ryujinx.SaveSync.Tests;
[NonParallelizable]
public class NativeTouchSafetyTests {
    private static unsafe void Begin(int id) { delegate* unmanaged<float, float, int, void> f = &NativeTouchDriver.TouchBeganAtPoint; f(10, 20, id); }
    private static unsafe void End(int id) { delegate* unmanaged<int, void> f = &NativeTouchDriver.TouchEndedForIndex; f(id); }
    [TearDown] public void Clear() { for (int id = 0; id < 8; id++) End(id); }
    [Test] public void DisposedDriverCannotLeaveTouchesForNextRun() {
        var driver = new NativeTouchDriver(HideCursorMode.Never);
        Begin(0); Assert.That(driver.CurrentPosition.Length, Is.EqualTo(1));
        driver.Dispose(); Assert.That(driver.CurrentPosition, Is.Empty);
    }
    [Test] public void ConcurrentUIKitWritesAndInputSnapshotsCannotInvalidateEnumeration() {
        using var driver = new NativeTouchDriver(HideCursorMode.Never);
        using var start = new ManualResetEventSlim(false);
        var writer = Task.Run(() => { start.Wait(); for (int i = 0; i < 100000; i++) { Begin(i % 8); End(i % 8); } });
        start.Set();
        Exception? failure = null;
        try { for (int i = 0; i < 100000; i++) { _ = driver.CurrentPosition; driver.UpdatePosition(); } }
        catch (Exception error) { failure = error; }
        Assert.That(writer.Wait(10000), Is.True);
        Assert.That(failure, Is.Null);
    }
}
