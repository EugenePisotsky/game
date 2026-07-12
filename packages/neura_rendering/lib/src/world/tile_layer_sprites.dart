import 'package:flame/components.dart' show Anchor;
import 'package:flame/extensions.dart';
import 'package:flame/sprite.dart';
import 'package:neura_world/neura_world.dart';

class TileLayerSprites {
  TileLayerSprites({
    required Map<String, Map<TileRotation, Image>> images,
    Set<String> unclippedAssetIds = const {},
  }) : _unclippedAssetIds = {...unclippedAssetIds},
       _sprites = {
         for (final assetEntry in images.entries)
           assetEntry.key: assetEntry.value.map(
             (rotation, image) => MapEntry(rotation, Sprite(image)),
           ),
       };

  static final Vector2 _canvasSize = Vector2.all(256);
  static final Vector2 _clippedCanvasSize = Vector2.all(260);
  static final Vector2 _croppedSurfaceCanvasSize = Vector2.all(288);
  static const Anchor _tileCenterAnchor = Anchor(0.5, 208 / 256);

  final Map<String, Map<TileRotation, Sprite>> _sprites;
  final Set<String> _unclippedAssetIds;

  bool contains(String assetId) => _sprites.containsKey(assetId);

  void add(
    String assetId,
    Map<TileRotation, Image> images, {
    bool clipToTile = true,
  }) {
    _sprites[assetId] = images.map(
      (rotation, image) => MapEntry(rotation, Sprite(image)),
    );
    if (clipToTile) {
      _unclippedAssetIds.remove(assetId);
    } else {
      _unclippedAssetIds.add(assetId);
    }
  }

  void render(
    Canvas canvas,
    Vector2 tileCenter,
    PlacedTileLayer layer, {
    bool? clipToTile,
    bool cropBakedEdge = false,
  }) {
    final sprite = _sprites[layer.assetId]?[layer.rotation];
    if (sprite == null) return;
    final topDiamond = Path()
      ..moveTo(tileCenter.x, tileCenter.y - 32.5)
      ..lineTo(tileCenter.x + 65, tileCenter.y)
      ..lineTo(tileCenter.x, tileCenter.y + 32.5)
      ..lineTo(tileCenter.x - 65, tileCenter.y)
      ..close();
    canvas.save();
    final shouldClip =
        clipToTile ?? !_unclippedAssetIds.contains(layer.assetId);
    if (shouldClip) {
      canvas.clipPath(topDiamond, doAntiAlias: false);
    }
    sprite.render(
      canvas,
      position: tileCenter,
      size: shouldClip
          ? (cropBakedEdge ? _croppedSurfaceCanvasSize : _clippedCanvasSize)
          : _canvasSize,
      anchor: _tileCenterAnchor,
    );
    canvas.restore();
  }
}
