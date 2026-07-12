import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/cache.dart';
import 'package:flame/game.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

import 'editor_controller.dart';

class EditorGame extends FlameGame {
  EditorGame(this.controller) {
    images = Images(prefix: neuraAssetPrefix);
  }

  final EditorController controller;
  final IsometricProjection projection = const IsometricProjection();
  static const double zoom = 0.72;
  final Vector2 _panOffset = Vector2.zero();
  final Vector2 _panVelocity = Vector2.zero();
  bool _isPanning = false;

  late final GroundSprites _groundSprites;
  late final RoadSprites _roadSprites;
  late final TileLayerSprites _tileLayerSprites;
  late final EnvironmentSprites _environmentSprites;
  late final AnimalSprites _animalSprites;
  final Map<String, Animal> _animals = {};
  final Set<String> _loadingTileLayers = {};

  final Paint _gridPaint = Paint()
    ..color = const Color(0x35FFFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  final Paint _elevatedGridPaint = Paint()
    ..color = const Color(0x8FCBE0D1)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.35;
  final Paint _hoverPaint = Paint()
    ..color = const Color(0x4CD7B96E)
    ..style = PaintingStyle.fill;
  final Paint _hoverOutlinePaint = Paint()
    ..color = const Color(0xFFD7B96E)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  final Paint _shadowPaint = Paint()..color = const Color(0x52000000);

  @override
  Color backgroundColor() => const Color(0xFF121713);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    final additionalGround = await images.loadAll([
      'ground/rocky_soil_n.png',
      'ground/dark_earth_n.png',
      'ground/cobblestone_n.png',
      'ground/wood_planks_n.png',
      'ground/stone_pavers_n.png',
      'ground/dry_grass_n.png',
    ]);
    _groundSprites = GroundSprites(
      foundationImages: await images.loadAll([
        'ground/dirt_n.png',
        'ground/dirt_e.png',
        'ground/dirt_s.png',
        'ground/dirt_w.png',
      ]),
      surfaceImages: await images.loadAll([
        'ground/grass_n.png',
        'ground/grass_e.png',
        'ground/grass_s.png',
        'ground/grass_w.png',
      ]),
      additionalImages: {
        GroundType.rockySoil: additionalGround[0],
        GroundType.darkEarth: additionalGround[1],
        GroundType.cobblestone: additionalGround[2],
        GroundType.woodPlanks: additionalGround[3],
        GroundType.stonePavers: additionalGround[4],
        GroundType.dryGrass: additionalGround[5],
      },
    );
    _roadSprites = RoadSprites(images: await _loadRoadImages());
    _tileLayerSprites = TileLayerSprites(images: {});
    await _loadTileLayerAssets(_tileLayerIdsInDocument());
    final environment = await images.loadAll([
      for (final type in DecorationType.values)
        for (final rotation in TileRotation.values)
          environmentAssetPath(type, rotation),
    ]);
    var environmentIndex = 0;
    _environmentSprites = EnvironmentSprites(
      images: {
        for (final type in DecorationType.values)
          type: {
            for (final rotation in TileRotation.values)
              rotation: environment[environmentIndex++],
          },
      },
    );
    final sheep = await images.loadAll([
      'animals/sheep/idle.png',
      'animals/sheep/walk.png',
    ]);
    _animalSprites = AnimalSprites(idleSheet: sheep[0], walkSheet: sheep[1]);
  }

  CellCoordinate? cellAtScreen(Vector2 screen) {
    if (!isLoaded) return null;
    final worldScreen =
        (screen - size / 2 - _panOffset) / zoom + _mapCenterScreen;
    CellCoordinate? best;
    var bestElevation = -1;
    var bestDistance = double.infinity;
    final document = controller.document;
    for (var y = document.originY; y <= document.maxY; y++) {
      for (var x = document.originX; x <= document.maxX; x++) {
        final elevation = document.elevationAt(x, y);
        final center = _screenFor(x.toDouble(), y.toDouble(), elevation);
        final dx = (worldScreen.x - center.x).abs() / projection.halfWidth;
        final dy = (worldScreen.y - center.y).abs() / projection.halfHeight;
        final distance = dx + dy;
        if (distance > 1) continue;
        if (distance < bestDistance - 0.0001 ||
            ((distance - bestDistance).abs() <= 0.0001 &&
                elevation > bestElevation)) {
          best = CellCoordinate(x, y);
          bestElevation = elevation;
          bestDistance = distance;
        }
      }
    }
    return best;
  }

  void beginPan() {
    if (_isPanning) return;
    _isPanning = true;
    _panVelocity.setZero();
  }

  /// Moves the map in viewport pixels and records velocity for inertial motion.
  void panByScreenDelta(Vector2 delta, {required double elapsedSeconds}) {
    _panOffset.add(delta);
    final sampleSeconds = elapsedSeconds.clamp(1 / 240, 1 / 15);
    final instantaneousVelocity = delta / sampleSeconds;
    _panVelocity
      ..scale(0.62)
      ..add(instantaneousVelocity * 0.38);
  }

  void endPan() {
    _isPanning = false;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_isPanning && _panVelocity.length2 > 1) {
      _panOffset.add(_panVelocity * dt);
      _panVelocity.scale(math.exp(-6.5 * dt));
      if (_panVelocity.length < 8) _panVelocity.setZero();
    }
    _loadMissingTileLayerAssets();
    _syncAnimals();
    for (final animal in _animals.values) {
      animal.update(dt);
      _animalSprites.update(dt, animal);
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final document = controller.document;
    canvas
      ..save()
      ..translate(size.x / 2 + _panOffset.x, size.y / 2 + _panOffset.y)
      ..scale(zoom)
      ..translate(-_mapCenterScreen.x, -_mapCenterScreen.y);

    final cells = <CellCoordinate>[
      for (var y = document.originY; y <= document.maxY; y++)
        for (var x = document.originX; x <= document.maxX; x++)
          CellCoordinate(x, y),
    ]..sort(_compareCells);

    final maxElevation = document.elevations.values.fold<int>(0, math.max);
    for (var level = 0; level <= maxElevation; level++) {
      // Render each material as a complete pass. Drawing a whole cell stack at
      // once lets a later cell's ground cover an earlier cell's road or grid.
      for (final cell in cells) {
        if (document.elevationAt(cell.x, cell.y) != level) continue;
        final center = _screenFor(cell.x.toDouble(), cell.y.toDouble(), level);
        _groundSprites.render(
          canvas,
          center,
          cell.x,
          cell.y,
          document.groundAt(cell.x, cell.y),
          clipToTile: level > 0,
        );
      }
      final maxLayerCount = cells
          .where((cell) => document.elevationAt(cell.x, cell.y) == level)
          .map((cell) => document.tileLayersAt(cell.x, cell.y).length)
          .fold<int>(0, math.max);
      for (var layerIndex = 0; layerIndex < maxLayerCount; layerIndex++) {
        for (final cell in cells) {
          if (document.elevationAt(cell.x, cell.y) != level) continue;
          final layers = document.tileLayersAt(cell.x, cell.y);
          if (layerIndex >= layers.length) continue;
          final layer = layers[layerIndex];
          final center = _screenFor(
            cell.x.toDouble(),
            cell.y.toDouble(),
            level,
          );
          final catalogItem = controller.groundCatalog.itemById(layer.assetId);
          _tileLayerSprites.render(
            canvas,
            center,
            layer,
            clipToTile: level > 0 && catalogItem?.role == 'base' ? true : null,
            cropBakedEdge: level > 0 && catalogItem?.role == 'base',
          );
        }
      }
      for (final cell in cells) {
        if (document.elevationAt(cell.x, cell.y) != level) continue;
        if (document.roadAt(cell.x, cell.y) != null) {
          _roadSprites.render(
            canvas,
            _screenFor(cell.x.toDouble(), cell.y.toDouble(), level),
            document.roadTileVariantAt(cell.x, cell.y),
          );
        }
      }
      if (level == 0) {
        for (final cell in cells) {
          if (document.elevationAt(cell.x, cell.y) == 0) {
            _drawDiamond(canvas, cell, _gridPaint);
          }
        }
      }
      for (final cell in cells) {
        for (final cliff in elevationCliffsAt(document, cell.x, cell.y)) {
          if (cliff.level != level) continue;
          _tileLayerSprites.render(
            canvas,
            _screenFor(cell.x.toDouble(), cell.y.toDouble(), level),
            cliff.layer,
          );
        }
      }
    }

    final scene = <_SceneEntry>[];
    for (final entry in document.decorations.entries) {
      final cell = entry.key;
      final elevation = document.elevationAt(cell.x, cell.y);
      scene.add(
        _SceneEntry(
          depth: cell.x + cell.y - elevation * 2.0,
          tieBreaker: cell.x.toDouble(),
          draw: (canvas) => _environmentSprites.render(
            canvas,
            _screenFor(
              cell.x.toDouble(),
              cell.y.toDouble(),
              document.elevationAt(cell.x, cell.y),
            ),
            entry.value,
          ),
        ),
      );
    }
    for (final actor in document.actors) {
      final animal = _animals[actor.id];
      if (animal == null) continue;
      final elevation = document.elevationAt(actor.x.round(), actor.y.round());
      scene.add(
        _SceneEntry(
          depth: actor.x + actor.y - elevation * 2.0,
          tieBreaker: actor.x,
          draw: (canvas) {
            final feet = _screenFor(
              actor.x,
              actor.y,
              document.elevationAt(actor.x.round(), actor.y.round()),
            );
            canvas.drawOval(
              Rect.fromCenter(
                center: Offset(feet.x, feet.y + 3),
                width: 32,
                height: 12,
              ),
              _shadowPaint,
            );
            _animalSprites.render(canvas, feet, animal);
          },
        ),
      );
    }
    scene.sort((a, b) {
      final depth = a.depth.compareTo(b.depth);
      return depth != 0 ? depth : a.tieBreaker.compareTo(b.tieBreaker);
    });
    for (final entry in scene) {
      entry.draw(canvas);
    }
    for (final cell in cells) {
      if (document.elevationAt(cell.x, cell.y) > 0) {
        _drawDiamond(canvas, cell, _elevatedGridPaint);
      }
    }
    final hovered = controller.hoveredCell;
    if (hovered != null) {
      _drawDiamond(canvas, hovered, _hoverPaint);
      _drawDiamond(canvas, hovered, _hoverOutlinePaint);
    }
    canvas.restore();
  }

  Vector2 get _mapCenterScreen {
    final document = controller.document;
    return projection.worldToScreen(
      Vector2(
        (document.originX + document.maxX) / 2,
        (document.originY + document.maxY) / 2,
      ),
    );
  }

  Vector2 _screenFor(double x, double y, [int elevation = 0]) =>
      projection.worldToScreen(Vector2(x, y)) -
      Vector2(0, elevation * elevationStepPixels);

  void _drawDiamond(Canvas canvas, CellCoordinate cell, Paint paint) {
    final center = _screenFor(
      cell.x.toDouble(),
      cell.y.toDouble(),
      controller.document.elevationAt(cell.x, cell.y),
    );
    final path = Path()
      ..moveTo(center.x, center.y - projection.halfHeight)
      ..lineTo(center.x + projection.halfWidth, center.y)
      ..lineTo(center.x, center.y + projection.halfHeight)
      ..lineTo(center.x - projection.halfWidth, center.y)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _syncAnimals() {
    final actorIds = controller.document.actors
        .map((actor) => actor.id)
        .toSet();
    _animals.removeWhere((id, _) => !actorIds.contains(id));
    for (final actor in controller.document.actors) {
      _animals.putIfAbsent(
        actor.id,
        () => Animal(
          home: Vector2(actor.x, actor.y),
          randomSeed: actor.id.hashCode,
          behavior: const AnimalBehavior(
            roamingRadius: 0,
            walkingSpeed: 0,
            minIdleTime: 10,
            maxIdleTime: 10,
          ),
        ),
      );
    }
  }

  static int _compareCells(CellCoordinate a, CellCoordinate b) {
    final depth = (a.x + a.y).compareTo(b.x + b.y);
    return depth != 0 ? depth : a.x.compareTo(b.x);
  }

  Future<Map<RoadTileVariant, Image>> _loadRoadImages() async {
    final roadImages = await images.loadAll([
      'ground/road_isolated.png',
      'ground/road_end_negative_x.png',
      'ground/road_end_positive_x.png',
      'ground/road_end_negative_y.png',
      'ground/road_end_positive_y.png',
      'ground/road_straight_y.png',
      'ground/road_straight_x.png',
      'ground/road_corner_n.png',
      'ground/road_corner_e.png',
      'ground/road_corner_s.png',
      'ground/road_corner_w.png',
      'ground/road_junction.png',
    ]);
    return {
      for (var i = 0; i < RoadTileVariant.values.length; i++)
        RoadTileVariant.values[i]: roadImages[i],
    };
  }

  Set<String> _tileLayerIdsInDocument() => {
    for (final layers in controller.document.tileLayers.values)
      for (final layer in layers) layer.assetId,
    if (controller.document.elevations.isNotEmpty) ...earthElevationAssetIds,
  };

  void _loadMissingTileLayerAssets() {
    final missing = _tileLayerIdsInDocument()
        .where(
          (assetId) =>
              !_tileLayerSprites.contains(assetId) &&
              !_loadingTileLayers.contains(assetId),
        )
        .toList();
    if (missing.isNotEmpty) unawaited(_loadTileLayerAssets(missing));
  }

  Future<void> _loadTileLayerAssets(Iterable<String> assetIds) async {
    for (final assetId in assetIds) {
      if (_tileLayerSprites.contains(assetId) ||
          !_loadingTileLayers.add(assetId)) {
        continue;
      }
      final item = controller.groundCatalog.itemById(assetId);
      if (item == null) {
        _loadingTileLayers.remove(assetId);
        continue;
      }
      try {
        final loaded = await images.loadAll([
          for (final rotation in TileRotation.values)
            item.assetForKey(rotation.name[0]),
        ]);
        _tileLayerSprites.add(assetId, {
          for (var index = 0; index < TileRotation.values.length; index++)
            TileRotation.values[index]: loaded[index],
        }, clipToTile: item.stackable);
      } finally {
        _loadingTileLayers.remove(assetId);
      }
    }
  }
}

class _SceneEntry {
  const _SceneEntry({
    required this.depth,
    required this.tieBreaker,
    required this.draw,
  });

  final double depth;
  final double tieBreaker;
  final void Function(Canvas canvas) draw;
}
