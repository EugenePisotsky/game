import 'package:flame/components.dart' show Anchor;
import 'package:flame/extensions.dart';
import 'package:flame/sprite.dart';
import 'package:neura_world/neura_world.dart';

class RoadSprites {
  RoadSprites({required Map<RoadTileVariant, Image> images})
    : _sprites = images.map(
        (variant, image) => MapEntry(variant, Sprite(image)),
      );

  static final Vector2 _canvasSize = Vector2.all(256);
  static const Anchor _tileCenterAnchor = Anchor(0.5, 208 / 256);

  final Map<RoadTileVariant, Sprite> _sprites;

  void render(Canvas canvas, Vector2 tileCenter, RoadTileVariant variant) {
    final topDiamond = Path()
      ..moveTo(tileCenter.x, tileCenter.y - 32)
      ..lineTo(tileCenter.x + 64, tileCenter.y)
      ..lineTo(tileCenter.x, tileCenter.y + 32)
      ..lineTo(tileCenter.x - 64, tileCenter.y)
      ..close();
    canvas
      ..save()
      ..clipPath(topDiamond);
    _sprites[variant]?.render(
      canvas,
      position: tileCenter,
      size: _canvasSize,
      anchor: _tileCenterAnchor,
    );
    canvas.restore();
  }
}
