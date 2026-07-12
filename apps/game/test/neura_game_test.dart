import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  test('maps world movement onto all documented character directions', () {
    expect(
      directionForWorldDelta(Vector2(1, 0)),
      EnvironmentDirection.southEast,
    );
    expect(
      directionForWorldDelta(Vector2(0, 1)),
      EnvironmentDirection.southWest,
    );
    expect(
      directionForWorldDelta(Vector2(-1, 0)),
      EnvironmentDirection.northWest,
    );
    expect(
      directionForWorldDelta(Vector2(0, -1)),
      EnvironmentDirection.northEast,
    );
    expect(directionForWorldDelta(Vector2(1, 1)), EnvironmentDirection.south);
    expect(directionForWorldDelta(Vector2(-1, -1)), EnvironmentDirection.north);
  });
}
