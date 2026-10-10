using System.Runtime.InteropServices;
using NUnit.Framework;

namespace Ryujinx.Nsz.Tests;

[TestFixture]
public class NszNativeLifetimeTests
{
    [Test]
    public void LayoutIsExactlyFortyEightBytesWithUInt64Ids()
    {
        Assert.That(Marshal.SizeOf<NszNativeProgress>(), Is.EqualTo(48));
        Assert.That(Marshal.OffsetOf<NszNativeProgress>(nameof(NszNativeProgress.ApplicationId)).ToInt32(), Is.EqualTo(32));
    }
    [Test]
    public void ResultUnavailableBeforeRunAndRunIsOwnedOnce()
    {
        using var f = new NszImportJobTests.JobFixture(); using var session = new NszImportSession(f.Job);
        Assert.That(session.ResultJson(), Is.Null);
        Assert.That(session.Run(), Is.Zero);
        Assert.That(session.ResultJson(), Does.Contain("0000000000000100"));
        Assert.That(session.Run(), Is.EqualTo(2));
        f.AssertPreserved();
    }
    [Test]
    public void FreeActiveSessionIsRejectedAndCancelCanBePolled()
    {
        using var f = NszImportJobTests.JobFixture.AtValidationBarrier(); using var session = new NszImportSession(f.Job);
        var run = Task.Run(session.Run); f.WaitUntilValidation();
        Assert.That(session.Progress().Phase, Is.EqualTo(2));
        Assert.That(session.ResultJson(), Is.Null);
        Assert.Throws<InvalidOperationException>(() => session.Dispose());
        session.Cancel(); f.ReleaseValidation(); Assert.That(run.GetAwaiter().GetResult(), Is.EqualTo(1));
        Assert.That(session.Progress().Phase, Is.EqualTo(6));
        Assert.That(session.ResultJson(), Does.Contain("cancelled")); f.AssertPreserved();
    }
    [Test]
    public void ErrorsAreSanitizedAndKeepCommittedPathWhenCancelledLate()
    {
        using var f = new NszImportJobTests.JobFixture(validate: (_, _) => throw new InvalidDataException("secret /private/keys"));
        using var session = new NszImportSession(f.Job);
        Assert.That(session.Run(), Is.EqualTo(2));
        Assert.That(session.ResultJson(), Does.Contain("invalid_package"));
        Assert.That(session.ResultJson(), Does.Not.Contain("secret").And.Not.Contain("/private"));
    }
    [Test]
    public void Utf8ResultAllocationIsOwnedAndFreeIsIdempotent()
    {
        nint ptr = NszUtf8Buffers.Allocate("测试 NSZ");
        Assert.That(Marshal.PtrToStringUTF8(ptr), Is.EqualTo("测试 NSZ"));
        Assert.That(NszUtf8Buffers.Owns(ptr), Is.True);
        NszUtf8Buffers.Free(ptr); NszUtf8Buffers.Free(ptr);
        Assert.That(NszUtf8Buffers.Owns(ptr), Is.False);
        Assert.Throws<ArgumentException>(() => NszUtf8Buffers.Allocate(new string('a', 65537)));
    }
    [Test]
    public void RequestsHaveBoundedVersionedJsonAndExactTitleIds()
    {
        string id = Guid.NewGuid().ToString("D");
        string json = "{\"version\":1,\"id\":\"" + id + "\",\"source\":\"/source.nsz\",\"targetRoot\":\"/roms\",\"outputName\":\"game.nsp\",\"kind\":0,\"applicationId\":\"fedcba9876543210\"}";
        var request = NszRequestJson.Parse(json);
        Assert.That(request.ExpectedApplicationId, Is.EqualTo(0xfedcba9876543210UL));
        Assert.Throws<ArgumentException>(() => NszRequestJson.Parse(json.Replace("\"version\":1", "\"version\":2")));
        Assert.Throws<ArgumentException>(() => NszRequestJson.Parse(json.Replace("\"fedcba9876543210\"", "1.23")));
        Assert.Throws<ArgumentException>(() => NszRequestJson.Parse(json.Replace("\"version\":1", "\"version\":1,\"version\":1")));
        Assert.Throws<ArgumentException>(() => NszRequestJson.Parse(new string('a', 65537)));
    }
}
