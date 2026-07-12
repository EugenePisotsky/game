import 'dart:async';
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
import 'package:neura_rendering/neura_rendering.dart';
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
  final Map<EnvironmentChunkCoordinate, ui.Picture> _terrainPictures = {};

  late EnvironmentDocument document;
  late final EnvironmentWorldManifest worldManifest;
  late final EnvironmentChunkStreamingManager chunkStreamer;
  late final EnvironmentCatalog environmentCatalog;
  late final CharacterCatalog characterCatalog;
  late NavigationGrid navigationGrid;
  EnvironmentChunkCoordinate? _streamingCenter;

  final List<Vector2> _movementWaypoints = [];
  Vector2? _destination;
  EnvironmentDirection _facing = EnvironmentDirection.north;
  String _characterId = 'other_worlds.male_1';
  double _animationTime = 0;
  double zoom = 0.9;
  bool showChunkDebug = false;

  static const double playerSpeedPixelsPerSecond = 210;
  static const double elevationPixelsPerWorldUnit = 64;
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
  int get loadedChunkCount => chunkStreamer.loadedChunks.length;
  int get loadedEnvironmentAssetCount =>
      chunkStreamer.assetReferenceCounts.length;
  EnvironmentChunkCoordinate? get currentChunk => _streamingCenter;
  int get preloadingChunkCount => chunkStreamer.preloadingChunks.length;
  int get pendingUnloadChunkCount => chunkStreamer.pendingUnloadChunks.length;

  void toggleChunkDebug() => showChunkDebug = !showChunkDebug;

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
    worldManifest = await loadEnvironmentWorldManifest(rootBundle);
    final spawn = worldManifest.playerSpawn.toWorld(worldManifest.chunkSize);
    playerPosition.setValues(spawn.x, spawn.y);
    chunkStreamer = EnvironmentChunkStreamingManager(
      manifest: worldManifest,
      repository: AssetBundleEnvironmentChunkRepository(rootBundle),
      loadRadius: 1,
      unloadRadius: 2,
    );
    await chunkStreamer.updateAround(spawn);
    _streamingCenter = worldManifest.coordinateFor(spawn);
    document = _documentFromLoadedChunks();
    environmentCatalog = EnvironmentCatalog.fromJsonString(
      await rootBundle.loadString(
        'packages/neura_assets/assets/catalogs/environment_catalog.json',
      ),
    );
    environmentCatalog.applyGeometryOverridesFromJsonString(
      await rootBundle.loadString(
        'packages/neura_assets/assets/catalogs/environment_geometry_overrides.json',
      ),
    );
    characterCatalog = CharacterCatalog.fromJsonString(
      await rootBundle.loadString(
        'packages/neura_assets/assets/catalogs/character_catalog.json',
      ),
    );

    final usedMaterialIds = <String>{
      worldManifest.baseMaterialId,
      for (final chunk in chunkStreamer.loadedChunks.values)
        for (final stroke in chunk.terrainStrokes) stroke.materialId,
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
    navigationGrid = NavigationGrid(
      width: worldManifest.width,
      height: worldManifest.height,
      cellSize: 0.4,
      isBlocked: _isPlayerBlocked,
    );
    _synchronizeTerrainPictures();
  }

  EnvironmentDocument _documentFromLoadedChunks() => EnvironmentDocument(
    id: worldManifest.id,
    name: worldManifest.name,
    width: worldManifest.width.ceil(),
    height: worldManifest.height.ceil(),
    baseMaterialId: worldManifest.baseMaterialId,
    objects: [
      for (final chunk in chunkStreamer.loadedChunks.values)
        ...chunk.worldObjects,
    ],
    editorLayers: worldManifest.editorLayers,
    activeLayerId: worldManifest.activeLayerId,
  );

  Future<void> _streamAroundPlayer() async {
    final position = WorldPoint(playerPosition.x, playerPosition.y);
    final coordinate = worldManifest.coordinateFor(position);
    if (_streamingCenter == coordinate) return;
    _streamingCenter = coordinate;
    final changed = await chunkStreamer.updateAround(position);
    if (!changed) return;
    document = _documentFromLoadedChunks();
    await _synchronizeChunkAssets();
    navigationGrid = NavigationGrid(
      width: worldManifest.width,
      height: worldManifest.height,
      cellSize: 0.4,
      isBlocked: _isPlayerBlocked,
    );
  }

  Future<void> _synchronizeChunkAssets() async {
    final loadedCoordinates = chunkStreamer.loadedChunks.keys.toSet();
    final stalePictures = _terrainPictures.keys
        .where((coordinate) => !loadedCoordinates.contains(coordinate))
        .toList();
    for (final coordinate in stalePictures) {
      _terrainPictures.remove(coordinate)?.dispose();
    }
    final materialIds = <String>{
      worldManifest.baseMaterialId,
      for (final chunk in chunkStreamer.loadedChunks.values)
        for (final stroke in chunk.terrainStrokes) stroke.materialId,
    };
    final neededPaths = <String>{
      for (final character in characterCatalog.characters) ...[
        character.idlePath,
        character.walkPath,
      ],
    };
    for (final materialId in materialIds) {
      final material = environmentCatalog.materialById(materialId);
      if (material != null) {
        neededPaths
          ..add(material.texturePath)
          ..add(material.decalPath);
      }
    }
    for (final chunk in chunkStreamer.loadedChunks.values) {
      for (final object in chunk.objects) {
        final asset = environmentCatalog.objectById(object.assetId);
        if (asset != null) {
          neededPaths.add(asset.viewFor(object.direction.name).imagePath);
        }
      }
    }
    final missing = neededPaths.difference(_loadedImages.keys.toSet());
    final loaded = await Future.wait([
      for (final path in missing)
        path.startsWith('environment_generated/')
            ? loadGeneratedEnvironmentImage(path)
            : images.load(path),
    ]);
    for (var index = 0; index < missing.length; index++) {
      _loadedImages[missing.elementAt(index)] = loaded[index];
    }
    final unused = _loadedImages.keys
        .where((path) => !neededPaths.contains(path))
        .toList();
    for (final path in unused) {
      final image = _loadedImages.remove(path);
      if (path.startsWith('environment_generated/')) image?.dispose();
    }
    _repeatingPaints.removeWhere((id, _) => !materialIds.contains(id));
    _decalPaints.removeWhere((id, _) => !materialIds.contains(id));
    for (final materialId in materialIds) {
      final material = environmentCatalog.materialById(materialId);
      if (material == null || _repeatingPaints.containsKey(materialId)) {
        continue;
      }
      final texture = _loadedImages[material.texturePath];
      final decal = _loadedImages[material.decalPath];
      if (texture == null || decal == null) continue;
      _repeatingPaints[materialId] = ui.Paint()
        ..shader = ui.ImageShader(
          texture,
          ui.TileMode.repeated,
          ui.TileMode.repeated,
          _identityMatrix,
        );
      _decalPaints[materialId] = ui.Paint()
        ..shader = ui.ImageShader(
          decal,
          ui.TileMode.clamp,
          ui.TileMode.clamp,
          _identityMatrix,
        );
    }
    _synchronizeTerrainPictures();
  }

  void _synchronizeTerrainPictures() {
    for (final chunk in chunkStreamer.loadedChunks.values) {
      _terrainPictures.putIfAbsent(
        chunk.coordinate,
        () => _buildTerrainPicture(chunk),
      );
    }
  }

  ui.Picture _buildTerrainPicture(EnvironmentChunkDocument chunk) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final originX = chunk.coordinate.x * chunk.size;
    final originY = chunk.coordinate.y * chunk.size;
    final maxX = math.min(worldManifest.width, originX + chunk.size);
    final maxY = math.min(worldManifest.height, originY + chunk.size);
    final corners = [
      projection.worldToScreen(Vector2(originX, originY)),
      projection.worldToScreen(Vector2(maxX, originY)),
      projection.worldToScreen(Vector2(maxX, maxY)),
      projection.worldToScreen(Vector2(originX, maxY)),
    ];
    final clip = ui.Path()..moveTo(corners.first.x, corners.first.y);
    for (final corner in corners.skip(1)) {
      clip.lineTo(corner.x, corner.y);
    }
    canvas.clipPath(clip..close());
    for (final stroke in chunk.terrainStrokes) {
      _renderStroke(
        canvas,
        TerrainStroke(
          materialId: stroke.materialId,
          radius: stroke.radius,
          opacity: stroke.opacity,
          points: [
            for (final point in stroke.points)
              WorldPoint(point.x + originX, point.y + originY),
          ],
        ),
      );
    }
    return recorder.endRecording();
  }

  @override
  void onTapDown(TapDownEvent event) {
    if (!isLoaded) return;
    final projected =
        (event.canvasPosition - size / 2) / zoom + _cameraProjectedPosition;
    final world = projection.screenToWorld(projected);
    final requestedDestination = Vector2(
      world.x.clamp(0.0, document.width.toDouble()),
      world.y.clamp(0.0, document.height.toDouble()),
    );
    final route = navigationGrid.findPath(
      WorldPoint(playerPosition.x, playerPosition.y),
      WorldPoint(requestedDestination.x, requestedDestination.y),
    );
    _movementWaypoints.clear();
    var cursor = playerPosition.clone();
    for (final point in route) {
      final next = Vector2(point.x, point.y);
      _movementWaypoints.addAll(majorDirectionWaypoints(cursor, next));
      cursor = next;
    }
    _destination = _movementWaypoints.isEmpty ? null : cursor;
    _animationTime = 0;
  }

  bool _isPlayerBlocked(WorldPoint point) {
    const playerRadius = 0.18;
    for (final object in document.objects) {
      final asset = environmentCatalog.objectById(object.assetId);
      if (asset != null &&
          environmentObjectBlocksPoint(
            asset,
            object,
            point,
            actorRadius: playerRadius,
            geometry: environmentCatalog.geometryForAsset(asset),
          )) {
        return true;
      }
    }
    return false;
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

    unawaited(_streamAroundPlayer());

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
    _renderChunkTerrain(canvas);
    _renderScene(canvas);
    _renderMapOutline(canvas);
    if (showChunkDebug) _renderChunkDebug(canvas);
    _renderTarget(canvas);
    canvas.restore();
  }

  void _renderBaseGround(ui.Canvas canvas) {
    final material = environmentCatalog.materialById(
      worldManifest.baseMaterialId,
    );
    final paint = _repeatingPaints[worldManifest.baseMaterialId];
    if (material == null || paint == null) return;
    for (final chunk in chunkStreamer.loadedChunks.values) {
      final originX = chunk.coordinate.x * chunk.size;
      final originY = chunk.coordinate.y * chunk.size;
      final maxX = math.min(worldManifest.width, originX + chunk.size);
      final maxY = math.min(worldManifest.height, originY + chunk.size);
      _drawTexturedWorldQuad(
        canvas,
        WorldPoint(originX, originY),
        WorldPoint(maxX, maxY),
        paint,
        ui.Rect.fromLTWH(
          originX * 64,
          originY * 64,
          (maxX - originX) * 64,
          (maxY - originY) * 64,
        ),
      );
    }
  }

  void _renderChunkTerrain(ui.Canvas canvas) {
    for (final coordinate in chunkStreamer.loadedChunks.keys) {
      final picture = _terrainPictures[coordinate];
      if (picture != null) canvas.drawPicture(picture);
    }
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
    _renderObjectBand(canvas, EnvironmentRenderBand.groundCover);

    final entries =
        <_SceneEntry>[
          for (final object in document.objects)
            if (environmentCatalog.objectById(object.assetId)?.renderBand ==
                EnvironmentRenderBand.depthSorted)
              _SceneEntry.object(
                object,
                environmentCatalog
                    .objectById(object.assetId)!
                    .depthAt(
                      object.x,
                      object.y,
                      instanceSortBias: object.sortBias,
                    ),
              ),
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

    _renderObjectBand(canvas, EnvironmentRenderBand.overhead);
    _renderObjectBand(canvas, EnvironmentRenderBand.effects);
  }

  void _renderObjectBand(ui.Canvas canvas, EnvironmentRenderBand band) {
    final objects =
        document.objects.where((object) {
          return environmentCatalog.objectById(object.assetId)?.renderBand ==
              band;
        }).toList()..sort((a, b) {
          final aAsset = environmentCatalog.objectById(a.assetId)!;
          final bAsset = environmentCatalog.objectById(b.assetId)!;
          final depth = aAsset
              .depthAt(a.x, a.y, instanceSortBias: a.sortBias)
              .compareTo(
                bAsset.depthAt(b.x, b.y, instanceSortBias: b.sortBias),
              );
          return depth != 0 ? depth : a.x.compareTo(b.x);
        });
    for (final object in objects) {
      _renderObject(canvas, object);
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
      position: projection.worldToScreen(Vector2(object.x, object.y))
        ..y -= object.verticalOffset * elevationPixelsPerWorldUnit,
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

  void _renderChunkDebug(ui.Canvas canvas) {
    final loadedPaint = ui.Paint()
      ..color = const ui.Color(0xDD58D68D)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2;
    final pendingPaint = ui.Paint()
      ..color = const ui.Color(0xDDE9C46A)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final coordinate in chunkStreamer.loadedChunks.keys) {
      final originX = coordinate.x * worldManifest.chunkSize;
      final originY = coordinate.y * worldManifest.chunkSize;
      final points = [
        projection.worldToScreen(Vector2(originX, originY)),
        projection.worldToScreen(
          Vector2(originX + worldManifest.chunkSize, originY),
        ),
        projection.worldToScreen(
          Vector2(
            originX + worldManifest.chunkSize,
            originY + worldManifest.chunkSize,
          ),
        ),
        projection.worldToScreen(
          Vector2(originX, originY + worldManifest.chunkSize),
        ),
      ];
      final path = ui.Path()..moveTo(points.first.x, points.first.y);
      for (final point in points.skip(1)) {
        path.lineTo(point.x, point.y);
      }
      canvas.drawPath(
        path..close(),
        chunkStreamer.pendingUnloadChunks.contains(coordinate)
            ? pendingPaint
            : loadedPaint,
      );
    }
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
