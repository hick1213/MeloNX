// Only native mapping/instruction-cache operations and the translator caller are
// substituted; allocation, copying, alignment and release use production code.
using System.Runtime.InteropServices;
namespace Ryujinx.Memory {
    public sealed class DualMappedJitAllocator : IDisposable {
        public static bool hasTXM => true;
        public nint RxPtr { get; private set; }
        public nint RwPtr => RxPtr;
        public DualMappedJitAllocator(ulong size) { RxPtr = Marshal.AllocHGlobal(checked((nint)size)); }
        public void Dispose() { if (RxPtr != 0) { Marshal.FreeHGlobal(RxPtr); RxPtr = 0; } }
    }
    public static class MemoryBlock { public static ulong GetPageSize() => 16384; }
    public static class JitSupportDarwin { public static void SysIcacheInvalidate(nint pointer, int size) {} }
}
namespace Ryujinx.Common { public static class BitUtils { public static int AlignUp(int value, int alignment) => checked(value + alignment - 1) & ~(alignment - 1); } }
namespace Ryujinx.Cpu.LightningJit {
    sealed class Translator {
        public readonly FunctionMap Functions = new();
        public void RegisterFunction(ulong address, TranslatedFunction function) {}
    }
    sealed class FunctionMap {
        private readonly System.Collections.Concurrent.ConcurrentDictionary<ulong, TranslatedFunction> _functions = new();
        public bool TryGetValue(ulong address, out TranslatedFunction function) => _functions.TryGetValue(address, out function!);
        public TranslatedFunction GetOrAdd(ulong address, ulong size, TranslatedFunction function) => _functions.GetOrAdd(address, function);
    }
}
