using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Common;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;
using System;

namespace Ryujinx.HLE.HOS.Services.Hid
{
    public class TouchDevice : BaseDevice
    {
        public TouchDevice(Switch device, bool active) : base(device, active) { }

        public void Update(params ReadOnlySpan<TouchPoint> points)
        {
            ref RingLifo<TouchScreenState> lifo = ref _device.Hid.SharedMemory.TouchScreen;

            ref TouchScreenState previousEntry = ref lifo.GetCurrentEntryRef();

            TouchScreenState newState = CreateState(points, previousEntry.SamplingNumber + 1, Active);
            lifo.Write(ref newState);
        }

        internal static TouchScreenState CreateState(ReadOnlySpan<TouchPoint> points, ulong samplingNumber, bool active)
        {
            TouchScreenState newState = new()
            {
                SamplingNumber = samplingNumber,
            };

            if (active)
            {
                newState.TouchesCount = Math.Min(points.Length, newState.Touches.Length);

                Span<TouchState> touchesSpan = newState.Touches.AsSpan();
                
                int pointsLength = Math.Min(points.Length, touchesSpan.Length);

                for (int i = 0; i < pointsLength; ++i)
                {
                    TouchPoint pi = points[i];
                    touchesSpan[i] = new TouchState
                    {
                        DeltaTime = newState.SamplingNumber,
                        Attribute = pi.Attribute,
                        X = pi.X,
                        Y = pi.Y,
                        FingerId = pi.FingerId ?? (uint)i,
                        DiameterX = pi.DiameterX,
                        DiameterY = pi.DiameterY,
                        RotationAngle = pi.Angle,
                    };
                }
            }

            return newState;
        }
    }
}
