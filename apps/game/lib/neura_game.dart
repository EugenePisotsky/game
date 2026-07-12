import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/cache.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

class NeuraGame extends FlameGame with TapCallbacks {
  NeuraGame() {
    images = Images(prefix: neuraAssetPrefix);
  }

  final IsometricProjection projection = const IsometricProjection();
  static const double worldZoom = 1.25;
  late final WorldDocument worldDocument;
  late final GroundCatalog groundCatalog;
  late final ChunkManager chunks;
  late final Player player;
  final List<Animal> sheep = [];
  late final AnimalSprites _sheepSprites;
  late final PlayerSprites _playerSprites;
  late final GroundSprites _groundSprites;
  late final RoadSprites _roadSprites;
  late final TileLayerSprites _tileLayerSprites;
  late final EnvironmentSprites _environmentSprites;
  final List<CellCoordinate> _playerPath = [];
  final Map<CellCoordinate, double> _decorationOpacity = {};
  CellCoordinate? _moveDestination;

  final Paint _targetPaint = Paint()
    ..color = const Color(0xFFE4CA72)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5;
  @override
  Color backgroundColor() => const Color(0xFF101713);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    worldDocument = WorldDocument.fromJsonString(
      await rootBundle.loadString(
        'packages/neura_assets/assets/worlds/starter_world.json',
      ),
    );
    groundCatalog = GroundCatalog.fromJsonString(
      await rootBundle.loadString(
        'packages/neura_assets/assets/catalogs/ground_catalog.json',
      ),
    );
    chunks = ChunkManager(world: worldDocument);
    player = Player(
      position: Vector2(worldDocument.spawnX, worldDocument.spawnY),
    );
    for (final actor in worldDocument.actors.where(
      (actor) => actor.type == ActorType.sheep,
    )) {
      sheep.add(
        Animal(
          home: Vector2(actor.x, actor.y),
          randomSeed: actor.id.hashCode,
          behavior: const AnimalBehavior(
            roamingRadius: 3.25,
            walkingSpeed: 1.15,
            minIdleTime: 0.7,
            maxIdleTime: 1.8,
            nearbyPlayerReaction: NearbyPlayerReaction.observe,
            awarenessRadius: 4,
          ),
        ),
      );
    }
    final sheets = await Future.wait([
      images.load('animals/sheep/idle.png'),
      images.load('animals/sheep/walk.png'),
    ]);
    _sheepSprites = AnimalSprites(idleSheet: sheets[0], walkSheet: sheets[1]);
    final playerSheets = await images.loadAll([
      'player/idle.png',
      'player/run.png',
    ]);
    _playerSprites = PlayerSprites(
      idleSheet: playerSheets[0],
      runSheet: playerSheets[1],
    );
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
    _tileLayerSprites = TileLayerSprites(
      images: await _loadTileLayerImages(),
      unclippedAssetIds: {
        for (final item in groundCatalog.items)
          if (!item.stackable) item.id,
      },
    );
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
    chunks.updateAround(player.position);
  }

  @override
  void onTapDown(TapDownEvent event) {
    final destination = _cellAtScreen(event.canvasPosition);
    if (destination == null) return;
    final start = CellCoordinate(
      player.position.x.round(),
      player.position.y.round(),
    );
    final path = _findPath(start, destination);
    if (path == null) return;
    _moveDestination = destination;
    _playerPath
      ..clear()
      ..addAll(path.skip(1));
    _advancePlayerPath();
  }

  @override
  void update(double dt) {
    super.update(dt);
    player.update(dt);
    _advancePlayerPath();
    _updateDecorationOcclusion(dt);
    _playerSprites.update(dt, player);
    for (final animal in sheep) {
      animal.update(dt);
      _sheepSprites.update(dt, animal);
    }
    chunks.updateAround(player.position);
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    canvas
      ..save()
      ..translate(size.x / 2, size.y / 2)
      ..scale(worldZoom)
      ..translate(-size.x / 2, -size.y / 2);

    final cameraOffset = _cameraOffset;
    final tiles = chunks.loadedChunks.expand((chunk) => chunk.tiles).toList()
      ..sort((a, b) {
        final depth = (a.x + a.y).compareTo(b.x + b.y);
        return depth != 0 ? depth : a.x.compareTo(b.x);
      });

    final maxElevation = tiles.fold<int>(
      0,
      (highest, tile) => tile.elevation > highest ? tile.elevation : highest,
    );
    for (var level = 0; level <= maxElevation; level++) {
      // Keep complete material passes within an elevation. Otherwise a later
      // cell's ground can overpaint an earlier cell's road and grid edges.
      for (final tile in tiles) {
        if (tile.elevation != level) continue;
        final center =
            _screenFor(tile.x.toDouble(), tile.y.toDouble(), level) +
            cameraOffset;
        if (!_isNearViewport(center)) continue;
        _groundSprites.render(
          canvas,
          center,
          tile.x,
          tile.y,
          tile.ground,
          clipToTile: level > 0,
        );
      }
      final maxLayerCount = tiles
          .where((tile) => tile.elevation == level)
          .map((tile) => tile.tileLayers.length)
          .fold<int>(0, math.max);
      for (var layerIndex = 0; layerIndex < maxLayerCount; layerIndex++) {
        for (final tile in tiles) {
          if (tile.elevation != level || layerIndex >= tile.tileLayers.length) {
            continue;
          }
          final center =
              _screenFor(tile.x.toDouble(), tile.y.toDouble(), level) +
              cameraOffset;
          if (!_isNearViewport(center)) continue;
          final layer = tile.tileLayers[layerIndex];
          final catalogItem = groundCatalog.itemById(layer.assetId);
          _tileLayerSprites.render(
            canvas,
            center,
            layer,
            clipToTile: level > 0 && catalogItem?.role == 'base' ? true : null,
            cropBakedEdge: level > 0 && catalogItem?.role == 'base',
          );
        }
      }
      for (final tile in tiles) {
        if (tile.elevation != level || tile.road == null) continue;
        final center =
            _screenFor(tile.x.toDouble(), tile.y.toDouble(), level) +
            cameraOffset;
        if (!_isNearViewport(center)) continue;
        _roadSprites.render(
          canvas,
          center,
          worldDocument.roadTileVariantAt(tile.x, tile.y),
        );
      }
      for (final tile in tiles) {
        for (final cliff in elevationCliffsAt(worldDocument, tile.x, tile.y)) {
          if (cliff.level != level) continue;
          final center =
              _screenFor(tile.x.toDouble(), tile.y.toDouble(), level) +
              cameraOffset;
          if (_isNearViewport(center)) {
            _tileLayerSprites.render(canvas, center, cliff.layer);
          }
        }
      }
    }

    final scene = <_SceneEntry>[];

    final moveDestination = _moveDestination;
    if (moveDestination != null) {
      final targetCenter =
          _screenFor(
            moveDestination.x.toDouble(),
            moveDestination.y.toDouble(),
            worldDocument.elevationAt(moveDestination.x, moveDestination.y),
          ) +
          cameraOffset;
      _drawTarget(canvas, targetCenter);
    }

    for (final tile in tiles) {
      final decoration = tile.decoration;
      if (decoration == null) continue;
      final cell = CellCoordinate(tile.x, tile.y);
      final center =
          _screenFor(tile.x.toDouble(), tile.y.toDouble(), tile.elevation) +
          cameraOffset;
      if (_isNearViewport(center)) {
        scene.add(
          _SceneEntry(
            depth: _depthAt(
              tile.x.toDouble(),
              tile.y.toDouble(),
              tile.elevation,
            ),
            tieBreaker: tile.x.toDouble(),
            draw: (canvas) => _environmentSprites.render(
              canvas,
              center,
              decoration,
              opacity: _decorationOpacity[cell] ?? 1,
            ),
          ),
        );
      }
    }

    for (final animal in sheep) {
      final sheepFeet =
          _screenFor(
            animal.position.x,
            animal.position.y,
            worldDocument.elevationAt(
              animal.position.x.round(),
              animal.position.y.round(),
            ),
          ) +
          cameraOffset;
      scene.add(
        _SceneEntry(
          depth: _depthAt(
            animal.position.x,
            animal.position.y,
            worldDocument.elevationAt(
              animal.position.x.round(),
              animal.position.y.round(),
            ),
          ),
          tieBreaker: animal.position.x,
          draw: (canvas) => _drawSheep(canvas, sheepFeet, animal),
        ),
      );
    }
    final playerFeet =
        _screenFor(
          player.position.x,
          player.position.y,
          worldDocument.elevationAt(
            player.position.x.round(),
            player.position.y.round(),
          ),
        ) +
        cameraOffset;
    scene.add(
      _SceneEntry(
        depth: _depthAt(
          player.position.x,
          player.position.y,
          worldDocument.elevationAt(
            player.position.x.round(),
            player.position.y.round(),
          ),
        ),
        tieBreaker: player.position.x,
        draw: (canvas) => _drawPlayer(canvas, playerFeet),
      ),
    );
    scene.sort((a, b) {
      final depth = a.depth.compareTo(b.depth);
      return depth != 0 ? depth : a.tieBreaker.compareTo(b.tieBreaker);
    });
    for (final entry in scene) {
      entry.draw(canvas);
    }
    canvas.restore();
  }

  Vector2 get _cameraFocusScreen => _screenFor(
    player.position.x,
    player.position.y,
    worldDocument.elevationAt(
      player.position.x.round(),
      player.position.y.round(),
    ),
  );

  Vector2 get _cameraOffset => size / 2 - _cameraFocusScreen;

  CellCoordinate? _cellAtScreen(Vector2 screen) {
    final unzoomedScreen = (screen - size / 2) / worldZoom + size / 2;
    final worldScreen = unzoomedScreen - size / 2 + _cameraFocusScreen;
    CellCoordinate? best;
    var bestElevation = -1;
    var bestDistance = double.infinity;
    for (var y = worldDocument.originY; y <= worldDocument.maxY; y++) {
      for (var x = worldDocument.originX; x <= worldDocument.maxX; x++) {
        final elevation = worldDocument.elevationAt(x, y);
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

  Vector2 _screenFor(double x, double y, [int elevation = 0]) =>
      projection.worldToScreen(Vector2(x, y)) -
      Vector2(0, elevation * elevationStepPixels);

  void _updateDecorationOcclusion(double dt) {
    final playerElevation = worldDocument.elevationAt(
      player.position.x.round(),
      player.position.y.round(),
    );
    final playerFeet = _screenFor(
      player.position.x,
      player.position.y,
      playerElevation,
    );
    final playerBounds = Rect.fromLTWH(
      playerFeet.x - 25,
      playerFeet.y - 100,
      50,
      102,
    );
    final playerDepth = _depthAt(
      player.position.x,
      player.position.y,
      playerElevation,
    );
    final blend = 1 - math.exp(-10 * dt);

    for (final entry in worldDocument.decorations.entries) {
      final cell = entry.key;
      final profile = _occlusionProfile(entry.value.type);
      if (profile == null) continue;
      final elevation = worldDocument.elevationAt(cell.x, cell.y);
      final decorationDepth = _depthAt(
        cell.x.toDouble(),
        cell.y.toDouble(),
        elevation,
      );
      final isInFront =
          decorationDepth > playerDepth + 0.001 ||
          ((decorationDepth - playerDepth).abs() <= 0.001 &&
              cell.x > player.position.x);
      final center = _screenFor(
        cell.x.toDouble(),
        cell.y.toDouble(),
        elevation,
      );
      final occlusionBounds = Rect.fromCenter(
        center: Offset(center.x, center.y + profile.offsetY),
        width: profile.width,
        height: profile.height,
      );
      final target = isInFront && occlusionBounds.overlaps(playerBounds)
          ? 0.35
          : 1.0;
      final current = _decorationOpacity[cell] ?? 1.0;
      final next = current + (target - current) * blend;
      if (target == 1 && (1 - next).abs() < 0.005) {
        _decorationOpacity.remove(cell);
      } else {
        _decorationOpacity[cell] = next;
      }
    }
  }

  _OcclusionProfile? _occlusionProfile(DecorationType decoration) =>
      switch (decoration) {
        DecorationType.roundTree => const _OcclusionProfile(
          width: 200,
          height: 190,
          offsetY: -95,
        ),
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
        DecorationType.ruralTreeC3 => const _OcclusionProfile(
          width: 200,
          height: 360,
          offsetY: -180,
        ),
        DecorationType.wideTree => const _OcclusionProfile(
          width: 248,
          height: 180,
          offsetY: -90,
        ),
        DecorationType.bush => const _OcclusionProfile(
          width: 130,
          height: 74,
          offsetY: -30,
        ),
        DecorationType.stoneWell => const _OcclusionProfile(
          width: 145,
          height: 110,
          offsetY: -48,
        ),
        DecorationType.woodenSign => const _OcclusionProfile(
          width: 84,
          height: 100,
          offsetY: -45,
        ),
        _ => null,
      };

  void _advancePlayerPath() {
    if (player.isMoving) return;
    if (_playerPath.isEmpty) {
      _moveDestination = null;
      return;
    }
    final next = _playerPath.removeAt(0);
    player.moveTo(Vector2(next.x.toDouble(), next.y.toDouble()));
  }

  List<CellCoordinate>? _findPath(
    CellCoordinate start,
    CellCoordinate destination,
  ) {
    if (!worldDocument.containsCell(destination.x, destination.y)) return null;
    final queue = <CellCoordinate>[start];
    final previous = <CellCoordinate, CellCoordinate?>{start: null};
    const steps = [
      CellCoordinate(-1, 0),
      CellCoordinate(1, 0),
      CellCoordinate(0, -1),
      CellCoordinate(0, 1),
      CellCoordinate(-1, -1),
      CellCoordinate(1, -1),
      CellCoordinate(-1, 1),
      CellCoordinate(1, 1),
    ];
    for (var index = 0; index < queue.length; index++) {
      final current = queue[index];
      if (current == destination) break;
      for (final step in steps) {
        final next = CellCoordinate(current.x + step.x, current.y + step.y);
        if (previous.containsKey(next) ||
            !_canTraversePathStep(current, next)) {
          continue;
        }
        previous[next] = current;
        queue.add(next);
      }
    }
    if (!previous.containsKey(destination)) return null;
    final reversed = <CellCoordinate>[];
    CellCoordinate? current = destination;
    while (current != null) {
      reversed.add(current);
      current = previous[current];
    }
    return reversed.reversed.toList();
  }

  bool _canTraversePathStep(CellCoordinate from, CellCoordinate to) {
    if (!worldDocument.canTraverse(from, to) ||
        hasElevationCliffAt(worldDocument, to.x, to.y)) {
      return false;
    }
    final dx = to.x - from.x;
    final dy = to.y - from.y;
    if (dx == 0 || dy == 0) return true;

    // A diagonal is valid only when both adjoining cardinal cells are open;
    // this prevents slipping through a cliff or obstacle corner.
    final acrossX = CellCoordinate(from.x + dx, from.y);
    final acrossY = CellCoordinate(from.x, from.y + dy);
    return worldDocument.canTraverse(from, acrossX) &&
        worldDocument.canTraverse(from, acrossY) &&
        !hasElevationCliffAt(worldDocument, acrossX.x, acrossX.y) &&
        !hasElevationCliffAt(worldDocument, acrossY.x, acrossY.y);
  }

  bool _isNearViewport(Vector2 point) {
    final halfVisibleWidth = size.x / (2 * worldZoom);
    final halfVisibleHeight = size.y / (2 * worldZoom);
    final left = size.x / 2 - halfVisibleWidth;
    final top = size.y / 2 - halfVisibleHeight;
    final right = size.x / 2 + halfVisibleWidth;
    final bottom = size.y / 2 + halfVisibleHeight;
    return point.x > left - 128 &&
        point.y > top - 48 &&
        point.x < right + 128 &&
        point.y < bottom + 208;
  }

  void _drawTarget(Canvas canvas, Vector2 center) {
    final rect = Rect.fromCenter(
      center: Offset(center.x, center.y),
      width: projection.tileWidth * 0.52,
      height: projection.tileHeight * 0.52,
    );
    canvas.drawOval(rect, _targetPaint);
  }

  void _drawPlayer(Canvas canvas, Vector2 feet) {
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(feet.x, feet.y + 3),
        width: 27,
        height: 10,
      ),
      Paint()..color = const Color(0x52000000),
    );
    _playerSprites.render(canvas, feet, player);
  }

  void _drawSheep(Canvas canvas, Vector2 feet, Animal animal) {
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(feet.x, feet.y + 3),
        width: 32,
        height: 12,
      ),
      Paint()..color = const Color(0x52000000),
    );
    _sheepSprites.render(canvas, feet, animal);
  }

  double _depthAt(double x, double y, int elevation) => x + y - elevation * 2;

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

  Future<Map<String, Map<TileRotation, Image>>> _loadTileLayerImages() async {
    final assetIds = {
      for (final layers in worldDocument.tileLayers.values)
        for (final layer in layers) layer.assetId,
      if (worldDocument.elevations.isNotEmpty) ...earthElevationAssetIds,
    };
    final catalogItems = assetIds
        .map(groundCatalog.itemById)
        .whereType<GroundCatalogItem>()
        .toList();
    final paths = [
      for (final item in catalogItems)
        for (final rotation in TileRotation.values)
          item.assetForKey(rotation.name[0]),
    ];
    final loaded = await images.loadAll(paths);
    var index = 0;
    return {
      for (final item in catalogItems)
        item.id: {
          for (final rotation in TileRotation.values) rotation: loaded[index++],
        },
    };
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

class _OcclusionProfile {
  const _OcclusionProfile({
    required this.width,
    required this.height,
    this.offsetY = 0,
  });

  final double width;
  final double height;
  final double offsetY;
}
