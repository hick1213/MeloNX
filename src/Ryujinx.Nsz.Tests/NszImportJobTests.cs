using NUnit.Framework;

namespace Ryujinx.Nsz.Tests;

[TestFixture]
public class NszImportJobTests
{
    [Test]
    public async Task CancelBeforeCommitLeavesExistingFilesUntouched()
    {
        using var f = JobFixture.AtValidationBarrier();
        var run = Task.Run(f.Job.Run);
        f.WaitUntilValidation(); f.Job.Cancel(); f.ReleaseValidation();
        Assert.ThrowsAsync<OperationCanceledException>(async () => await run);
        await Task.WhenAny(run, Task.Delay(5000));
        f.AssertPreserved();
        Assert.That(f.Job.CommittedPath, Is.Null);
        Assert.That(f.Job.HasEnded, Is.True);
        Assert.That(f.StagingDirectories(), Is.Empty);
    }

    [Test]
    public void SuccessUsesUniqueNameAndKeepsOriginal()
    {
        using var f = new JobFixture();
        var result = f.Job.Run();
        Assert.That(result.OutputPath, Is.EqualTo(Path.Combine(f.Root, "game (1).nsp")));
        Assert.That(File.ReadAllBytes(result.OutputPath), Is.EqualTo(f.Expected));
        Assert.That(f.Job.Progress.Stage, Is.EqualTo("succeeded"));
        f.AssertPreserved(); Assert.That(f.StagingDirectories(), Is.Empty);
        Assert.Throws<InvalidOperationException>(() => f.Job.Run());
    }

    [Test]
    public void ValidationFailureOnlyRemovesOwnedStaging()
    {
        using var f = new JobFixture(validate: (_, _) => throw new InvalidDataException("invalid"));
        Assert.Throws<InvalidDataException>(() => f.Job.Run());
        f.AssertPreserved(); Assert.That(f.StagingDirectories(), Is.Empty);
        Assert.That(f.Job.Progress.Stage, Is.EqualTo("failed"));
    }

    [Test]
    public void PreflightAndPeriodicSpaceChecksFailWithoutModifyingSource()
    {
        using (var f = new JobFixture(available: () => 0))
        {
            var error = Assert.Throws<NszImportException>(() => f.Job.Run());
            Assert.That(error!.Code, Is.EqualTo(NszImportError.InsufficientSpace)); f.AssertPreserved();
        }
        int checks = 0;
        using (var f = new JobFixture(available: () => ++checks > 1 ? 0 : long.MaxValue))
        {
            var error = Assert.Throws<NszImportException>(() => f.Job.Run());
            Assert.That(error!.Code, Is.EqualTo(NszImportError.InsufficientSpace));
            Assert.That(checks, Is.GreaterThan(1)); f.AssertPreserved();
            Assert.That(f.StagingDirectories(), Is.Empty);
        }
    }

    [TestCase("../escape.nsp")]
    [TestCase("/escape.nsp")]
    [TestCase("a\\b.nsp")]
    [TestCase("a\0.nsp")]
    [TestCase("game.nsz")]
    public void RejectsUnsafeOutputNames(string name)
    {
        using var f = new JobFixture(createJob: false);
        Assert.Throws<ArgumentException>(() => f.CreateJob(outputName: name)); f.AssertPreserved();
    }

    [Test]
    public void EmptyInputAndWrongPackageRoleFailBeforeCommit()
    {
        using (var f = new JobFixture())
        {
            File.WriteAllBytes(f.SourcePath, []);
            Assert.Throws<InvalidDataException>(() => f.Job.Run());
            Assert.That(File.ReadAllBytes(f.ExistingPath), Is.EqualTo(f.ExistingBytes));
            Assert.That(f.StagingDirectories(), Is.Empty);
        }
        using (var f = new JobFixture(validate: (_, _) => new(NszPackageKind.Patch, 0x100, 0x180)))
        {
            var error = Assert.Throws<NszImportException>(() => f.Job.Run());
            Assert.That(error!.Code, Is.EqualTo(NszImportError.WrongPackage)); f.AssertPreserved();
        }
        using (var f = new JobFixture(validate: (_, _) => new(NszPackageKind.Application, 0x200, 0x200)))
        {
            var error = Assert.Throws<NszImportException>(() => f.Job.Run());
            Assert.That(error!.Code, Is.EqualTo(NszImportError.WrongPackage)); f.AssertPreserved();
        }
    }

    [Test]
    public void SourceEqualToCandidateIsNeverOverwritten()
    {
        using var f = new JobFixture(createJob: false);
        f.CreateJob(outputName: Path.GetFileName(f.SourcePath));
        var result = f.Job.Run();
        Assert.That(result.OutputPath, Is.Not.EqualTo(f.SourcePath)); f.AssertPreserved();
        Assert.That(File.ReadAllBytes(result.OutputPath), Is.EqualTo(f.Expected));
    }

    [Test]
    public void DisposeWhileRunningIsRejectedAndPreStartCancellationEndsSafely()
    {
        using (var f = JobFixture.AtValidationBarrier())
        {
            var run = Task.Run(f.Job.Run); f.WaitUntilValidation();
            Assert.Throws<InvalidOperationException>(() => f.Job.Dispose());
            f.Job.Cancel(); f.ReleaseValidation();
            Assert.ThrowsAsync<OperationCanceledException>(async () => await run);
            f.AssertPreserved();
        }
        using (var f = new JobFixture())
        {
            f.Job.Cancel(); Assert.Throws<OperationCanceledException>(() => f.Job.Run());
            Assert.That(f.Job.HasEnded, Is.True); f.AssertPreserved();
        }
    }

    [TestCase(false)]
    [TestCase(true)]
    public void CancellationIsOrderedAgainstAtomicCommit(bool afterCommit)
    {
        using var f = new JobFixture(createJob: false);
        using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
        Action barrier = () => { entered.Set(); if (!release.Wait(10000)) throw new TimeoutException(); };
        f.CreateJob(hooks: afterCommit ? new(AfterCommit: barrier) : new(BeforeCommit: barrier));
        var run = Task.Run(f.Job.Run);
        Assert.That(entered.Wait(10000), Is.True); f.Job.Cancel(); release.Set();
        Assert.ThrowsAsync<OperationCanceledException>(async () => await run);
        Assert.That(f.Job.HasEnded, Is.True); f.AssertPreserved();
        if (afterCommit)
        {
            Assert.That(f.Job.CommittedPath, Is.Not.Null);
            Assert.That(File.ReadAllBytes(f.Job.CommittedPath!), Is.EqualTo(f.Expected));
        }
        else Assert.That(f.Job.CommittedPath, Is.Null);
        Assert.That(f.StagingDirectories(), Is.Empty);
    }

    [Test]
    public void DiskFullWriteUnwindsBeforeDeletingOwnedPartial()
    {
        using var f = new JobFixture(createJob: false);
        f.CreateJob(hooks: new(OpenOutput: path => new DiskFullStream(path)));
        var error = Assert.Throws<NszImportException>(() => f.Job.Run());
        Assert.That(error!.Code, Is.EqualTo(NszImportError.InsufficientSpace));
        Assert.That(f.Job.HasEnded, Is.True); f.AssertPreserved();
        Assert.That(f.StagingDirectories(), Is.Empty);
    }

    [Test]
    public void MaximumLengthNameStillSupportsUniqueCommit()
    {
        using var f = new JobFixture(createJob: false);
        string name = new('a', 251); name += ".nsp";
        byte[] old = [6, 7]; string existing = Path.Combine(f.Root, name); File.WriteAllBytes(existing, old);
        f.CreateJob(outputName: name);
        var result = f.Job.Run();
        Assert.That(System.Text.Encoding.UTF8.GetByteCount(Path.GetFileName(result.OutputPath)), Is.LessThanOrEqualTo(255));
        Assert.That(File.ReadAllBytes(existing), Is.EqualTo(old)); f.AssertPreserved();
    }

    [Test]
    public void StartupCleanupOnlyDeletesMarkedPriorSessionStaging()
    {
        using var f = new JobFixture();
        string root = Path.Combine(f.Root, ".imports"); Directory.CreateDirectory(root);
        string old = CreateStaging(root, Guid.NewGuid(), true);
        string unmarked = CreateStaging(root, Guid.NewGuid(), false);
        string unexpected = CreateStaging(root, Guid.NewGuid(), true); File.WriteAllText(Path.Combine(unexpected, "user-file"), "retain");
        string linked = CreateStaging(root, Guid.NewGuid(), true);
        File.Delete(Path.Combine(linked, "result.partial")); File.CreateSymbolicLink(Path.Combine(linked, "result.partial"), f.SourcePath);
        Assert.That(NszImportJob.CleanupStaleImports(f.Root), Is.EqualTo(1));
        Assert.That(Directory.Exists(old), Is.False);
        Assert.That(Directory.Exists(unmarked), Is.True); Assert.That(Directory.Exists(unexpected), Is.True);
        Assert.That(Directory.Exists(linked), Is.True); f.AssertPreserved();
    }

    [Test]
    public void CleanupCannotRaceActiveJobOrReuseAnExistingJobDirectory()
    {
        using (var f = JobFixture.AtValidationBarrier())
        {
            var run = Task.Run(f.Job.Run); f.WaitUntilValidation();
            Assert.Throws<InvalidOperationException>(() => NszImportJob.CleanupStaleImports(f.Root));
            f.ReleaseValidation(); Assert.That(run.GetAwaiter().GetResult().OutputPath, Is.Not.Empty); f.AssertPreserved();
        }
        using (var f = new JobFixture(createJob: false))
        {
            var id = Guid.NewGuid(); string existing = CreateStaging(Path.Combine(f.Root, ".imports"), id, false);
            f.CreateJob(id: id); Assert.Throws<IOException>(() => f.Job.Run());
            Assert.That(Directory.Exists(existing), Is.True); f.AssertPreserved();
        }
    }

    private static string CreateStaging(string root, Guid id, bool marked)
    {
        string path = Path.Combine(root, id.ToString("D")); Directory.CreateDirectory(path);
        File.WriteAllText(Path.Combine(path, "result.partial"), "old");
        if (marked) File.WriteAllText(Path.Combine(path, "owner"), $"MeloNX.NSZ.v1\n{id:D}\n{Guid.NewGuid():D}");
        return path;
    }

    private sealed class DiskFullStream(string path) : Stream
    {
        private readonly FileStream _file = new(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        public override void Write(byte[] buffer, int offset, int count) => throw new IOException("Disk full", unchecked((int)0x80070070));
        public override void Write(ReadOnlySpan<byte> buffer) { _file.Write(buffer[..Math.Min(1, buffer.Length)]); throw new IOException("Disk full", unchecked((int)0x80070070)); }
        protected override void Dispose(bool disposing) { if (disposing) _file.Dispose(); base.Dispose(disposing); }
        public override bool CanWrite => true; public override bool CanRead => false; public override bool CanSeek => false;
        public override long Length => _file.Length; public override long Position { get => _file.Position; set => throw new NotSupportedException(); }
        public override void Flush() => _file.Flush(); public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long value) => throw new NotSupportedException();
    }

    private sealed class Validator(Func<string, CancellationToken, NszPackage> validate) : INszPackageValidator
    {
        public NszPackage Validate(string path, CancellationToken cancellation) => validate(path, cancellation);
    }

    internal sealed class JobFixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "melonx-nsz-tests", Guid.NewGuid().ToString("D"));
        public string SourcePath => Path.Combine(Root, "source.nsp");
        public string ExistingPath => Path.Combine(Root, "game.nsp");
        public byte[] SourceBytes { get; }
        public byte[] ExistingBytes { get; } = [9, 8, 7];
        public byte[] Expected { get; }
        public NszImportJob Job { get; private set; } = null!;
        private readonly Func<string, CancellationToken, NszPackage> _validate;
        private readonly Func<long> _available;
        private readonly ManualResetEventSlim _entered = new();
        private readonly ManualResetEventSlim _release = new();

        public JobFixture(Func<string, CancellationToken, NszPackage>? validate = null,
            Func<long>? available = null, bool createJob = true)
        {
            var fixture = NszFixtures.Build(); SourceBytes = fixture.Nsz; Expected = fixture.ExpectedNsp;
            Directory.CreateDirectory(Root); File.WriteAllBytes(SourcePath, SourceBytes); File.WriteAllBytes(ExistingPath, ExistingBytes);
            _validate = validate ?? ((_, _) => new(NszPackageKind.Application, 0x100, 0x100));
            _available = available ?? (() => long.MaxValue);
            if (createJob) CreateJob();
        }
        public void CreateJob(string outputName = "game.nsp", ImportJobHooks? hooks = null, Guid? id = null) => Job = new(
            new(id ?? Guid.NewGuid(), SourcePath, Root, outputName, NszPackageKind.Application, 0x100),
            new Validator(_validate), new(), _available, hooks ?? new());
        public static JobFixture AtValidationBarrier()
        {
            var f = new JobFixture(createJob: false);
            f.Job = new(new(Guid.NewGuid(), f.SourcePath, f.Root, "game.nsp", NszPackageKind.Application, 0x100),
                new Validator((_, _) => { f._entered.Set(); if (!f._release.Wait(10000)) throw new TimeoutException(); return new(NszPackageKind.Application, 0x100, 0x100); }), new(), f._available);
            return f;
        }
        public void WaitUntilValidation() => Assert.That(_entered.Wait(10000), Is.True, "validator barrier was not reached");
        public void ReleaseValidation() => _release.Set();
        public string[] StagingDirectories() => Directory.Exists(Path.Combine(Root, ".imports")) ? Directory.GetDirectories(Path.Combine(Root, ".imports")) : [];
        public void AssertPreserved()
        {
            Assert.That(File.ReadAllBytes(SourcePath), Is.EqualTo(SourceBytes));
            Assert.That(File.ReadAllBytes(ExistingPath), Is.EqualTo(ExistingBytes));
        }
        public void Dispose()
        {
            _release.Set(); Job?.Dispose(); _entered.Dispose(); _release.Dispose(); Directory.Delete(Root, true);
        }
    }
}
