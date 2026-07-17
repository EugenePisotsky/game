import 'package:vector_math/vector_math.dart';

/// Converts between continuous world/tile coordinates and isometric pixels.
class IsometricProjection {
  const IsometricProjection({
    this.tileWidth = defaultTileWidth,
    this.tileHeight = defaultTileHeight,
  });

  /// The source art uses a true-isometric ground plane. Its diamond height is
  /// `1 / sqrt(2)` of its width (about 35.264 degrees per ground axis), rather
  /// than the 1:2 ratio commonly used for pixel-art dimetric projections.
  static const double trueIsometricRatio = 0.7071067811865476;
  static const double defaultTileWidth = 128;
  static const double defaultTileHeight = defaultTileWidth * trueIsometricRatio;

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
