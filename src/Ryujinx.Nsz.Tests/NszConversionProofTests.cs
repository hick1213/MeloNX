using NUnit.Framework;
using Ryujinx.Library.Compression;
using System.Security.Cryptography;

namespace Ryujinx.Nsz.Tests;

public class NszConversionProofTests
{
    [Test]
    public void DiagnosticOnlyConversionHasExactHashAndOwnedFailureChecks()
    {
        string root = Path.Combine(Path.GetTempPath(), "NSZProof-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            var fixture = NszFixtures.Build(blocked: true, rawLastBlock: true, exactMultiple: true);
            string source = Path.Combine(root, "source.nsz"), output = Path.Combine(root, "result.nsp");
            File.WriteAllBytes(source, fixture.Nsz);
            var proof = NszConversionDiagnostic.RunProof(source, output);
            Assert.That(proof.Sha256, Is.EqualTo(Convert.ToHexString(SHA256.HashData(fixture.ExpectedNsp)).ToLowerInvariant()));
            Assert.That(proof.CancellationVerified && proof.SpaceFailureVerified, Is.True);
            Assert.That(File.ReadAllBytes(source), Is.EqualTo(fixture.Nsz));
            Assert.That(File.ReadAllBytes(output), Is.EqualTo(fixture.ExpectedNsp));
            Assert.Throws<IOException>(() => NszConversionDiagnostic.RunProof(source, output));
        }
        finally { Directory.Delete(root, true); }
    }
}
