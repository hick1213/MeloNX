using System;
using System.Threading;
namespace Ryujinx.Cpu.LightningJit
{
    // Dispose can be requested from a guest SVC while generated code is still
    // on that thread's stack. Reclaim only after every Execute has returned.
    sealed class TranslatorExecutionLifetime
    {
        private readonly Lock _lock = new();
        private int _active;
        private bool _disposeRequested;
        private bool _released;

        public bool TryEnter()
        {
            lock (_lock)
            {
                if (_disposeRequested) return false;
                _active++;
                return true;
            }
        }

        public void Exit(Action release)
        {
            bool reclaim;
            lock (_lock)
            {
                if (_active == 0) throw new InvalidOperationException("No active translator execution.");
                _active--;
                reclaim = TakeRelease();
            }
            if (reclaim) release();
        }

        public void RequestDispose(Action release)
        {
            bool reclaim;
            lock (_lock)
            {
                _disposeRequested = true;
                reclaim = TakeRelease();
            }
            if (reclaim) release();
        }

        public void WhileAlive(Action action)
        {
            lock (_lock)
            {
                if (!_disposeRequested) action();
            }
        }

        public static void DisposeResources(Action stubs, Action table, Action code)
        {
            try { stubs(); }
            finally
            {
                try { table(); }
                finally { code(); }
            }
        }

        private bool TakeRelease()
        {
            if (!_disposeRequested || _active != 0 || _released) return false;
            _released = true;
            return true;
        }
    }
}
