using System.Drawing;
using System.Numerics;
using NUnit.Framework;
using Ryujinx.Input.HLE;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;
namespace Ryujinx.SaveSync.Tests;
public class TouchFrameTests {
    [Test] public void ReleasedFirstFingerDoesNotRenameTheRemainingFinger() {
        var frames = new TouchFrameBuilder();
        _ = frames.Build([new(0, new(10, 20)), new(1, new(30, 40))], new Size(1280, 720));
        var next = frames.Build([new(1, new(35, 45))], new Size(1280, 720));
        Assert.That(next.Single(p => p.FingerId == 0).Attribute, Is.EqualTo(TouchAttribute.End));
        var held = next.Single(p => p.FingerId == 1);
        Assert.That(held.Attribute, Is.EqualTo(TouchAttribute.None)); Assert.That(held.X, Is.EqualTo(35));
        var last = frames.Build([], new Size(1280, 720));
        Assert.That(last.Length, Is.EqualTo(1)); Assert.That(last[0].FingerId, Is.EqualTo(1)); Assert.That(last[0].Attribute, Is.EqualTo(TouchAttribute.End));
    }
    [Test] public void ManyEndAndStartEventsCannotOverflowTheSixteenContactHidPacket() {
        var frames = new TouchFrameBuilder();
        _ = frames.Build(Enumerable.Range(0, 16).Select(i => new KeyValuePair<int, Vector2>(i, new(10, 20))).ToArray(), new Size(1280, 720));
        var incoming = Enumerable.Range(16, 16).Select(i => new KeyValuePair<int, Vector2>(i, new(30, 40))).ToArray();
        var ends = frames.Build(incoming, new Size(1280, 720));
        Assert.That(ends.Length, Is.EqualTo(16)); Assert.That(ends.All(p => p.Attribute == TouchAttribute.End), Is.True);
        var starts = frames.Build(incoming, new Size(1280, 720));
        Assert.That(starts.Length, Is.EqualTo(16)); Assert.That(starts.All(p => p.Attribute == TouchAttribute.Start), Is.True);
    }
}
