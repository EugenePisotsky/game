import 'dart:math' as math;

import 'package:neura_world/neura_world.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  test('shortest turn includes intermediate facing rows', () {
    expect(
      shortestDirectionTurn(
        EnvironmentDirection.north,
        EnvironmentDirection.east,
      ),
      [EnvironmentDirection.northEast, EnvironmentDirection.east],
    );
    expect(
      shortestDirectionTurn(
        EnvironmentDirection.north,
        EnvironmentDirection.south,
      ),
      [
        EnvironmentDirection.northEast,
        EnvironmentDirection.east,
        EnvironmentDirection.southEast,
        EnvironmentDirection.south,
      ],
    );
    expect(
      shortestDirectionTurn(
        EnvironmentDirection.north,
        EnvironmentDirection.west,
      ),
      [EnvironmentDirection.northWest, EnvironmentDirection.west],
    );
  });

  test('off-angle destination becomes two animated direction legs', () {
    final waypoints = directionAlignedWaypoints(
      Vector2.zero(),
      [Vector2(3, 1)],
      initialFacing: EnvironmentDirection.north,
      maxLineDeviation: double.infinity,
    );

    expect(waypoints, hasLength(2));
    expect(waypoints.first.x, closeTo(1, 1e-9));
    expect(waypoints.first.y, closeTo(1, 1e-9));
    expect(waypoints.last.x, closeTo(3, 1e-9));
    expect(waypoints.last.y, closeTo(1, 1e-9));
    var cursor = Vector2.zero();
    for (final waypoint in waypoints) {
      expect(isDirectionAlignedDelta(waypoint - cursor), isTrue);
      cursor = waypoint;
    }
  });

  test('current facing selects the dogleg with fewer turns', () {
    final waypoints = directionAlignedWaypoints(
      Vector2.zero(),
      [Vector2(3, 1)],
      initialFacing: EnvironmentDirection.southEast,
      maxLineDeviation: double.infinity,
    );

    expect(waypoints.first.x, closeTo(2, 1e-9));
    expect(waypoints.first.y, closeTo(0, 1e-9));
    expect(
      directionForWorldDelta(waypoints.first),
      EnvironmentDirection.southEast,
    );
  });

  test('same-direction legs are merged across route boundaries', () {
    final waypoints = directionAlignedWaypoints(Vector2.zero(), [
      Vector2(1, 0),
      Vector2(3, 0),
      Vector2(4, 1),
    ], initialFacing: EnvironmentDirection.southEast);

    expect(waypoints, hasLength(2));
    expect(waypoints.first.x, closeTo(3, 1e-9));
    expect(waypoints.first.y, closeTo(0, 1e-9));
    expect(waypoints.last.x, closeTo(4, 1e-9));
    expect(waypoints.last.y, closeTo(1, 1e-9));
  });

  test('collision check rejects a blocked dogleg order', () {
    final waypoints = directionAlignedWaypoints(
      Vector2.zero(),
      [Vector2(3, 1)],
      initialFacing: EnvironmentDirection.north,
      isWalkable: (start, end) => !(end.x == 1 && end.y == 1),
      maxLineDeviation: double.infinity,
    );

    expect(waypoints.first.x, closeTo(2, 1e-9));
    expect(waypoints.first.y, closeTo(0, 1e-9));
  });

  test('long off-angle route stays inside a bounded line corridor', () {
    final start = Vector2.zero();
    final destination = Vector2(10, 3);
    final waypoints = directionAlignedWaypoints(
      start,
      [destination],
      initialFacing: EnvironmentDirection.north,
      maxLineDeviation: 0.35,
    );

    expect(waypoints.length, greaterThan(2));
    expect(waypoints.last.x, closeTo(destination.x, 1e-9));
    expect(waypoints.last.y, closeTo(destination.y, 1e-9));
    var cursor = start;
    for (final waypoint in waypoints) {
      expect(isDirectionAlignedDelta(waypoint - cursor), isTrue);
      expect(
        _lineDistance(waypoint, start, destination),
        lessThanOrEqualTo(0.35 + 1e-9),
      );
      cursor = waypoint;
    }
  });

  test('gameplay corridor favors longer runs over a tight staircase', () {
    List<Vector2> route({double? deviation}) {
      if (deviation == null) {
        return directionAlignedWaypoints(Vector2.zero(), [
          Vector2(10, 3),
        ], initialFacing: EnvironmentDirection.north);
      }
      return directionAlignedWaypoints(
        Vector2.zero(),
        [Vector2(10, 3)],
        initialFacing: EnvironmentDirection.north,
        maxLineDeviation: deviation,
      );
    }

    final gameplayRoute = route();
    final tightRoute = route(deviation: 0.35);

    expect(gameplayRoute.length, lessThan(tightRoute.length));
    expect(gameplayRoute.length, lessThanOrEqualTo(4));
  });

  test('seeded cadence variation avoids mechanically equal turn intervals', () {
    List<Vector2> routeForSeed(int seed) => directionAlignedWaypoints(
      Vector2.zero(),
      [Vector2(12, 4)],
      initialFacing: EnvironmentDirection.north,
      maxLineDeviation: 0.3,
      turnRandom: math.Random(seed),
    );

    final first = routeForSeed(7);
    final repeated = routeForSeed(7);
    final different = routeForSeed(8);

    expect(first, hasLength(repeated.length));
    for (var index = 0; index < first.length; index++) {
      expect(first[index].x, closeTo(repeated[index].x, 1e-9));
      expect(first[index].y, closeTo(repeated[index].y, 1e-9));
    }
    expect(
      different.length != first.length ||
          List.generate(
            math.min(first.length, different.length),
            (index) => (first[index] - different[index]).length,
          ).any((distance) => distance > 1e-6),
      isTrue,
    );

    final lengths = <double>[];
    var cursor = Vector2.zero();
    for (final waypoint in first) {
      lengths.add((waypoint - cursor).length);
      cursor = waypoint;
    }
    expect(
      lengths.map((length) => length.toStringAsFixed(3)).toSet().length,
      greaterThan(2),
    );
  });
}

double _lineDistance(Vector2 point, Vector2 start, Vector2 end) {
  final route = end - start;
  final fromStart = point - start;
  return (route.x * fromStart.y - route.y * fromStart.x).abs() / route.length;
}
