import 'dart:math' as math;

import 'package:vector_math/vector_math.dart';

import 'environment_document.dart';

/// Converts a world-space movement vector to the nearest documented
/// Other Worlds character direction.
EnvironmentDirection directionForWorldDelta(Vector2 delta) {
  final screenX = delta.x - delta.y;
  final screenY = delta.x + delta.y;
  final sector =
      ((math.atan2(screenY, screenX) / (math.pi / 4)).round() + 8) % 8;
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

/// Builds a path whose every segment exactly matches one of the eight sprite
/// directions. Any planar delta can be decomposed into at most two such
/// segments. The longer projected segment is used first, keeping most of the
/// journey close to the direction the player intended.
List<Vector2> majorDirectionWaypoints(
  Vector2 start,
  Vector2 destination, {
  double epsilon = 1e-6,
}) {
  final delta = destination - start;
  final absX = delta.x.abs();
  final absY = delta.y.abs();
  if (absX <= epsilon && absY <= epsilon) return const [];

  if (absX <= epsilon || absY <= epsilon || (absX - absY).abs() <= epsilon) {
    return [destination.clone()];
  }

  final diagonalAmount = math.min(absX, absY);
  final diagonal = Vector2(
    delta.x.sign * diagonalAmount,
    delta.y.sign * diagonalAmount,
  );
  final axial = delta - diagonal;

  // Projection uses 128x64 tiles. Comparing projected lengths makes the
  // choice match what the player sees rather than the unequal world axes.
  final diagonalScreenLength = _projectedLength(diagonal);
  final axialScreenLength = _projectedLength(axial);
  final first = diagonalScreenLength >= axialScreenLength ? diagonal : axial;

  return [start + first, destination.clone()];
}

bool isMajorDirectionDelta(Vector2 delta, {double epsilon = 1e-6}) {
  final absX = delta.x.abs();
  final absY = delta.y.abs();
  return absX <= epsilon || absY <= epsilon || (absX - absY).abs() <= epsilon;
}

double _projectedLength(Vector2 delta) {
  final screenX = (delta.x - delta.y) * 64;
  final screenY = (delta.x + delta.y) * 32;
  return math.sqrt(screenX * screenX + screenY * screenY);
}
