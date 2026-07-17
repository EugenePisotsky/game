import 'dart:math';

import 'package:vector_math/vector_math.dart';

import 'world/isometric_projection.dart';

enum MovementDirection {
  east,
  northEast,
  north,
  northWest,
  west,
  southWest,
  south,
  southEast,
}

extension MovementDirectionSheetRow on MovementDirection {
  int get clockwiseSheetRow => switch (this) {
    MovementDirection.east => 0,
    MovementDirection.southEast => 1,
    MovementDirection.south => 2,
    MovementDirection.southWest => 3,
    MovementDirection.west => 4,
    MovementDirection.northWest => 5,
    MovementDirection.north => 6,
    MovementDirection.northEast => 7,
  };
}

class IsometricMovementDirections {
  const IsometricMovementDirections._();

  static MovementDirection fromWorldMovement(Vector2 movement) {
    final screen = const IsometricProjection().worldToScreen(movement);
    var degrees = atan2(-screen.y, screen.x) * 180 / pi;
    if (degrees < 0) degrees += 360;
    final index = (degrees / 45).round() % MovementDirection.values.length;
    return MovementDirection.values[index];
  }

  static Vector2 worldVector(MovementDirection direction) {
    final angle = direction.index * pi / 4;
    final screen = Vector2(cos(angle), -sin(angle));
    return const IsometricProjection().screenToWorld(screen).normalized();
  }
}
