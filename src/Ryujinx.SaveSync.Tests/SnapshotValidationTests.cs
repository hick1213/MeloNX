using NUnit.Framework;
using Ryujinx.SaveSync;

namespace Ryujinx.SaveSync.Tests;

public class SnapshotValidationTests
{
    [Test]
    public void BothLanguagesDecodeSameHexIdAndIndexFixture()
    {
        byte[] json = File.ReadAllBytes(Path.Combine(TestContext.CurrentContext.TestDirectory, "Fixtures", "snapshot.json"));
        SaveSnapshot snapshot = SnapshotJson.DecodeSnapshot(json);
        Assert.That(snapshot.TitleID, Is.EqualTo(0x100UL));
        Assert.That(snapshot.Records.Select(r => r.Key.Kind), Is.EqualTo(new[] { SaveKind.Account, SaveKind.Device }));
        Assert.That(snapshot.Records.Select(r => r.Key.Index), Is.EqualTo(new ushort[] { 2, 0 }));
        Assert.That(snapshot.OwnerUserID, Is.EqualTo("00000000000000000000000000000001"));
        // Git/MSBuild copy files, so materialize these declared empty test directories.
        string fixtureRoot = Path.Combine(TestContext.CurrentContext.TestDirectory, "Fixtures");
        const string generation = "11111111-1111-4111-8111-111111111111";
        Directory.CreateDirectory(Path.Combine(fixtureRoot, "0000000000000100/00000000000000000000000000000001/Account/2/versions", generation, "payload/empty/sub"));
        Directory.CreateDirectory(Path.Combine(fixtureRoot, "0000000000000100/shared/Device/0/versions", generation, "payload/empty/sub"));
        SnapshotFiles.Verify(Path.Combine(TestContext.CurrentContext.TestDirectory, "Fixtures"), snapshot, CancellationToken.None);
    }
    [Test]
    public void NumericOrDuplicatePropertiesAndUnknownSchemaAreRejected()
    {
        string json = File.ReadAllText(Path.Combine(TestContext.CurrentContext.TestDirectory, "Fixtures", "snapshot.json"));
        Assert.Throws<SaveSyncException>(() => SnapshotJson.DecodeSnapshot(System.Text.Encoding.UTF8.GetBytes(json.Replace("\"schemaVersion\":1", "\"schemaVersion\":2"))));
        Assert.Throws<SaveSyncException>(() => SnapshotJson.DecodeSnapshot(System.Text.Encoding.UTF8.GetBytes(json.Replace("\"titleID\":\"0000000000000100\"", "\"titleID\":256"))));
        Assert.Throws<SaveSyncException>(() => SnapshotJson.DecodeSnapshot(System.Text.Encoding.UTF8.GetBytes(json.Replace("\"schemaVersion\":1", "\"schemaVersion\":1,\"schemaVersion\":1"))));
        Assert.Throws<SaveSyncException>(() => SnapshotJson.DecodeSnapshot(System.Text.Encoding.UTF8.GetBytes(json.Replace("\"type\":\"Account\"", "\"type\":0"))));
        Assert.Throws<SaveSyncException>(() => SnapshotJson.DecodeSnapshot(new byte[4 * 1024 * 1024 + 1]));
    }
    [Test]
    public void ImplicitDirectoryCountAlsoRespectsEntryBudget()
    {
        string[] paths = Enumerable.Range(0, 50001).Select(i => $"dir{i}/file").ToArray();
        Assert.Throws<SaveSyncException>(() => SnapshotPaths.ValidateEntries(paths, []));
    }
    [TestCase("../escape")][TestCase("/escape")][TestCase("a/../b")][TestCase("a//b")][TestCase("a\\b")]
    public void UnsafePayloadPathsAreRejected(string path) => Assert.Throws<SaveSyncException>(() => SnapshotPaths.Validate(path));
    [Test]
    public void AliasesAndFileAncestorAreRejected()
    {
        Assert.Throws<SaveSyncException>(() => SnapshotPaths.ValidateEntries(["Save", "save"], []));
        Assert.Throws<SaveSyncException>(() => SnapshotPaths.ValidateEntries(["é", "e\u0301"], []));
        Assert.Throws<SaveSyncException>(() => SnapshotPaths.ValidateEntries(["file", "file/child"], []));
    }
    [Test]
    public void RecordDigestMismatchDoesNotPassVerification()
    {
        string root = Path.Combine(Path.GetTempPath(), "save-sync-test-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            byte[] bytes = File.ReadAllBytes(Path.Combine(TestContext.CurrentContext.TestDirectory, "Fixtures", "snapshot.json"));
            SaveSnapshot snapshot = SnapshotJson.DecodeSnapshot(bytes);
            foreach (SaveRecordReference record in snapshot.Records)
            {
                string path = Path.Combine(root, record.ManifestRelativePath);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, "{}");
            }
            Assert.Throws<SaveSyncException>(() => SnapshotFiles.Verify(root, snapshot, CancellationToken.None));
        }
        finally { Directory.Delete(root, true); }
    }
}
