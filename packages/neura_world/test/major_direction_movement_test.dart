import 'package:neura_world/neura_world.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  test('arbitrary destinations decompose into supported sprite directions', () {
    final start = Vector2(3.2, 4.7);
    final destination = Vector2(11.6, 7.1);
    final waypoints = majorDirectionWaypoints(start, destination);

    expect(waypoints, hasLength(2));
    var previous = start;
    for (final waypoint in waypoints) {
      expect(isMajorDirectionDelta(waypoint - previous), isTrue);
      previous = waypoint;
    }
    expect(previous.x, closeTo(destination.x, 1e-9));
    expect(previous.y, closeTo(destination.y, 1e-9));
  });

  test('already-supported directions need only the destination waypoint', () {
    final start = Vector2(2, 2);
    for (final destination in [
      Vector2(8, 2),
      Vector2(2, 8),
      Vector2(8, 8),
      Vector2(8, -4),
    ]) {
      expect(majorDirectionWaypoints(start, destination), hasLength(1));
    }
  });

  test('no movement produces no waypoint', () {
    expect(majorDirectionWaypoints(Vector2(4, 5), Vector2(4, 5)), isEmpty);
  });
}
