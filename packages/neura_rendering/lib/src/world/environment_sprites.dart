import 'dart:ui' show Color, Paint;

import 'package:flame/components.dart' show Anchor;
import 'package:flame/extensions.dart';
import 'package:flame/sprite.dart';

import 'package:neura_world/neura_world.dart';

class EnvironmentSprites {
  EnvironmentSprites({
    required Map<DecorationType, Map<TileRotation, Image>> images,
  }) : _sprites = images.map(
         (decoration, rotations) => MapEntry(
           decoration,
           rotations.map(
             (rotation, image) => MapEntry(rotation, Sprite(image)),
           ),
         ),
       );

  static const Anchor _tileCenterAnchor = Anchor(0.5, 208 / 256);
  static final Paint _paint = Paint();

  final Map<DecorationType, Map<TileRotation, Sprite>> _sprites;

  void render(
    Canvas canvas,
    Vector2 tileCenter,
    PlacedDecoration decoration, {
    double opacity = 1,
  }) {
    final sprite = _sprites[decoration.type]?[decoration.rotation];
    if (sprite == null) return;
    _paint.color = Color.fromRGBO(255, 255, 255, opacity);
    sprite.render(
      canvas,
      position: tileCenter,
      size: Vector2(
        sprite.image.width.toDouble(),
        sprite.image.height.toDouble(),
      ),
      anchor: _tileCenterAnchor,
      overridePaint: _paint,
    );
  }
}

bool decorationSupportsRotation(DecorationType type) => switch (type) {
  DecorationType.ruralTreeA1 ||
  DecorationType.ruralTreeA2 ||
  DecorationType.ruralTreeA3 ||
  DecorationType.ruralTreeA4 ||
  DecorationType.ruralTreeA5 ||
  DecorationType.ruralTreeA6 ||
  DecorationType.ruralTreeA7 ||
  DecorationType.ruralTreeA8 ||
  DecorationType.ruralTreeA9 ||
  DecorationType.ruralTreeA10 ||
  DecorationType.ruralTreeA11 ||
  DecorationType.ruralTreeA12 ||
  DecorationType.ruralTreeB1 ||
  DecorationType.ruralTreeB2 ||
  DecorationType.ruralTreeB3 ||
  DecorationType.ruralTreeC1 ||
  DecorationType.ruralTreeC2 ||
  DecorationType.ruralTreeC3 => true,
  _ => false,
};

String environmentAssetPath(DecorationType type, TileRotation rotation) {
  final fixed = switch (type) {
    DecorationType.roundTree => 'environment/tree_round.png',
    DecorationType.wideTree => 'environment/tree_wide.png',
    DecorationType.bush => 'environment/bush.png',
    DecorationType.lowFlora => 'environment/low_flora.png',
    DecorationType.leafyGroundcover => 'environment/leafy_groundcover.png',
    DecorationType.clayPots => 'environment/clay_pots.png',
    DecorationType.woodenCrate => 'environment/wooden_crate.png',
    DecorationType.stoneWell => 'environment/stone_well.png',
    DecorationType.woodenSign => 'environment/wooden_sign.png',
    DecorationType.fallenLog => 'environment/fallen_log.png',
    DecorationType.firewoodPile => 'environment/firewood_pile.png',
    DecorationType.stonePile => 'environment/stone_pile.png',
    DecorationType.hayBale => 'environment/hay_bale.png',
    DecorationType.closedChest => 'environment/closed_chest.png',
    _ => null,
  };
  if (fixed != null) return fixed;
  final treeId = switch (type) {
    DecorationType.ruralTreeA1 => 'A1',
    DecorationType.ruralTreeA2 => 'A2',
    DecorationType.ruralTreeA3 => 'A3',
    DecorationType.ruralTreeA4 => 'A4',
    DecorationType.ruralTreeA5 => 'A5',
    DecorationType.ruralTreeA6 => 'A6',
    DecorationType.ruralTreeA7 => 'A7',
    DecorationType.ruralTreeA8 => 'A8',
    DecorationType.ruralTreeA9 => 'A9',
    DecorationType.ruralTreeA10 => 'A10',
    DecorationType.ruralTreeA11 => 'A11',
    DecorationType.ruralTreeA12 => 'A12',
    DecorationType.ruralTreeB1 => 'B1',
    DecorationType.ruralTreeB2 => 'B2',
    DecorationType.ruralTreeB3 => 'B3',
    DecorationType.ruralTreeC1 => 'C1',
    DecorationType.ruralTreeC2 => 'C2',
    DecorationType.ruralTreeC3 => 'C3',
    _ => throw StateError('No environment asset for $type'),
  };
  final direction = switch (rotation) {
    TileRotation.north => 'N',
    TileRotation.east => 'E',
    TileRotation.south => 'S',
    TileRotation.west => 'W',
  };
  return 'environment/rural_tree_${treeId}_$direction.png';
}
