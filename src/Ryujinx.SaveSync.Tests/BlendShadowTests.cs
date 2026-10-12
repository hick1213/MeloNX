using System.Reflection;
using System.Runtime.InteropServices;
using NUnit.Framework;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Engine;
using Ryujinx.Graphics.Gpu.Engine.Threed;
using Ryujinx.Graphics.Gpu.Engine.Types;

namespace Ryujinx.SaveSync.Tests;

public class BlendShadowTests
{
    [TestCase(0, false)]
    [TestCase(1, false)]
    [TestCase(0, true)]
    [TestCase(1, true)]
    public void BulkBlendRecordsAndReplaysLikeRegisterWrites(int modeValue, bool redundant)
    {
        var mode = (SetMmeShadowRamControlMode)modeValue;
        using var context = new GpuContext(new BufferCacheBindingTests.BufferRenderer(), default);
        var engine = new ThreedClass(context, null!, null!);
        var state = (DeviceStateWithShadow<ThreedClassState>)typeof(ThreedClass).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(engine)!;
        var oracle = new DeviceStateWithShadow<ThreedClassState>();
        int offset = Marshal.OffsetOf<ThreedClassState>(nameof(ThreedClassState.BlendEnable)).ToInt32();
        Boolean32[] a = Enumerable.Range(0, 8).Select(i => new Boolean32(i % 2 == 0 ? 1u : 0u)).ToArray();
        Boolean32[] b = Enumerable.Range(0, 8).Select(i => new Boolean32(i % 2 != 0 ? 1u : 0u)).ToArray();
        if (redundant) a.AsSpan().CopyTo(state.State.BlendEnable.AsSpan());
        state.State.SetMmeShadowRamControl = (uint)mode;
        oracle.State.SetMmeShadowRamControl = (uint)mode;
        engine.UpdateBlendEnable(a);
        for (int i = 0; i < 8; i++) oracle.Write(offset + i * 4, i % 2 == 0 ? 1 : 0);
        Assert.That(state.ShadowState.BlendEnable.AsSpan().ToArray(), Is.EqualTo(oracle.ShadowState.BlendEnable.AsSpan().ToArray()));
        state.State.SetMmeShadowRamControl = (uint)SetMmeShadowRamControlMode.MethodPassthrough;
        engine.UpdateBlendEnable(b);
        state.State.SetMmeShadowRamControl = (uint)SetMmeShadowRamControlMode.MethodReplay;
        var tracker = Tracker(engine);
        ClearDirty(tracker);
        engine.UpdateBlendEnable(b);
        Assert.That(b, Is.EqualTo(a));
        Assert.That(state.State.BlendEnable.AsSpan().ToArray(), Is.EqualTo(a));
        Assert.That(tracker.IsDirty(StateUpdater.BlendStateIndex), Is.True);
        ClearDirty(tracker);
        engine.UpdateBlendEnable(b);
        Assert.That(tracker.IsDirty(StateUpdater.BlendStateIndex), Is.False);
    }

    [TestCase(0)]
    [TestCase(1)]
    public void BulkColorMasksRecordAndReplaySavedChannels(int modeValue)
    {
        var mode = (SetMmeShadowRamControlMode)modeValue;
        using var context = new GpuContext(new BufferCacheBindingTests.BufferRenderer(), default);
        var engine = new ThreedClass(context, null!, null!);
        var state = (DeviceStateWithShadow<ThreedClassState>)typeof(ThreedClass).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(engine)!;
        var oracle = new DeviceStateWithShadow<ThreedClassState>();
        int offset = Marshal.OffsetOf<ThreedClassState>(nameof(ThreedClassState.RtColorMask)).ToInt32();
        RtColorMask[] a = Enumerable.Range(0, 8).Select(i => new RtColorMask((uint)i + 1)).ToArray();
        RtColorMask[] b = Enumerable.Repeat(new RtColorMask(15), 8).ToArray();
        state.State.SetMmeShadowRamControl = (uint)mode;
        oracle.State.SetMmeShadowRamControl = (uint)mode;
        engine.UpdateColorMasks(a);
        for (int i = 0; i < 8; i++) oracle.Write(offset + i * 4, (int)a[i].Packed);
        Assert.That(state.ShadowState.RtColorMask.AsSpan().ToArray(), Is.EqualTo(oracle.ShadowState.RtColorMask.AsSpan().ToArray()));
        state.State.SetMmeShadowRamControl = (uint)SetMmeShadowRamControlMode.MethodPassthrough;
        engine.UpdateColorMasks(b);
        state.State.SetMmeShadowRamControl = (uint)SetMmeShadowRamControlMode.MethodReplay;
        engine.UpdateColorMasks(b);
        Assert.That(b, Is.EqualTo(a));
        Assert.That(state.State.RtColorMask.AsSpan().ToArray(), Is.EqualTo(a));
    }

    private static StateUpdateTracker<ThreedClassState> Tracker(ThreedClass engine)
    {
        var updater = typeof(ThreedClass).GetField("_stateUpdater", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(engine)!;
        return (StateUpdateTracker<ThreedClassState>)typeof(StateUpdater).GetField("_updateTracker", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(updater)!;
    }

    private static void ClearDirty(StateUpdateTracker<ThreedClassState> tracker) =>
        typeof(StateUpdateTracker<ThreedClassState>).GetField("_dirtyMask", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(tracker, 0UL);
}
