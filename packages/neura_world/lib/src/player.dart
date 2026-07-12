import 'package:vector_math/vector_math.dart';

import 'movement_direction.dart';

class Player {
  Player({Vector2? position})
    : position = position ?? Vector2.zero(),
      target = (position ?? Vector2.zero()).clone();

  final Vector2 position;
  final Vector2 target;
  double speed = 3.5;
  MovementDirection direction = MovementDirection.southEast;

  bool get isMoving => position.distanceTo(target) > 0.001;

  void moveTo(Vector2 destination) => target.setFrom(destination);

  void update(double dt) {
    final delta = target - position;
    final distance = delta.length;
    if (distance == 0) return;

    direction = IsometricMovementDirections.fromWorldMovement(delta);

    final step = speed * dt;
    if (step >= distance) {
      position.setFrom(target);
    } else {
      position.add(delta.normalized() * step);
    }
  }
}
