import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/cache.dart';
import 'package:flame/components.dart' show Anchor;
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/sprite.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

/// Small playable proof that the painted environment and modular Other Worlds
/// character sheets share one coherent isometric space.
class NeuraGame extends FlameGame with TapCallbacks {
  NeuraGame() {
    images = Images(prefix: neuraAssetPrefix);
  }

  final IsometricProjection projection = const IsometricProjection();
  final Vector2 playerPosition = Vector2(12, 20.5);
  final Map<String, ui.Image> _loadedImages = {};
  final Map<String, ui.Paint> _repeatingPaints = {};
  final Map<String, ui.Paint> _decalPaints = {};
  final Map<String, _CharacterImages> _characterImages = {};

  late final EnvironmentDocument document;
  late final EnvironmentCatalog environmentCatalog;
  late final CharacterCatalog characterCatalog;

  final List<Vector2> _movementWaypoints = [];
  Vector2? _destination;
  EnvironmentDirection _facing = EnvironmentDirection.north;
  String _characterId = 'other_worlds.male_1';
  double _animationTime = 0;
  double zoom = 0.9;

  static const double playerSpeedPixelsPerSecond = 210;
  static const double _walkFramesPerSecond = 10;
  static const double _idleFramesPerSecond = 5;

  final ui.Paint _targetPaint = ui.Paint()
    ..color = const ui.Color(0xFFEACB73)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _mapOutlinePaint = ui.Paint()
    ..color = const ui.Color(0x338DA596)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5;

  static final Float64List _identityMatrix = Float64List.fromList([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);

  String get characterId => _characterId;
  bool get isMoving => _movementWaypoints.isNotEmpty;
  Vector2? get destination => _destination?.clone();

  void setCharacter(String id) {
    if (_characterImages.containsKey(id)) {
      _characterId = id;
      _animationTime = 0;
    }
  }

  @override
  ui.Color backgroundColor() => const ui.Color(0xFF101713);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    document = EnvironmentDocument.fromJsonString(
      await rootBundle.loadString(
        'packages/neura_assets/assets/worlds/environment_starter.json',
      ),
    );
    environmentCatalog = EnvironmentCatalog.fromJsonString(
      await rootBundle.loadString(
        'packages/neura_assets/assets/catalogs/environment_catalog.json',
      ),
    );
    characterCatalog = CharacterCatalog.fromJsonString(
      await rootBundle.loadString(
        'packages/neura_assets/assets/catalogs/character_catalog.json',
      ),
    );

    final usedMaterialIds = <String>{
      document.baseMaterialId,
      for (final stroke in document.terrainStrokes) stroke.materialId,
    };
    final usedMaterials = <EnvironmentMaterial>[];
    for (final id in usedMaterialIds) {
      final material = environmentCatalog.materialById(id);
      if (material != null) usedMaterials.add(material);
    }
    final paths = <String>{
      for (final material in usedMaterials) ...[
        material.texturePath,
        material.decalPath,
      ],
      for (final character in characterCatalog.characters) ...[
        character.idlePath,
        character.walkPath,
      ],
    };
    for (final object in document.objects) {
      final asset = environmentCatalog.objectById(object.assetId);
      if (asset != null) {
        paths.add(asset.viewFor(object.direction.name).imagePath);
      }
    }
    final pathList = paths.toList();
    final loaded = await Future.wait([
      for (final path in pathList)
        path.startsWith('environment_generated/')
            ? loadGeneratedEnvironmentImage(path)
            : images.load(path),
    ]);
    for (var index = 0; index < pathList.length; index++) {
      _loadedImages[pathList[index]] = loaded[index];
    }

    for (final material in usedMaterials) {
      _repeatingPaints[material.id] = ui.Paint()
        ..shader = ui.ImageShader(
          _loadedImages[material.texturePath]!,
          ui.TileMode.repeated,
          ui.TileMode.repeated,
          _identityMatrix,
        );
      _decalPaints[material.id] = ui.Paint()
        ..shader = ui.ImageShader(
          _loadedImages[material.decalPath]!,
          ui.TileMode.clamp,
          ui.TileMode.clamp,
          _identityMatrix,
        );
    }
    for (final character in characterCatalog.characters) {
      _characterImages[character.id] = _CharacterImages(
        idle: _loadedImages[character.idlePath]!,
        walk: _loadedImages[character.walkPath]!,
      );
    }
  }

  @override
  void onTapDown(TapDownEvent event) {
    if (!isLoaded) return;
    final projected =
        (event.canvasPosition - size / 2) / zoom + _cameraProjectedPosition;
    final world = projection.screenToWorld(projected);
    final destination = Vector2(
      world.x.clamp(0.0, document.width.toDouble()),
      world.y.clamp(0.0, document.height.toDouble()),
    );
    _movementWaypoints
      ..clear()
      ..addAll(majorDirectionWaypoints(playerPosition, destination));
    _destination = _movementWaypoints.isEmpty ? null : destination;
    _animationTime = 0;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_movementWaypoints.isEmpty) {
      _animationTime += dt;
      return;
    }

    var remainingPixels = playerSpeedPixelsPerSecond * dt;
    while (_movementWaypoints.isNotEmpty && remainingPixels > 0) {
      final waypoint = _movementWaypoints.first;
      final delta = waypoint - playerPosition;
      final projectedDistance = projection.worldToScreen(delta).length;
      if (projectedDistance <= 0.01) {
        playerPosition.setFrom(waypoint);
        _movementWaypoints.removeAt(0);
        continue;
      }

      _facing = directionForWorldDelta(delta);
      if (remainingPixels >= projectedDistance) {
        playerPosition.setFrom(waypoint);
        _movementWaypoints.removeAt(0);
        remainingPixels -= projectedDistance;
      } else {
        playerPosition.add(delta * (remainingPixels / projectedDistance));
        remainingPixels = 0;
      }
    }

    if (_movementWaypoints.isEmpty) {
      _destination = null;
      _animationTime = 0;
    } else {
      _animationTime += dt;
    }
  }

  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);
    if (!isLoaded) return;

    canvas
      ..save()
      ..translate(size.x / 2, size.y / 2)
      ..scale(zoom)
      ..translate(-_cameraProjectedPosition.x, -_cameraProjectedPosition.y);

    _renderBaseGround(canvas);
    for (final stroke in document.terrainStrokes) {
      _renderStroke(canvas, stroke);
    }
    _renderMapOutline(canvas);
    _renderTarget(canvas);
    _renderScene(canvas);
    canvas.restore();
  }

  void _renderBaseGround(ui.Canvas canvas) {
    final material = environmentCatalog.materialById(document.baseMaterialId);
    final paint = _repeatingPaints[document.baseMaterialId];
    if (material == null || paint == null) return;
    _drawTexturedWorldQuad(
      canvas,
      const WorldPoint(0, 0),
      WorldPoint(document.width.toDouble(), document.height.toDouble()),
      paint,
      ui.Rect.fromLTWH(0, 0, document.width * 64, document.height * 64),
    );
  }

  void _renderStroke(ui.Canvas canvas, TerrainStroke stroke) {
    if (stroke.points.isEmpty) return;
    final material = environmentCatalog.materialById(stroke.materialId);
    final paint = _decalPaints[stroke.materialId];
    if (material == null || paint == null) return;
    final image = _loadedImages[material.decalPath]!;
    paint.color = ui.Color.fromRGBO(255, 255, 255, stroke.opacity);
    final spacing = math.max(0.15, stroke.radius * 0.22);
    WorldPoint? previous;
    for (final point in stroke.points) {
      if (previous == null) {
        _drawStamp(canvas, point, stroke.radius, paint, image);
      } else {
        final dx = point.x - previous.x;
        final dy = point.y - previous.y;
        final distance = math.sqrt(dx * dx + dy * dy);
        final steps = math.max(1, (distance / spacing).ceil());
        for (var step = 1; step <= steps; step++) {
          final t = step / steps;
          _drawStamp(
            canvas,
            WorldPoint(previous.x + dx * t, previous.y + dy * t),
            stroke.radius,
            paint,
            image,
          );
        }
      }
      previous = point;
    }
  }

  void _drawStamp(
    ui.Canvas canvas,
    WorldPoint center,
    double radius,
    ui.Paint paint,
    ui.Image image,
  ) {
    _drawTexturedWorldQuad(
      canvas,
      WorldPoint(center.x - radius, center.y - radius),
      WorldPoint(center.x + radius, center.y + radius),
      paint,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    );
  }

  void _drawTexturedWorldQuad(
    ui.Canvas canvas,
    WorldPoint min,
    WorldPoint max,
    ui.Paint paint,
    ui.Rect textureRect,
  ) {
    final corners = [
      projection.worldToScreen(Vector2(min.x, min.y)),
      projection.worldToScreen(Vector2(max.x, min.y)),
      projection.worldToScreen(Vector2(max.x, max.y)),
      projection.worldToScreen(Vector2(min.x, max.y)),
    ];
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangleFan,
      Float32List.fromList([
        for (final corner in corners) ...[corner.x, corner.y],
      ]),
      textureCoordinates: Float32List.fromList([
        textureRect.left,
        textureRect.top,
        textureRect.right,
        textureRect.top,
        textureRect.right,
        textureRect.bottom,
        textureRect.left,
        textureRect.bottom,
      ]),
    );
    canvas.drawVertices(vertices, ui.BlendMode.srcOver, paint);
  }

  void _renderScene(ui.Canvas canvas) {
    final entries =
        <_SceneEntry>[
          for (final object in document.objects)
            _SceneEntry.object(object, object.x + object.y),
          _SceneEntry.player(playerPosition.x + playerPosition.y),
        ]..sort((a, b) {
          final depth = a.depth.compareTo(b.depth);
          if (depth != 0) return depth;
          return a.x.compareTo(b.x);
        });

    for (final entry in entries) {
      if (entry.object case final object?) {
        _renderObject(canvas, object);
      } else {
        _renderPlayer(canvas);
      }
    }
  }

  void _renderObject(ui.Canvas canvas, PlacedEnvironmentObject object) {
    final asset = environmentCatalog.objectById(object.assetId);
    if (asset == null) return;
    final view = asset.viewFor(object.direction.name);
    final image = _loadedImages[view.imagePath];
    if (image == null) return;
    Sprite(image).render(
      canvas,
      position: projection.worldToScreen(Vector2(object.x, object.y)),
      size: Vector2(
        image.width * asset.renderScale,
        image.height * asset.renderScale,
      ),
      anchor: Anchor(view.pivotX, view.pivotY),
    );
  }

  void _renderPlayer(ui.Canvas canvas) {
    final asset = characterCatalog.characterById(_characterId);
    final moving = isMoving;
    final imageSet = _characterImages[_characterId]!;
    final image = moving ? imageSet.walk : imageSet.idle;
    final frameCount = moving ? asset.walkFrames : asset.idleFrames;
    final fps = moving ? _walkFramesPerSecond : _idleFramesPerSecond;
    final column = (_animationTime * fps).floor() % frameCount;
    final row = characterCatalog.rowForDirection(_facing.name);
    final frameWidth = characterCatalog.frameWidth.toDouble();
    final frameHeight = characterCatalog.frameHeight.toDouble();
    final position = projection.worldToScreen(playerPosition);
    final destination = ui.Rect.fromLTWH(
      position.x - frameWidth * asset.renderScale * asset.pivotX,
      position.y - frameHeight * asset.renderScale * asset.pivotY,
      frameWidth * asset.renderScale,
      frameHeight * asset.renderScale,
    );
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
        column * frameWidth,
        row * frameHeight,
        frameWidth,
        frameHeight,
      ),
      destination,
      ui.Paint(),
    );
  }

  void _renderTarget(ui.Canvas canvas) {
    final target = _destination;
    if (target == null) return;
    final center = projection.worldToScreen(target);
    final points = [
      projection.worldToScreen(target + Vector2(-0.28, -0.28)),
      projection.worldToScreen(target + Vector2(0.28, -0.28)),
      projection.worldToScreen(target + Vector2(0.28, 0.28)),
      projection.worldToScreen(target + Vector2(-0.28, 0.28)),
    ];
    final path = ui.Path()..moveTo(points.first.x, points.first.y);
    for (final point in points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(path..close(), _targetPaint);
    canvas.drawCircle(center.toOffset(), 2.5, _targetPaint);
  }

  void _renderMapOutline(ui.Canvas canvas) {
    final points = [
      projection.worldToScreen(Vector2.zero()),
      projection.worldToScreen(Vector2(document.width.toDouble(), 0)),
      projection.worldToScreen(
        Vector2(document.width.toDouble(), document.height.toDouble()),
      ),
      projection.worldToScreen(Vector2(0, document.height.toDouble())),
    ];
    final path = ui.Path()..moveTo(points.first.x, points.first.y);
    for (final point in points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(path..close(), _mapOutlinePaint);
  }

  Vector2 get _cameraProjectedPosition =>
      projection.worldToScreen(playerPosition);
}

class _CharacterImages {
  const _CharacterImages({required this.idle, required this.walk});

  final ui.Image idle;
  final ui.Image walk;
}

class _SceneEntry {
  const _SceneEntry._({required this.depth, required this.x, this.object});

  factory _SceneEntry.object(PlacedEnvironmentObject object, double depth) =>
      _SceneEntry._(depth: depth, x: object.x, object: object);

  factory _SceneEntry.player(double depth) =>
      _SceneEntry._(depth: depth, x: double.infinity);

  final double depth;
  final double x;
  final PlacedEnvironmentObject? object;
}
