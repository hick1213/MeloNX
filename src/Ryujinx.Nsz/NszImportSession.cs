using System.Runtime.InteropServices;
using System.Text.Json;

namespace Ryujinx.Nsz;

[StructLayout(LayoutKind.Sequential)]
public struct NszNativeProgress
{
    public uint Version;
    public int Phase;
    public long Completed, Total;
    public int Status, Kind;
    public ulong ApplicationId, ContentId;
}

// Portable lifetime/status layer used unchanged by the native export adapter.
public sealed class NszImportSession(NszImportJob job) : IDisposable
{
    private readonly object _gate = new();
    private bool _started, _running, _disposed;
    private int? _status;
    private string? _error;
    private NszImportResult? _result;
    public int Run()
    {
        lock (_gate)
        {
            if (_started || _disposed) return 2;
            _started = _running = true;
        }
        try { var result = job.Run(); lock (_gate) { _result = result; _status = 0; } }
        catch (OperationCanceledException) { lock (_gate) { _status = 1; _error = "cancelled"; } }
        catch (Exception error)
        {
            lock (_gate)
            {
                _status = 2;
                _error = error switch
                {
                    NszImportException { Code: NszImportError.InsufficientSpace } => "insufficient_space",
                    NszImportException { Code: NszImportError.WrongPackage } => "wrong_package",
                    NszImportException { Code: NszImportError.UnsupportedPackage } => "unsupported_package",
                    NszImportException { Code: NszImportError.MissingKey } => "missing_key",
                    InvalidDataException or NszImportException { Code: NszImportError.InvalidPackage } => "invalid_package",
                    IOException or UnauthorizedAccessException => "io_failure",
                    _ => "import_failed"
                };
            }
        }
        finally { lock (_gate) _running = false; }
        lock (_gate) return _status ?? 2;
    }
    public void Cancel() { lock (_gate) { if (!_disposed) job.Cancel(); } }
    public NszNativeProgress Progress()
    {
        lock (_gate)
        {
            var p = job.Progress; var package = _result?.Package;
            return new()
            {
                Version = 1, Phase = p.Stage switch { "preparing" => 0, "converting" => 1, "validating" => 2, "committing" => 3, "succeeded" => 4, "failed" => 5, "cancelled" => 6, _ => 7 },
                Completed = p.CompletedBytes, Total = p.TotalBytes, Status = _status ?? 0,
                Kind = (int)(package?.Kind ?? NszPackageKind.Unsupported), ApplicationId = package?.ApplicationId ?? 0, ContentId = package?.ContentId ?? 0
            };
        }
    }
    public string? ResultJson()
    {
        lock (_gate)
        {
            if (_running || !_status.HasValue || _disposed) return null;
            using var buffer = new MemoryStream();
            using (var writer = new Utf8JsonWriter(buffer))
            {
                writer.WriteStartObject(); writer.WriteNumber("version", 1); writer.WriteString("id", job.Id);
                writer.WriteNumber("status", _status.Value); writer.WriteString("path", _result?.OutputPath ?? job.CommittedPath);
                writer.WriteNumber("kind", (int)(_result?.Package.Kind ?? NszPackageKind.Unsupported));
                writer.WriteString("applicationId", _result?.Package.ApplicationId.ToString("x16"));
                writer.WriteString("contentId", _result?.Package.ContentId.ToString("x16"));
                writer.WriteString("errorCode", _error); writer.WriteEndObject();
            }
            if (buffer.Length > 65536) return null;
            return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
        }
    }
    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            if (_running) throw new InvalidOperationException("The native run still owns this session.");
            job.Dispose(); _disposed = true;
        }
    }
}
