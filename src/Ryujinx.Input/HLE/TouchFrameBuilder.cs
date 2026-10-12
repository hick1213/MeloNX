using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Numerics;

namespace Ryujinx.Input.HLE
{
    // Tracks contacts by identity, including end events, rather than by compacted
    // array position. New contacts are deferred when end events fill the packet.
    class TouchFrameBuilder
    {
        private const int MaxContacts = 16;
        private readonly Dictionary<int, Vector2> _previous = new();

        public TouchPoint[] Build(IReadOnlyList<KeyValuePair<int, Vector2>> samples, Size size)
        {
            var current = samples.Where(sample => sample.Key >= 0).GroupBy(sample => sample.Key)
                .Select(group => group.Last()).Take(MaxContacts).ToDictionary(sample => sample.Key, sample => sample.Value);
            var points = new List<TouchPoint>(MaxContacts);
            foreach (int id in _previous.Keys.Where(id => !current.ContainsKey(id)).ToArray())
            {
                points.Add(Point(id, _previous[id], TouchAttribute.End));
                _previous.Remove(id);
            }
            foreach (var sample in current.OrderByDescending(sample => _previous.ContainsKey(sample.Key)))
            {
                if (points.Count == MaxContacts) break;
                var position = ITouchScreen.GetTouchPosition(sample.Value, size);
                var attribute = _previous.ContainsKey(sample.Key) ? TouchAttribute.None : TouchAttribute.Start;
                points.Add(Point(sample.Key, position, attribute));
                _previous[sample.Key] = position;
            }
            return points.ToArray();
        }

        private static TouchPoint Point(int id, Vector2 position, TouchAttribute attribute) => new()
        {
            FingerId = (uint)id, Attribute = attribute, X = (uint)position.X, Y = (uint)position.Y,
            DiameterX = 10, DiameterY = 10, Angle = 90,
        };
    }
}
