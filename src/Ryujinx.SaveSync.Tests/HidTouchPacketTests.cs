using NUnit.Framework;
using Ryujinx.HLE.HOS.Services.Hid;
namespace Ryujinx.SaveSync.Tests;
public class HidTouchPacketTests {
    [Test] public void PacketPreservesFingerIdentityRatherThanArrayIndex() {
        var state = TouchDevice.CreateState([new TouchPoint { FingerId = 17, X = 35, Y = 45 }], 1, true);
        Assert.That(state.Touches.AsSpan()[0].FingerId, Is.EqualTo(17));
    }
    [Test] public void PacketCountCannotExceedItsPhysicalSixteenEntryArray() {
        var points = Enumerable.Range(0, 20).Select(i => new TouchPoint { FingerId = (uint)i }).ToArray();
        var state = TouchDevice.CreateState(points, 1, true);
        Assert.That(state.TouchesCount, Is.EqualTo(16));
    }
    [Test] public void LegacyMouseUsesArrayIndexWhenNoIdentityWasProvided() {
        var state = TouchDevice.CreateState([new TouchPoint(), new TouchPoint()], 1, true);
        Assert.That(state.Touches.AsSpan()[1].FingerId, Is.EqualTo(1));
    }
}
