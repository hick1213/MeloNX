using NUnit.Framework;
using Ryujinx.SaveSync;

namespace Ryujinx.SaveSync.Tests;

public class SaveJobLifetimeTests
{
    [Test]
    public void StopRequestCannotFreeWorkerBeforeItsRealEnd()
    {
        using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
        var request = new SaveNativeRequest(1, Guid.NewGuid(), "recover", 0, null, null, null, null, null, null);
        var job = new SaveSyncJob(request, worker => {
            entered.Set(); release.Wait(TimeSpan.FromSeconds(5));
            return new SaveNativeResult(1, request.Id, worker.StopRequested ? 1 : 0, null, null, null, [], [], null);
        });
        Task<int> run = Task.Run(job.Run); Assert.That(entered.Wait(TimeSpan.FromSeconds(5)), Is.True);
        job.RequestSafeStop(); Assert.That(job.TryFree(), Is.False); Assert.That(job.ResultJson(), Is.Null);
        release.Set(); Assert.That(run.GetAwaiter().GetResult(), Is.EqualTo(1));
        Assert.That(job.ResultJson(), Is.Not.Null); Assert.That(job.TryFree(), Is.True);
        Assert.That(job.Run(), Is.EqualTo(2));
    }
    [Test]
    public void ExceptionsAreSanitizedAndDuplicateRunIsRejected()
    {
        var request = new SaveNativeRequest(1, Guid.NewGuid(), "recover", 0, null, null, null, null, null, null);
        var job = new SaveSyncJob(request, _ => throw new IOException("private/full/path/and/secret"));
        Assert.That(job.Run(), Is.EqualTo(2)); Assert.That(job.Run(), Is.EqualTo(2));
        Assert.That(job.ResultJson(), Does.Not.Contain("private"));
        Assert.That(job.TryFree(), Is.True);
    }
    [Test]
    public void OversizedDuplicateOrUnknownRequestsCannotRun()
    {
        const string good = "{\"version\":1,\"id\":\"11111111-1111-4111-8111-111111111111\",\"operation\":\"recover\",\"titleID\":\"0000000000000000\"}";
        Assert.That(SaveNativeJson.ParseRequest(System.Text.Encoding.UTF8.GetBytes(good)).Operation, Is.EqualTo("recover"));
        Assert.Throws<SaveSyncException>(() => SaveNativeJson.ParseRequest(System.Text.Encoding.UTF8.GetBytes(good.Replace("\"version\":1", "\"version\":1,\"version\":1"))));
        Assert.Throws<SaveSyncException>(() => SaveNativeJson.ParseRequest(System.Text.Encoding.UTF8.GetBytes(good.Replace("recover", "execute"))));
        Assert.Throws<SaveSyncException>(() => SaveNativeJson.ParseRequest(new byte[65537]));
    }
}

public class SaveIntentBoundaryTests
{
    [Test]
    public void RestoreIntentMustMatchExactOwnedGenerationBeforeReading()
    {
        string root = Path.Combine(Path.GetTempPath(), "save-intent-" + Guid.NewGuid());
        Guid generation = Guid.NewGuid();
        string staging = Path.Combine(root, "staging", generation.ToString("D"));
        Directory.CreateDirectory(staging);
        try
        {
            var intent = new BindingIntent(Guid.NewGuid(), "iCloud.test", 0x100, new string('a', 32), new string('b', 32), generation);
            string file = Path.Combine(staging, "binding-intent.json");
            File.WriteAllBytes(file, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(intent, SaveJsonContext.Default.BindingIntent));
            var request = new SaveNativeRequest(1, Guid.NewGuid(), "restore", 0, null, Guid.NewGuid(), staging, file, null, null);
            Assert.That(SaveNativePaths.ReadRestoreIntent(request, root), Is.EqualTo(intent));
            // A nonexistent out-of-scope file must be rejected before an I/O read.
            Assert.Throws<SaveSyncException>(() => SaveNativePaths.ReadRestoreIntent(request with { BindingIntentFile = Path.Combine(root, "private.json") }, root));
            Assert.Throws<SaveSyncException>(() => SaveNativePaths.ReadRestoreIntent(request with { SnapshotRoot = Path.Combine(root, "staging", generation + "-suffix") }, root));
            File.WriteAllBytes(file, new byte[65537]);
            Assert.Throws<SaveSyncException>(() => SaveNativePaths.ReadRestoreIntent(request, root));
        }
        finally { Directory.Delete(root, true); }
    }
}
