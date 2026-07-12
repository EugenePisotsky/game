import 'dart:math';

import 'package:vector_math/vector_math.dart';

import 'movement_direction.dart';

enum AnimalState { idle, wandering }

enum NearbyPlayerReaction { ignore, observe, flee, approach }

/// Data that can vary by species without changing the state machine.
class AnimalBehavior {
  const AnimalBehavior({
    required this.roamingRadius,
    required this.walkingSpeed,
    required this.minIdleTime,
    required this.maxIdleTime,
    this.nearbyPlayerReaction = NearbyPlayerReaction.ignore,
    this.awarenessRadius = 4,
    this.movementDirections = const [
      MovementDirection.east,
      MovementDirection.northEast,
      MovementDirection.north,
      MovementDirection.northWest,
      MovementDirection.west,
      MovementDirection.southWest,
      MovementDirection.south,
      MovementDirection.southEast,
    ],
  });

  final double roamingRadius;
  final double walkingSpeed;
  final double minIdleTime;
  final double maxIdleTime;
  final NearbyPlayerReaction nearbyPlayerReaction;
  final double awarenessRadius;
  final List<MovementDirection> movementDirections;
}

/// A renderer-independent animal with a small idle/wander state machine.
class Animal {
  Animal({required Vector2 home, required this.behavior, int? randomSeed})
    : home = home.clone(),
      position = home.clone(),
      target = home.clone(),
      _random = Random(randomSeed) {
    _beginIdle();
  }

  final Vector2 home;
  final Vector2 position;
  final Vector2 target;
  final AnimalBehavior behavior;
  final Random _random;

  AnimalState state = AnimalState.idle;
  MovementDirection direction = MovementDirection.southEast;
  double _remainingIdleTime = 0;

  void update(double dt) {
    if (state == AnimalState.idle) {
      _remainingIdleTime -= dt;
      if (_remainingIdleTime <= 0) {
        _beginWandering();
      }
      return;
    }

    final delta = target - position;
    final distance = delta.length;
    final step = behavior.walkingSpeed * dt;
    if (distance <= step) {
      position.setFrom(target);
      _beginIdle();
      return;
    }

    direction = directionForWorldMovement(delta);
    position.add(delta.normalized() * step);
  }

  /// Converts movement on the isometric world plane to one of the sheet rows.
  static MovementDirection directionForWorldMovement(Vector2 movement) =>
      IsometricMovementDirections.fromWorldMovement(movement);

  /// Returns a world-space unit vector whose projected screen direction
  /// exactly matches [direction].
  static Vector2 worldMovementForDirection(MovementDirection direction) =>
      IsometricMovementDirections.worldVector(direction);

  void _beginIdle() {
    state = AnimalState.idle;
    _remainingIdleTime =
        behavior.minIdleTime +
        _random.nextDouble() * (behavior.maxIdleTime - behavior.minIdleTime);
  }

  void _beginWandering() {
    if (behavior.roamingRadius <= 0 || behavior.movementDirections.isEmpty) {
      _beginIdle();
      return;
    }

    // Choose whole walking segments from directions that have actual art.
    // Retrying keeps the destination inside the animal's circular home range.
    for (var attempt = 0; attempt < 32; attempt++) {
      final candidateDirection =
          behavior.movementDirections[_random.nextInt(
            behavior.movementDirections.length,
          )];
      final distance =
          behavior.roamingRadius * (0.2 + _random.nextDouble() * 0.55);
      final candidate =
          position + worldMovementForDirection(candidateDirection) * distance;
      if (candidate.distanceTo(home) <= behavior.roamingRadius) {
        _startWalkingTo(candidate, candidateDirection);
        return;
      }
    }

    // At an edge, choose the supported direction that points most toward home.
    final towardHome = home - position;
    final fallbackDirection = behavior.movementDirections.reduce((best, next) {
      final bestScore = worldMovementForDirection(best).dot(towardHome);
      final nextScore = worldMovementForDirection(next).dot(towardHome);
      return nextScore > bestScore ? next : best;
    });
    var distance = behavior.roamingRadius * 0.2;
    var candidate =
        position + worldMovementForDirection(fallbackDirection) * distance;
    while (candidate.distanceTo(home) > behavior.roamingRadius &&
        distance > 0.001) {
      distance /= 2;
      candidate =
          position + worldMovementForDirection(fallbackDirection) * distance;
    }
    _startWalkingTo(candidate, fallbackDirection);
  }

  void _startWalkingTo(Vector2 destination, MovementDirection newDirection) {
    target.setFrom(destination);
    direction = newDirection;
    state = AnimalState.wandering;
  }
}
