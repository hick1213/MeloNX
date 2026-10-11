using System.Text.Json;

namespace Ryujinx.SaveSync;

public sealed class SaveSyncJob
{
    private readonly object _gate = new();
    private readonly SaveNativeRequest _request;
    private readonly Func<SaveSyncJob, SaveNativeResult> _action;
    private readonly CancellationTokenSource _cancellation = new();
    private int _state;
    private SaveNativeResult? _result;
    private SaveNativeProgress _progress = new("preparing", 0, 0);
    private Action? _stopHandler;
    public SaveSyncJob(SaveNativeRequest request, Func<SaveSyncJob, SaveNativeResult> action) { _request = request; _action = action; }
    public bool StopRequested => _cancellation.IsCancellationRequested;
    public CancellationToken Cancellation => _cancellation.Token;
    public void SetStopHandler(Action action) { lock (_gate) { _stopHandler = action; if (StopRequested) action(); } }
    public int Run()
    {
        lock (_gate) { if (_state != 0) return 2; _state = 1; }
        SaveNativeResult result;
        try { result = _action(this); }
        catch (OperationCanceledException) { result = Failure(1, "cancelled"); }
        catch (Exception error) { result = Failure(error is SaveSyncException { Code: "rollbackRequired" } ? 3 : 2, error is SaveSyncException save ? save.Code : "io_failure"); }
        lock (_gate) { _result = result; _state = 2; }
        return result.Status;
    }
    private SaveNativeResult Failure(int status, string code) => new(1, _request.Id, status, null, null, null, [], [], code);
    public void RequestSafeStop()
    {
        lock (_gate) { if (_state == 3) return; _cancellation.Cancel(); _stopHandler?.Invoke(); }
    }
    public void Progress(string phase, long completed, long total) { lock (_gate) _progress = new(phase, completed, total); }
    public string ProgressJson() { lock (_gate) return JsonSerializer.Serialize(_progress, SaveJsonContext.Default.SaveNativeProgress); }
    public string? ResultJson() { lock (_gate) return _state == 2 && _result is not null ? SaveNativeJson.Encode(_result) : null; }
    public bool TryFree()
    {
        lock (_gate)
        {
            if (_state is 1 or 3) return false;
            _state = 3; _cancellation.Dispose(); _stopHandler = null; return true;
        }
    }
}
