using System.Reflection;
using System.Runtime.CompilerServices;
using NUnit.Framework;
using Ryujinx.Cpu;
namespace Ryujinx.SaveSync.Tests;
public class TranslatorStubDisposalTests {
    [TestCase("_noWxCache")] [TestCase("_dualMappedNoWxCache")]
    public void CacheOwnedStubsAreNotUnmappedThroughTheGlobalJitCache(string cacheField) {
        var type = typeof(ICpuContext).Assembly.GetType("Ryujinx.Cpu.LightningJit.TranslatorStubs")!;
        var stubs = RuntimeHelpers.GetUninitializedObject(type);
        var field = type.GetField(cacheField, BindingFlags.NonPublic | BindingFlags.Instance)!;
        // No generated code is executed; cache presence controls the real
        // production disposal path. Its mapping is owned by that cache.
        field.SetValue(stubs, RuntimeHelpers.GetUninitializedObject(field.FieldType));
        Assert.DoesNotThrow(() => ((IDisposable)stubs).Dispose());
    }
}
