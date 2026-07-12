import 'package:vector_math/vector_math.dart';

/// Converts between continuous world/tile coordinates and isometric pixels.
class IsometricProjection {
  const IsometricProjection({this.tileWidth = 128, this.tileHeight = 64});

  final double tileWidth;
  final double tileHeight;

  double get halfWidth => tileWidth / 2;
  double get halfHeight => tileHeight / 2;

  Vector2 worldToScreen(Vector2 world) => Vector2(
    (world.x - world.y) * halfWidth,
    (world.x + world.y) * halfHeight,
  );

  Vector2 screenToWorld(Vector2 screen) => Vector2(
    screen.x / tileWidth + screen.y / tileHeight,
    screen.y / tileHeight - screen.x / tileWidth,
  );
}
