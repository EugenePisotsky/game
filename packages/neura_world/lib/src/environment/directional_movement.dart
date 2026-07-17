import 'dart:math' as math;

import 'package:vector_math/vector_math.dart';

import 'environment_document.dart';
import '../world/isometric_projection.dart';

typedef DirectionSegmentWalkable = bool Function(Vector2 start, Vector2 end);

const _clockwiseDirections = [
  EnvironmentDirection.south,
  EnvironmentDirection.southWest,
  EnvironmentDirection.west,
  EnvironmentDirection.northWest,
  EnvironmentDirection.north,
  EnvironmentDirection.northEast,
  EnvironmentDirection.east,
  EnvironmentDirection.southEast,
];

/// Facing rows encountered along the shortest rotation from [from] to [to],
/// excluding [from] and including [to]. A 180-degree tie turns clockwise.
List<EnvironmentDirection> shortestDirectionTurn(
  EnvironmentDirection from,
  EnvironmentDirection to,
) {
  if (from == to) return const [];
  final fromIndex = _clockwiseDirections.indexOf(from);
  final toIndex = _clockwiseDirections.indexOf(to);
  final clockwiseSteps = (toIndex - fromIndex + 8) % 8;
  final counterClockwiseSteps = 8 - clockwiseSteps;
  final step = clockwiseSteps <= counterClockwiseSteps ? 1 : -1;
  final count = math.min(clockwiseSteps, counterClockwiseSteps);
  return [
    for (var offset = 1; offset <= count; offset++)
      _clockwiseDirections[(fromIndex + step * offset + 8) % 8],
  ];
}

/// Converts a world-space movement vector to the documented Other Worlds
/// character direction that exactly matches it.
///
/// Callers should pass an axis-aligned or 45-degree world-space vector. Those
/// eight vectors become the eight isometric screen directions.
EnvironmentDirection directionForWorldDelta(Vector2 delta) {
  final screen = const IsometricProjection().worldToScreen(delta);
  final sector =
      ((math.atan2(screen.y, screen.x) / (math.pi / 4)).round() + 8) % 8;
  return const [
    EnvironmentDirection.east,
    EnvironmentDirection.southEast,
    EnvironmentDirection.south,
    EnvironmentDirection.southWest,
    EnvironmentDirection.west,
    EnvironmentDirection.northWest,
    EnvironmentDirection.north,
    EnvironmentDirection.northEast,
  ][sector];
}

/// Whether [delta] can be animated without the character visually sliding.
bool isDirectionAlignedDelta(Vector2 delta, {double epsilon = 1e-7}) {
  final x = delta.x.abs();
  final y = delta.y.abs();
  return x <= epsilon || y <= epsilon || (x - y).abs() <= epsilon;
}

/// Turns a smooth navigation route into physical legs matching the eight
/// authored character directions.
///
/// Each arbitrary segment needs at most one diagonal and one axial leg. Their
/// order is chosen to minimize changes from [initialFacing]. Ties put the
/// shorter correction first, avoiding a tiny last-second turn at the target.
/// Adjacent legs with the same direction are merged across route boundaries.
///
/// If a dogleg would cross an obstacle, [isWalkable] causes the smooth segment
/// to be subdivided until a collision-safe direction-aligned approximation is
/// found. [maxLineDeviation] also subdivides long doglegs into a digital-line
/// pattern, balancing visual turns against distance from the ideal route. When
/// [turnRandom] is provided, [turnCadenceVariation] keeps those subdivisions
/// from landing at mechanically equal intervals.
List<Vector2> directionAlignedWaypoints(
  Vector2 start,
  Iterable<Vector2> destinations, {
  required EnvironmentDirection initialFacing,
  DirectionSegmentWalkable? isWalkable,
  double maxLineDeviation = 1.1,
  math.Random? turnRandom,
  double turnCadenceVariation = 0.12,
}) {
  assert(maxLineDeviation >= 0);
  assert(turnCadenceVariation >= 0 && turnCadenceVariation < 0.5);
  final result = <Vector2>[];
  var cursor = start.clone();
  var facing = initialFacing;

  void append(Vector2 endpoint) {
    final delta = endpoint - cursor;
    if (delta.length2 <= 1e-12) return;
    final direction = directionForWorldDelta(delta);
    if (result.isNotEmpty) {
      final previousStart = result.length == 1
          ? start
          : result[result.length - 2];
      final previousDirection = directionForWorldDelta(
        result.last - previousStart,
      );
      if (previousDirection == direction) {
        result[result.length - 1] = endpoint.clone();
        cursor = endpoint.clone();
        facing = direction;
        return;
      }
    }
    result.add(endpoint.clone());
    cursor = endpoint.clone();
    facing = direction;
  }

  bool planSegment(Vector2 destination, [int depth = 0]) {
    final delta = destination - cursor;
    if (delta.length2 <= 1e-12) return true;
    if (isDirectionAlignedDelta(delta)) {
      if (isWalkable == null || isWalkable(cursor, destination)) {
        append(destination);
        return true;
      }
    }

    if (depth < 12 &&
        _doglegLineDeviation(cursor, destination) > maxLineDeviation) {
      final splitRatio = turnRandom == null
          ? 0.5
          : 0.5 + (turnRandom.nextDouble() * 2 - 1) * turnCadenceVariation;
      final split = cursor + delta * splitRatio;
      return planSegment(split, depth + 1) &&
          planSegment(destination, depth + 1);
    }

    final options = _doglegOptions(cursor, destination)
        .where(
          (option) =>
              isWalkable == null ||
              _optionIsWalkable(cursor, option, isWalkable),
        )
        .toList();
    if (options.isNotEmpty) {
      options.sort((a, b) => _compareOptions(a, b, cursor, facing));
      for (final endpoint in options.first) {
        append(endpoint);
      }
      return true;
    }

    // A narrow clear corridor can reject both full-size doglegs even though
    // the smoothed segment itself is valid. Smaller doglegs hug that segment.
    if (depth < 12) {
      final midpoint = (cursor + destination) / 2;
      return planSegment(midpoint, depth + 1) &&
          planSegment(destination, depth + 1);
    }
    return false;
  }

  for (final destination in destinations) {
    if (!planSegment(destination)) return const [];
  }
  return result;
}

double _doglegLineDeviation(Vector2 start, Vector2 end) {
  final route = end - start;
  final routeLength = route.length;
  if (routeLength <= 1e-12) return 0;
  var best = double.infinity;
  for (final option in _doglegOptions(start, end)) {
    var maximum = 0.0;
    for (final point in option.take(option.length - 1)) {
      final fromStart = point - start;
      final cross = (route.x * fromStart.y - route.y * fromStart.x).abs();
      maximum = math.max(maximum, cross / routeLength);
    }
    best = math.min(best, maximum);
  }
  return best;
}

List<List<Vector2>> _doglegOptions(Vector2 start, Vector2 end) {
  final delta = end - start;
  final diagonalDistance = math.min(delta.x.abs(), delta.y.abs());
  if (diagonalDistance <= 1e-12 ||
      (delta.x.abs() - delta.y.abs()).abs() <= 1e-12) {
    return [
      [end.clone()],
    ];
  }

  final diagonal = Vector2(
    delta.x.sign * diagonalDistance,
    delta.y.sign * diagonalDistance,
  );
  final axial = delta - diagonal;
  return [
    [start + diagonal, end.clone()],
    [start + axial, end.clone()],
  ];
}

bool _optionIsWalkable(
  Vector2 start,
  List<Vector2> option,
  DirectionSegmentWalkable isWalkable,
) {
  var cursor = start;
  for (final endpoint in option) {
    if (!isWalkable(cursor, endpoint)) return false;
    cursor = endpoint;
  }
  return true;
}

int _compareOptions(
  List<Vector2> a,
  List<Vector2> b,
  Vector2 start,
  EnvironmentDirection initialFacing,
) {
  final aTurns = _turnCount(a, start, initialFacing);
  final bTurns = _turnCount(b, start, initialFacing);
  if (aTurns != bTurns) return aTurns.compareTo(bTurns);

  // With equal turn counts, make the small corrective leg first and settle
  // into the longer direction for the remainder of the movement.
  final aFirstLength = _projectedLength(a.first - start);
  final bFirstLength = _projectedLength(b.first - start);
  return aFirstLength.compareTo(bFirstLength);
}

int _turnCount(
  List<Vector2> option,
  Vector2 start,
  EnvironmentDirection initialFacing,
) {
  var turns = 0;
  var facing = initialFacing;
  var cursor = start;
  for (final endpoint in option) {
    final next = directionForWorldDelta(endpoint - cursor);
    if (next != facing) turns++;
    facing = next;
    cursor = endpoint;
  }
  return turns;
}

double _projectedLength(Vector2 delta) {
  return const IsometricProjection().worldToScreen(delta).length;
}
