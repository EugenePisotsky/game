import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/sprite.dart';

import 'package:neura_world/neura_world.dart';

class PlayerSprites {
  PlayerSprites({required Image idleSheet, required Image runSheet})
    : _idle = _tickers(idleSheet, 0.09),
      _run = _tickers(runSheet, 0.055);

  static const int _frameCount = 15;
  static final Vector2 _frameSize = Vector2.all(128);
  static final Vector2 _renderSize = Vector2.all(128);

  final List<SpriteAnimationTicker> _idle;
  final List<SpriteAnimationTicker> _run;

  void update(double dt, Player player) => _tickerFor(player).update(dt);

  void render(Canvas canvas, Vector2 feet, Player player) {
    _tickerFor(player).getSprite().render(
      canvas,
      // Feet sit around y=92 inside the 128px source cell.
      position: feet - Vector2(0, 28),
      size: _renderSize,
      anchor: Anchor.center,
    );
  }

  SpriteAnimationTicker _tickerFor(Player player) {
    final animations = player.isMoving ? _run : _idle;
    return animations[player.direction.clockwiseSheetRow];
  }

  static List<SpriteAnimationTicker> _tickers(Image image, double stepTime) =>
      List.generate(MovementDirection.values.length, (row) {
        final animation = SpriteAnimation.fromFrameData(
          image,
          SpriteAnimationData.sequenced(
            amount: _frameCount,
            stepTime: stepTime,
            textureSize: _frameSize,
            texturePosition: Vector2(0, row * _frameSize.y),
          ),
        );
        return animation.createTicker();
      });
}
