import 'package:flame/components.dart' show Anchor;
import 'package:flame/extensions.dart';
import 'package:flame/sprite.dart';

import 'package:neura_world/neura_world.dart';

/// Renders the tileset's foundation and surface at their shared native anchor.
class GroundSprites {
  GroundSprites({
    required List<Image> foundationImages,
    required List<Image> surfaceImages,
    required Map<GroundType, Image> additionalImages,
  }) : assert(foundationImages.length == surfaceImages.length),
       _foundations = foundationImages.map(Sprite.new).toList(),
       _surfaces = surfaceImages.map(Sprite.new).toList(),
       _additional = additionalImages.map(
         (ground, image) => MapEntry(ground, Sprite(image)),
       );

  static final Vector2 _canvasSize = Vector2.all(256);
  static final Vector2 _clippedCanvasSize = Vector2.all(260);
  static const Anchor _tileCenterAnchor = Anchor(0.5, 208 / 256);

  final List<Sprite> _foundations;
  final List<Sprite> _surfaces;
  final Map<GroundType, Sprite> _additional;

  void render(
    Canvas canvas,
    Vector2 tileCenter,
    int worldX,
    int worldY,
    GroundType ground, {
    bool clipToTile = false,
  }) {
    if (clipToTile) {
      final topDiamond = Path()
        ..moveTo(tileCenter.x, tileCenter.y - 32.5)
        ..lineTo(tileCenter.x + 65, tileCenter.y)
        ..lineTo(tileCenter.x, tileCenter.y + 32.5)
        ..lineTo(tileCenter.x - 65, tileCenter.y)
        ..close();
      canvas
        ..save()
        ..clipPath(topDiamond, doAntiAlias: false);
    }
    final variant = _variantFor(worldX, worldY);
    if (_usesFoundation(ground)) {
      _foundations[variant].render(
        canvas,
        position: tileCenter,
        size: clipToTile ? _clippedCanvasSize : _canvasSize,
        anchor: _tileCenterAnchor,
      );
    }

    final surface = ground == GroundType.grass
        ? _surfaces[variant]
        : _additional[ground];
    if (surface != null) {
      surface.render(
        canvas,
        position: tileCenter,
        size: clipToTile ? _clippedCanvasSize : _canvasSize,
        anchor: _tileCenterAnchor,
      );
    }
    if (clipToTile) canvas.restore();
  }

  bool _usesFoundation(GroundType ground) => switch (ground) {
    GroundType.grass ||
    GroundType.cobblestone ||
    GroundType.woodPlanks ||
    GroundType.stonePavers ||
    GroundType.dryGrass => true,
    GroundType.rockySoil || GroundType.darkEarth => false,
  };

  int _variantFor(int x, int y) {
    var hash = x * 374761393 + y * 668265263;
    hash = hash ^ (hash >> 13);
    return (hash & 0x7fffffff) % _foundations.length;
  }
}
