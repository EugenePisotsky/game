import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/cache.dart';
import 'package:flame/components.dart' show Anchor, FpsComponent;
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/sprite.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

/// Small playable proof that the painted environment and modular Other Worlds
/// character sheets share one coherent isometric space.
class NeuraGame extends FlameGame
    with TapCallbacks, KeyboardEvents, HasPerformanceTracker {
  NeuraGame({this.debugSceneName}) {
    images = Images(prefix: neuraAssetPrefix);
  }

  final String? debugSceneName;

  final IsometricProjection projection = const IsometricProjection();
  final Vector2 playerPosition = Vector2(12, 20.5);
  final Map<String, ui.Image> _loadedImages = {};
  final LinkedHashMap<String, ui.Image> _inactiveEnvironmentImages =
      LinkedHashMap();
  final Map<String, ui.Paint> _repeatingPaints = {};
  final Map<String, ui.Paint> _decalPaints = {};
  final Map<String, _CharacterImages> _characterImages = {};
  final Map<EnvironmentChunkCoordinate, ui.Picture> _terrainPictures = {};
  final FpsComponent _fpsComponent = FpsComponent(windowSize: 60);

  late EnvironmentDocument document;
  late final EnvironmentWorldManifest worldManifest;
  late final EnvironmentChunkStreamingManager chunkStreamer;
  late final EnvironmentCatalog environmentCatalog;
  late final CharacterCatalog characterCatalog;
  late final math.Random _movementRandom;
  late NavigationGrid navigationGrid;
  EnvironmentDebugScene? debugScene;
  EnvironmentChunkCoordinate? _streamingCenter;

  final List<Vector2> _movementWaypoints = [];
  final Queue<EnvironmentDirection> _turnDirections = Queue();
  Vector2? _destination;
  EnvironmentDirection _facing = EnvironmentDirection.north;
  String _characterId = 'other_worlds.male_1';
  double _animationTime = 0;
  double _turnStepRemaining = 0;
  double zoom = 0.9;
  bool showDiagnostics = true;
  bool showRenderDebug = false;
  bool showGeometryDebug = false;
  bool showChunkDebug = false;
  bool showNavigationDebug = false;
  bool diagnosticsPaused = false;
  int _assetCacheHits = 0;
  int _assetCacheMisses = 0;
  int _assetCacheEvictions = 0;
  int _pendingAssetRequests = 0;

  static const double playerSpeedPixelsPerSecond = 210;
  static const double elevationPixelsPerWorldUnit = 64;
  static const double _walkFramesPerSecond = 10;
  static const double _idleFramesPerSecond = 5;
  static const double _turnStepSeconds = 0.065;
  static const int _maxInactiveAssetEntries = 24;
  static const int _maxInactiveAssetBytes = 32 << 20;

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
  Vector2 get cameraPosition => playerPosition.clone();
  EnvironmentDirection get facing => _facing;
  bool get isTurning => _turnDirections.isNotEmpty;
  double get animationTime => _animationTime;
  List<Vector2> get movementWaypoints => [
    for (final waypoint in _movementWaypoints) waypoint.clone(),
  ];
  int get loadedChunkCount => chunkStreamer.loadedChunks.length;
  int get loadedEnvironmentAssetCount =>
      chunkStreamer.assetReferenceCounts.length;
  EnvironmentChunkCoordinate? get currentChunk => _streamingCenter;
  int get preloadingChunkCount => chunkStreamer.preloadingChunks.length;
  int get pendingUnloadChunkCount => chunkStreamer.pendingUnloadChunks.length;
  int get decodedImageCount =>
      _loadedImages.length + _inactiveEnvironmentImages.length;
  int get decodedImageBytes => [
    ..._loadedImages.values,
    ..._inactiveEnvironmentImages.values,
  ].fold(0, (sum, image) => sum + _estimatedImageBytes(image));
  int get inactiveAssetCount => _inactiveEnvironmentImages.length;
  int get inactiveAssetBytes => _inactiveEnvironmentImages.values.fold(
    0,
    (sum, image) => sum + _estimatedImageBytes(image),
  );
  int get assetCacheHits => _assetCacheHits;
  int get assetCacheMisses => _assetCacheMisses;
  int get assetCacheEvictions => _assetCacheEvictions;
  int get pendingAssetRequests => _pendingAssetRequests;
  int get cancelledChunkRequests => chunkStreamer.cancelledRequestCount;
  int get currentPathLength => _movementWaypoints.length;
  int get navigationExpandedNodes => navigationGrid.lastExpandedNodeCount;
  int get terrainPictureCount => _terrainPictures.length;
  int? get debugRandomSeed => debugScene?.randomSeed;
  double get diagnosticsFps => _fpsComponent.fps;
  double get diagnosticsFrameMilliseconds =>
      diagnosticsFps <= 0 ? 0 : 1000 / diagnosticsFps;
  List<String> get debugRenderOrder => [
    for (final object in _objectsInBand(EnvironmentRenderBand.groundCover))
      object.id,
    for (final entry in _depthSortedSceneEntries())
      entry.object?.id ?? 'player',
    for (final object in _objectsInBand(EnvironmentRenderBand.overhead))
      object.id,
    for (final object in _objectsInBand(EnvironmentRenderBand.effects))
      object.id,
  ];

  void toggleChunkDebug() => showChunkDebug = !showChunkDebug;

  void togglePause() {
    diagnosticsPaused = !diagnosticsPaused;
    diagnosticsPaused ? pauseEngine() : resumeEngine();
  }

  void stepDebug() {
    if (diagnosticsPaused) update(1 / 60);
  }

  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.f1:
        showDiagnostics = !showDiagnostics;
      case LogicalKeyboardKey.f2:
        showRenderDebug = !showRenderDebug;
      case LogicalKeyboardKey.f3:
        showGeometryDebug = !showGeometryDebug;
      case LogicalKeyboardKey.f4:
        showChunkDebug = !showChunkDebug;
      case LogicalKeyboardKey.f5:
        showNavigationDebug = !showNavigationDebug;
      case LogicalKeyboardKey.keyP:
        togglePause();
      case LogicalKeyboardKey.period:
        stepDebug();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void setCharacter(String id) {
    if (_characterImages.containsKey(id)) {
      _characterId = id;
      _animationTime = 0;
    }
  }

  Future<void> teleportTo(WorldPoint point) async {
    playerPosition.setValues(
      point.x.clamp(0, worldManifest.width),
      point.y.clamp(0, worldManifest.height),
    );
    _movementWaypoints.clear();
    _turnDirections.clear();
    _turnStepRemaining = 0;
    _destination = null;
    _streamingCenter = null;
    await _streamAroundPlayer();
  }

  @override
  ui.Color backgroundColor() => const ui.Color(0xFF101713);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await add(_fpsComponent);
    final requestedDebugScene = debugSceneName;
    if (requestedDebugScene != null) {
      debugScene = await loadEnvironmentDebugScene(
        rootBundle,
        requestedDebugScene,
      );
    }
    _movementRandom = math.Random(debugScene?.randomSeed);
    worldManifest = await loadReleaseEnvironmentWorldManifest(rootBundle);
    final spawn =
        debugScene?.player ??
        worldManifest.playerSpawn.toWorld(worldManifest.chunkSize);
    playerPosition.setValues(spawn.x, spawn.y);
    if (debugScene case final scene?) {
      _facing = EnvironmentDirection.values.byName(scene.facing);
      _animationTime = scene.clockSeconds;
    }
    chunkStreamer = EnvironmentChunkStreamingManager(
      manifest: worldManifest,
      repository: AssetBundleEnvironmentChunkRepository.release(rootBundle),
      loadRadius: 1,
      unloadRadius: 2,
    );
    await chunkStreamer.updateAround(spawn);
    _streamingCenter = worldManifest.coordinateFor(spawn);
    document = _documentFromLoadedChunks();
    environmentCatalog = EnvironmentCatalog.fromJsonString(
      await rootBundle.loadString(environmentReleaseCatalogAsset),
    );
    environmentCatalog.applyGeometryOverridesFromJsonString(
      await rootBundle.loadString(environmentReleaseGeometryOverridesAsset),
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
    await _ensureRuntimeImages(paths);

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
    if (debugScene != null) {
      diagnosticsPaused = true;
      pauseEngine();
    }
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
    await _ensureRuntimeImages(neededPaths);
    final unused = _loadedImages.keys
        .where((path) => !neededPaths.contains(path))
        .toList();
    for (final path in unused) {
      final image = _loadedImages.remove(path);
      if (path.startsWith('images/') && image != null) {
        _inactiveEnvironmentImages[path] = image;
      }
    }
    _trimInactiveAssetCache();
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

  Future<ui.Image> _loadRuntimeImage(String path) => path.startsWith('images/')
      ? loadReleaseEnvironmentImage(rootBundle, path)
      : images.load(path);

  Future<void> _ensureRuntimeImages(Iterable<String> paths) async {
    final missing = <String>[];
    for (final path in paths) {
      if (_loadedImages.containsKey(path)) continue;
      final cached = _inactiveEnvironmentImages.remove(path);
      if (cached != null) {
        _loadedImages[path] = cached;
        _assetCacheHits++;
      } else {
        missing.add(path);
      }
    }
    if (missing.isEmpty) return;
    _assetCacheMisses += missing.length;
    _pendingAssetRequests += missing.length;
    try {
      final loaded = await Future.wait([
        for (final path in missing) _loadRuntimeImage(path),
      ]);
      for (var index = 0; index < missing.length; index++) {
        _loadedImages[missing[index]] = loaded[index];
      }
    } finally {
      _pendingAssetRequests -= missing.length;
    }
  }

  void _trimInactiveAssetCache() {
    var bytes = _inactiveEnvironmentImages.values.fold(
      0,
      (sum, image) => sum + _estimatedImageBytes(image),
    );
    while (_inactiveEnvironmentImages.length > _maxInactiveAssetEntries ||
        bytes > _maxInactiveAssetBytes) {
      final path = _inactiveEnvironmentImages.keys.first;
      final image = _inactiveEnvironmentImages.remove(path)!;
      bytes -= _estimatedImageBytes(image);
      image.dispose();
      _assetCacheEvictions++;
    }
  }

  static int _estimatedImageBytes(ui.Image image) =>
      image.width * image.height * 4;

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
    requestMovement(
      WorldPoint(
        world.x.clamp(0.0, document.width.toDouble()),
        world.y.clamp(0.0, document.height.toDouble()),
      ),
    );
  }

  bool requestMovement(WorldPoint requested) {
    if (!isLoaded) return false;
    final wasMoving = isMoving;
    final requestedDestination = WorldPoint(
      requested.x.clamp(0.0, document.width.toDouble()),
      requested.y.clamp(0.0, document.height.toDouble()),
    );
    final route = navigationGrid.findPath(
      WorldPoint(playerPosition.x, playerPosition.y),
      requestedDestination,
    );
    _movementWaypoints
      ..clear()
      ..addAll(
        directionAlignedWaypoints(
          playerPosition,
          [for (final point in route) Vector2(point.x, point.y)],
          initialFacing: _facing,
          turnRandom: _movementRandom,
          isWalkable: (start, end) => navigationGrid.isSegmentWalkable(
            WorldPoint(start.x, start.y),
            WorldPoint(end.x, end.y),
          ),
        ),
      );
    if (_movementWaypoints.isEmpty) {
      _destination = null;
      _turnDirections.clear();
      _turnStepRemaining = 0;
      return false;
    }

    var cursor = playerPosition.clone();
    for (final waypoint in _movementWaypoints) {
      cursor = waypoint;
    }
    _destination = cursor.clone();
    if (!wasMoving) _animationTime = 0;
    _beginFacingChange(
      directionForWorldDelta(_movementWaypoints.first - playerPosition),
    );
    return true;
  }

  void _beginFacingChange(EnvironmentDirection target) {
    _turnDirections.clear();
    _turnStepRemaining = 0;
    final turn = shortestDirectionTurn(_facing, target);
    if (turn.isEmpty) return;
    if (turn.length == 1) {
      _facing = target;
      return;
    }
    _facing = turn.first;
    _turnDirections.addAll(turn.skip(1));
    _turnStepRemaining = _turnStepSeconds;
  }

  double _consumeFacingChange(double seconds) {
    var remaining = seconds;
    while (_turnDirections.isNotEmpty) {
      if (remaining < _turnStepRemaining) {
        _turnStepRemaining -= remaining;
        return 0;
      }
      remaining -= _turnStepRemaining;
      _facing = _turnDirections.removeFirst();
      if (_turnDirections.isEmpty) {
        _turnStepRemaining = 0;
        return remaining;
      }
      _turnStepRemaining = _turnStepSeconds;
    }
    return remaining;
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

    var remainingSeconds = dt;
    while (_movementWaypoints.isNotEmpty && remainingSeconds > 0) {
      final waypoint = _movementWaypoints.first;
      final delta = waypoint - playerPosition;
      final projectedDistance = projection.worldToScreen(delta).length;
      if (projectedDistance <= 0.01) {
        playerPosition.setFrom(waypoint);
        _movementWaypoints.removeAt(0);
        continue;
      }

      final desiredFacing = directionForWorldDelta(delta);
      if (!isTurning && desiredFacing != _facing) {
        _beginFacingChange(desiredFacing);
      }
      if (isTurning) {
        remainingSeconds = _consumeFacingChange(remainingSeconds);
        if (remainingSeconds <= 0) break;
      }

      final remainingPixels = playerSpeedPixelsPerSecond * remainingSeconds;
      if (remainingPixels >= projectedDistance) {
        playerPosition.setFrom(waypoint);
        _movementWaypoints.removeAt(0);
        remainingSeconds -= projectedDistance / playerSpeedPixelsPerSecond;
      } else {
        playerPosition.add(delta * (remainingPixels / projectedDistance));
        remainingSeconds = 0;
      }
    }

    unawaited(_streamAroundPlayer());

    if (_movementWaypoints.isEmpty) {
      _destination = null;
      _turnDirections.clear();
      _turnStepRemaining = 0;
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
    if (showRenderDebug) _renderDepthDebug(canvas);
    if (showGeometryDebug) _renderGeometryDebug(canvas);
    if (showChunkDebug) _renderChunkDebug(canvas);
    if (showNavigationDebug) _renderNavigationDebug(canvas);
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

    for (final entry in _depthSortedSceneEntries()) {
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
    for (final object in _objectsInBand(band)) {
      _renderObject(canvas, object);
    }
  }

  List<PlacedEnvironmentObject> _objectsInBand(EnvironmentRenderBand band) =>
      document.objects.where((object) {
        return environmentCatalog.objectById(object.assetId)?.renderBand ==
            band;
      }).toList()..sort((a, b) {
        final aAsset = environmentCatalog.objectById(a.assetId)!;
        final bAsset = environmentCatalog.objectById(b.assetId)!;
        final depth = aAsset
            .depthAt(a.x, a.y, instanceSortBias: a.sortBias)
            .compareTo(bAsset.depthAt(b.x, b.y, instanceSortBias: b.sortBias));
        return depth != 0 ? depth : a.x.compareTo(b.x);
      });

  List<_SceneEntry> _depthSortedSceneEntries() =>
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
    final moving = isMoving && !isTurning;
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

  void _renderDepthDebug(ui.Canvas canvas) {
    final anchorPaint = ui.Paint()..color = const ui.Color(0xFFE9C46A);
    for (final object in document.objects) {
      final asset = environmentCatalog.objectById(object.assetId);
      if (asset == null) continue;
      final anchor = projection.worldToScreen(
        Vector2(object.x + asset.sortAnchorX, object.y + asset.sortAnchorY),
      );
      canvas.drawCircle(anchor.toOffset(), 4 / zoom, anchorPaint);
      _drawDebugLabel(
        canvas,
        '${asset.renderBand.name} ${(asset.depthAt(object.x, object.y, instanceSortBias: object.sortBias)).toStringAsFixed(2)}',
        anchor.toOffset() + ui.Offset(7 / zoom, -7 / zoom),
        const ui.Color(0xFFE9C46A),
      );
    }
    final player = projection.worldToScreen(playerPosition);
    canvas.drawCircle(
      player.toOffset(),
      5 / zoom,
      ui.Paint()..color = const ui.Color(0xFF71C4FF),
    );
    _drawDebugLabel(
      canvas,
      'actor ${(playerPosition.x + playerPosition.y).toStringAsFixed(2)}',
      player.toOffset() + ui.Offset(8 / zoom, -8 / zoom),
      const ui.Color(0xFF71C4FF),
    );
  }

  void _renderGeometryDebug(ui.Canvas canvas) {
    final footprintPaint = ui.Paint()
      ..color = const ui.Color(0xDD4EA8DE)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2 / zoom;
    final blockingPaint = ui.Paint()
      ..color = const ui.Color(0xDDE76F51)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2.5 / zoom;
    final walkablePaint = ui.Paint()
      ..color = const ui.Color(0xDD6FCF97)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2 / zoom;
    final selectionPaint = ui.Paint()
      ..color = const ui.Color(0xDDB987FF)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.5 / zoom;
    for (final object in document.objects) {
      final asset = environmentCatalog.objectById(object.assetId);
      if (asset == null) continue;
      final geometry = environmentCatalog.geometryForAsset(asset);
      if (geometry.footprint case final footprint?) {
        _drawWorldShape(canvas, footprint, object, footprintPaint);
      }
      for (final shape in geometry.blocking) {
        _drawWorldShape(canvas, shape, object, blockingPaint);
      }
      for (final shape in geometry.walkable) {
        _drawWorldShape(canvas, shape, object, walkablePaint);
      }
      for (final shape in geometry.selection) {
        _drawWorldShape(canvas, shape, object, selectionPaint);
      }
    }
  }

  void _drawWorldShape(
    ui.Canvas canvas,
    EnvironmentGeometryShape shape,
    PlacedEnvironmentObject object,
    ui.Paint paint,
  ) {
    final points = environmentShapeOutline(shape, object);
    if (points.isEmpty) return;
    final first = projection.worldToScreen(
      Vector2(points.first.x, points.first.y),
    );
    final path = ui.Path()..moveTo(first.x, first.y);
    for (final point in points.skip(1)) {
      final projected = projection.worldToScreen(Vector2(point.x, point.y));
      path.lineTo(projected.x, projected.y);
    }
    canvas.drawPath(path..close(), paint);
  }

  void _renderNavigationDebug(ui.Canvas canvas) {
    final blockedPaint = ui.Paint()..color = const ui.Color(0x55E76F51);
    final pathPaint = ui.Paint()
      ..color = const ui.Color(0xFF71C4FF)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 3 / zoom;
    final cell = navigationGrid.cellSize;
    final minX = math.max(0.0, playerPosition.x - 5);
    final maxX = math.min(worldManifest.width, playerPosition.x + 5);
    final minY = math.max(0.0, playerPosition.y - 5);
    final maxY = math.min(worldManifest.height, playerPosition.y + 5);
    for (var y = minY; y <= maxY; y += cell) {
      for (var x = minX; x <= maxX; x += cell) {
        final point = WorldPoint(x + cell / 2, y + cell / 2);
        if (!_isPlayerBlocked(point)) continue;
        final center = projection.worldToScreen(Vector2(point.x, point.y));
        canvas.drawCircle(center.toOffset(), 2.2 / zoom, blockedPaint);
      }
    }
    final pathPoints = <Vector2>[
      playerPosition,
      ..._movementWaypoints,
    ].map(projection.worldToScreen).toList();
    if (pathPoints.length > 1) {
      final path = ui.Path()..moveTo(pathPoints.first.x, pathPoints.first.y);
      for (final point in pathPoints.skip(1)) {
        path.lineTo(point.x, point.y);
      }
      canvas.drawPath(path, pathPaint);
    }
  }

  void _drawDebugLabel(
    ui.Canvas canvas,
    String text,
    ui.Offset offset,
    ui.Color color,
  ) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 10 / zoom))
      ..pushStyle(ui.TextStyle(color: color));
    builder.addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: 180 / zoom));
    canvas.drawParagraph(paragraph, offset);
  }

  @override
  void onRemove() {
    for (final picture in _terrainPictures.values) {
      picture.dispose();
    }
    _terrainPictures.clear();
    for (final entry in _loadedImages.entries) {
      if (entry.key.startsWith('images/')) entry.value.dispose();
    }
    for (final image in _inactiveEnvironmentImages.values) {
      image.dispose();
    }
    _inactiveEnvironmentImages.clear();
    super.onRemove();
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
