using System.Text;

namespace Ryujinx.Nsz;

// Run owns all open streams. Cancellation may prevent commit, but never deletes a committed file.
public sealed class NszImportJob : IDisposable
{
    internal const long SpaceReserve = 256L << 20;
    private const string OwnerMagic = "MeloNX.NSZ.v1";
    private static readonly Guid Session = Guid.NewGuid();
    private static readonly object StagingLock = new();
    private static int _activeJobs;
    private readonly object _gate = new();
    private readonly CancellationTokenSource _cancellation = new();
    private readonly NszImportRequest _request;
    private readonly INszPackageValidator _validator;
    private readonly NszLimits _limits;
    private readonly Func<long> _availableBytes;
    private readonly ImportJobHooks _hooks;
    private ConversionProgress _progress = new(0, 0, "preparing");
    private bool _started, _ended, _disposed;
    private string? _committedPath;
    public ConversionProgress Progress { get { lock (_gate) return _progress; } }
    public bool HasEnded { get { lock (_gate) return _ended; } }
    public string? CommittedPath { get { lock (_gate) return _committedPath; } }
    public Guid Id => _request.Id;

    public NszImportJob(NszImportRequest request, INszPackageValidator validator,
        NszLimits limits, Func<long> availableBytes) : this(request, validator, limits, availableBytes, new()) { }

    internal NszImportJob(NszImportRequest request, INszPackageValidator validator,
        NszLimits limits, Func<long> availableBytes, ImportJobHooks hooks)
    {
        ArgumentNullException.ThrowIfNull(request); ArgumentNullException.ThrowIfNull(validator);
        ArgumentNullException.ThrowIfNull(limits); ArgumentNullException.ThrowIfNull(availableBytes);
        string name = request.OutputName;
        if (request.Id == Guid.Empty || string.IsNullOrWhiteSpace(name) || Encoding.UTF8.GetByteCount(name) > 255 ||
            name.IndexOfAny(['/', '\\', ':', '*', '?', '"', '<', '>', '|', '\0']) >= 0 || name.Any(char.IsControl) ||
            name != name.Trim() || !name.EndsWith(".nsp", StringComparison.OrdinalIgnoreCase) || name == ".nsp" ||
            !Enum.IsDefined(request.ExpectedKind) || request.ExpectedKind == NszPackageKind.Unsupported)
            throw new ArgumentException("Invalid import request.");
        _request = request with { Source = Path.GetFullPath(request.Source), TargetRoot = Path.GetFullPath(request.TargetRoot) };
        _validator = validator; _limits = limits; _availableBytes = availableBytes; _hooks = hooks;
    }

    public NszImportResult Run()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_started) throw new InvalidOperationException("An import job can run only once.");
            _started = true;
        }
        lock (StagingLock) _activeJobs++;
        string staging = Path.Combine(_request.TargetRoot, ".imports", _request.Id.ToString("D"));
        string partial = Path.Combine(staging, "result.partial");
        bool ownsStaging = false;
        try
        {
            var token = _cancellation.Token;
            token.ThrowIfCancellationRequested();
            using (var input = new FileStream(_request.Source, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
            {
                long total = NszConverter.EstimateOutputSize(input, _limits, token);
                SetProgress(new(0, total, "preparing")); CheckSpace(total);
                lock (StagingLock)
                {
                    Directory.CreateDirectory(_request.TargetRoot);
                    RejectLink(_request.TargetRoot);
                    Directory.CreateDirectory(Path.GetDirectoryName(staging)!);
                    RejectLink(Path.GetDirectoryName(staging)!);
                    if (Directory.Exists(staging) || File.Exists(staging)) throw new IOException("Import staging already exists.");
                    Directory.CreateDirectory(staging); ownsStaging = true;
                    File.WriteAllText(Path.Combine(staging, "owner"), $"{OwnerMagic}\n{_request.Id:D}\n{Session:D}");
                }
                using (var file = _hooks.OpenOutput?.Invoke(partial) ?? new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 20))
                {
                    using var quota = new SpaceCheckedWriteStream(file, total, CheckSpace, token);
                    NszConverter.Convert(input, quota, _limits, token, SetProgress);
                    file.Flush();
                    if (file is FileStream fs) fs.Flush(flushToDisk: true);
                }
            }
            token.ThrowIfCancellationRequested();
            SetStage("validating");
            NszPackage package = _validator.Validate(partial, token);
            if (package.Kind == NszPackageKind.Unsupported)
                throw new NszImportException(NszImportError.UnsupportedPackage, "Package type is unsupported or ambiguous.");
            if (package.Kind != _request.ExpectedKind || (_request.ExpectedApplicationId is ulong expected && expected != package.ApplicationId))
                throw new NszImportException(NszImportError.WrongPackage, "Package does not match the selected game or content type.");
            SetStage("committing"); _hooks.BeforeCommit?.Invoke();
            lock (_gate)
            {
                token.ThrowIfCancellationRequested();
                _committedPath = CommitUnique(partial);
            }
            // Barrier is after the atomic decision: a late cancel retains this file and suppresses caller registration.
            _hooks.AfterCommit?.Invoke();
            lock (_gate)
            {
                token.ThrowIfCancellationRequested();
                _progress = _progress with { Stage = "succeeded" };
                return new(_request.Id, _committedPath!, package);
            }
        }
        catch (OperationCanceledException) { SetStage("cancelled"); throw; }
        catch (IOException error) when ((error.HResult & 0xffff) is 28 or 112)
        {
            SetStage("failed");
            throw new NszImportException(NszImportError.InsufficientSpace, "The disk became full while importing the package.");
        }
        catch { SetStage("failed"); throw; }
        finally
        {
            // Every stream has unwound before cleanup. The source and committed path are never cleanup targets.
            if (ownsStaging) TryRemoveOwned(staging);
            lock (StagingLock) _activeJobs--;
            lock (_gate) _ended = true;
        }
    }

    public void Cancel()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _cancellation.Cancel();
        }
    }
    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            if (_started && !_ended) throw new InvalidOperationException("Wait for Run to end before disposing an import job.");
            _disposed = true; _cancellation.Dispose();
        }
    }
    private void SetProgress(ConversionProgress progress) { lock (_gate) _progress = progress; }
    private void SetStage(string stage) { lock (_gate) _progress = _progress with { Stage = stage }; }
    private void CheckSpace(long remaining)
    {
        if (_availableBytes() < checked(remaining + SpaceReserve))
            throw new NszImportException(NszImportError.InsufficientSpace, "Not enough space for the reconstructed package.");
    }
    private string CommitUnique(string partial)
    {
        string basename = Path.GetFileNameWithoutExtension(_request.OutputName);
        for (int suffix = 0; suffix < 10000; suffix++)
        {
            string ending = $" ({suffix}).nsp";
            string name = suffix == 0 ? _request.OutputName : Utf8Prefix(basename, 255 - Encoding.UTF8.GetByteCount(ending)) + ending;
            string candidate = Path.Combine(_request.TargetRoot, name);
            if (File.Exists(candidate) || Directory.Exists(candidate)) continue;
            try { File.Move(partial, candidate, overwrite: false); return candidate; }
            catch (IOException error) when ((error.HResult & 0xffff) is 17 or 80 or 183 && File.Exists(partial) &&
                (File.Exists(candidate) || Directory.Exists(candidate))) { }
        }
        throw new IOException("No unused output filename is available.");
    }
    private static string Utf8Prefix(string value, int maxBytes)
    {
        int bytes = 0; var prefix = new StringBuilder();
        foreach (Rune rune in value.EnumerateRunes())
        {
            if (bytes + rune.Utf8SequenceLength > maxBytes) break;
            bytes += rune.Utf8SequenceLength; prefix.Append(rune.ToString());
        }
        return prefix.ToString();
    }

    // Call only during exclusive importer startup. Unmarked, linked, malformed and current-session directories are retained.
    public static int CleanupStaleImports(string targetRoot)
    {
        lock (StagingLock)
        {
            if (_activeJobs != 0) throw new InvalidOperationException("Stale import cleanup requires an idle importer.");
            string root = Path.Combine(Path.GetFullPath(targetRoot), ".imports");
            if (!Directory.Exists(root)) return 0;
            RejectLink(targetRoot); RejectLink(root);
            int removed = 0;
            foreach (string path in Directory.EnumerateDirectories(root))
            {
                if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || !Guid.TryParseExact(Path.GetFileName(path), "D", out var id)) continue;
                string owner = Path.Combine(path, "owner");
                if (!File.Exists(owner) || (File.GetAttributes(owner) & FileAttributes.ReparsePoint) != 0 || new FileInfo(owner).Length > 200) continue;
                string[] fields = File.ReadAllText(owner).Split('\n');
                if (fields.Length != 3 || fields[0] != OwnerMagic || fields[1] != id.ToString("D") || !Guid.TryParseExact(fields[2], "D", out var session) || session == Session) continue;
                if (TryRemoveOwned(path)) removed++;
            }
            return removed;
        }
    }
    private static void RejectLink(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Import directories must not be links.");
    }
    private static bool TryRemoveOwned(string path)
    {
        try
        {
            var files = Directory.GetFileSystemEntries(path);
            if (files.Any(p => Path.GetFileName(p) is not ("owner" or "result.partial") ||
                (File.GetAttributes(p) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)) return false;
            foreach (string file in files) File.Delete(file);
            Directory.Delete(path); return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    private sealed class SpaceCheckedWriteStream(Stream file, long total, Action<long> checkSpace, CancellationToken cancellation) : Stream
    {
        private long _written, _nextSpaceCheck;
        public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));
        public override void Write(ReadOnlySpan<byte> buffer)
        {
            cancellation.ThrowIfCancellationRequested();
            if (_written >= _nextSpaceCheck)
            {
                checkSpace(Math.Max(0, total - _written)); _nextSpaceCheck = checked(_written + (1 << 20));
            }
            file.Write(buffer); _written = checked(_written + buffer.Length);
        }
        public override void Flush() => file.Flush();
        public override bool CanWrite => true;
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override long Length => _written;
        public override long Position { get => _written; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}

// Internal deterministic fault/barrier hooks; never exposed through the production native request.
internal sealed record ImportJobHooks(Action? BeforeCommit = null, Action? AfterCommit = null,
    Func<string, Stream>? OpenOutput = null);
