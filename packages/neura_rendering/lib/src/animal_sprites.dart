import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/sprite.dart';

import 'package:neura_world/neura_world.dart';

class AnimalSprites {
  AnimalSprites({required Image idleSheet, required Image walkSheet})
    : _idle = _tickers(idleSheet, 0.11),
      _walk = _tickers(walkSheet, 0.07);

  static const int _frameCount = 15;
  static final Vector2 _frameSize = Vector2.all(64);
  static final Vector2 _renderSize = Vector2.all(80);

  final List<SpriteAnimationTicker> _idle;
  final List<SpriteAnimationTicker> _walk;

  void update(double dt, Animal animal) {
    _tickerFor(animal).update(dt);
  }

  void render(Canvas canvas, Vector2 feet, Animal animal) {
    _tickerFor(animal).getSprite().render(
      canvas,
      // The source cells have transparent padding beneath the animal.
      position: feet - Vector2(0, 7),
      size: _renderSize,
      anchor: Anchor.center,
    );
  }

  SpriteAnimationTicker _tickerFor(Animal animal) {
    final animations = animal.state == AnimalState.idle ? _idle : _walk;
    return animations[rowForDirection(animal.direction)];
  }

  /// The purchased sheets run clockwise down the rows, unlike the semantic
  /// enum which follows increasing mathematical angles.
  static int rowForDirection(MovementDirection direction) =>
      direction.clockwiseSheetRow;

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
