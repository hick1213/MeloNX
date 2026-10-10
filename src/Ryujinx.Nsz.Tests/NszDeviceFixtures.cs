using System.Security.Cryptography;
using System.Text.Json;
using NUnit.Framework;

namespace Ryujinx.Nsz.Tests;

public class NszDeviceFixtures
{
    [Test, Explicit("Exports generated public vectors only when a task-local directory is explicitly supplied.")]
    public void ExportDeviceFixtures()
    {
        string? root = Environment.GetEnvironmentVariable("MELONX_NSZ_FIXTURES");
        Assert.That(root, Is.Not.Null.And.Not.Empty);
        Assert.That(Path.IsPathFullyQualified(root!), Is.True);
        Assert.That(Path.GetFullPath(root!).StartsWith("/Volumes/untitled/github/MeloNX/.local/", StringComparison.Ordinal), Is.True);
        Directory.CreateDirectory(root!);
        var records = new List<object>();
        foreach (var blocked in new[] { false, true })
        {
            string name = blocked ? "block" : "solid";
            var fixture = NszFixtures.Build(firstOffset: blocked ? 0x6000 : 0x2000, blocked: blocked, rawLastBlock: true, exactMultiple: true);
            using (var file = new FileStream(Path.Combine(root!, name + ".nsz"), FileMode.CreateNew)) file.Write(fixture.Nsz);
            records.Add(new { source = name + ".nsz", output = name + ".nsp", sha256 = Convert.ToHexString(SHA256.HashData(fixture.ExpectedNsp)).ToLowerInvariant() });
        }
        string json = JsonSerializer.Serialize(new { version = 1, fixtures = records }, new JsonSerializerOptions { WriteIndented = true });
        using var manifest = new FileStream(Path.Combine(root!, "manifest.json"), FileMode.CreateNew);
        manifest.Write(System.Text.Encoding.UTF8.GetBytes(json));
        Assert.That(records.Count, Is.EqualTo(2));
    }
}
