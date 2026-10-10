using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Spl;
using NUnit.Framework;
using Ryujinx.Library.Compression;

namespace Ryujinx.Nsz.Tests;

[TestFixture]
public class NszValidatorOwnershipTests
{
    [Test]
    public void SnapshotOwnsBothKeyStructAndExternalTitleKeys()
    {
        var source = new KeySet(); source.HeaderKey.Data.Fill(1);
        source.ExternalKeySet.Add(new RightsId(new byte[16]), new AccessKey(Enumerable.Repeat((byte)2, 16).ToArray())).ThrowIfFailure();
        var snapshot = NszPackageValidator.Snapshot(source);
        using (var validator = new NszPackageValidator(snapshot))
        {
            source.HeaderKey.Data.Fill(3); source.ExternalKeySet.Clear();
            Assert.That(snapshot.HeaderKey.Data[0], Is.EqualTo(1));
            Assert.That(snapshot.ExternalKeySet.ToList().Count, Is.EqualTo(1));
        }
        Assert.That(source.HeaderKey.Data[0], Is.EqualTo(3));
        Assert.That(snapshot.HeaderKey.IsZeros(), Is.True);
        Assert.That(snapshot.ExternalKeySet.ToList(), Is.Empty);
    }
    [Test]
    public void EmptyHeaderKeysProduceStructuredMissingKeyAndPreserveInput()
    {
        using var f = new NszImportJobTests.JobFixture();
        using var validator = new NszPackageValidator(new KeySet());
        var error = Assert.Throws<NszImportException>(() => validator.Validate(f.SourcePath, default));
        Assert.That(error!.Code, Is.EqualTo(NszImportError.MissingKey)); f.AssertPreserved();
    }
    [Test]
    public void MissingTitleKeyIsDistinctFromMalformedContentAtNativeBoundary()
    {
        using var f = new NszImportJobTests.JobFixture(validate: (_, _) => throw new NszImportException(NszImportError.MissingKey, "private title key information"));
        using var session = new NszImportSession(f.Job);
        Assert.That(session.Run(), Is.EqualTo(2));
        Assert.That(session.ResultJson(), Does.Contain("missing_key").And.Not.Contain("private")); f.AssertPreserved();
    }
}
