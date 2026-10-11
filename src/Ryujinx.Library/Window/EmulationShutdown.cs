#nullable enable
using System;
using System.Threading;

namespace Ryujinx.Library;

/// Cross-thread stop requests never dispose resources or wait for the renderer.
public sealed class EmulationShutdown
{
    private readonly object _stopLock = new();
    private int _state; // 0: not started, 1: active, 2: stop requested
    public bool IsActive => Volatile.Read(ref _state) == 1;
    public bool StopRequested => Volatile.Read(ref _state) == 2;
    public bool TryStart() => Interlocked.CompareExchange(ref _state, 1, 0) == 0;
    public void RequestStop(Action wakePausedRenderer, Action wakeInput, Action cancelGpu)
    {
        lock (_stopLock)
        {
            if (Interlocked.Exchange(ref _state, 2) == 2) return;
            try { wakePausedRenderer(); }
            finally { try { wakeInput(); } finally { cancelGpu(); } }
        }
    }
    public static void RunMainLoop(Action loop, Action stop, Action waitGpu, Action disposeGuest, Action disposeGpu, Action joinRender)
    {
        try { loop(); }
        finally
        {
            try { stop(); }
            finally
            {
                waitGpu();
                try { disposeGuest(); }
                finally { try { disposeGpu(); } finally { joinRender(); } }
            }
        }
    }
    public static void RunRender(Action render, Action finalize, Action signalEnded)
    {
        try { render(); }
        finally { try { finalize(); } finally { signalEnded(); } }
    }
}

/// Armed synchronously before dispatching the native worker; early exit cannot
/// be lost while the worker is loading a package or constructing its window.
public sealed class EmulationRunSession
{
    private readonly object _lock = new();
    private bool _stopRequested;
    private Action? _stopWindow;
    private bool _completed;
    public bool StopRequested { get { lock (_lock) return _stopRequested; } }
    public void PublishWindow(Action stop)
    {
        lock (_lock) { _stopWindow = stop; if (_stopRequested) stop(); }
    }
    public void RequestStop()
    {
        lock (_lock) { _stopRequested = true; _stopWindow?.Invoke(); }
    }
    public void WhileRunning(Action action)
    {
        lock (_lock) { if (!_stopRequested && !_completed) action(); }
    }
    public void Complete() { lock (_lock) { _completed = true; _stopWindow = null; } }
}
