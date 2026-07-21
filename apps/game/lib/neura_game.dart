import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/cache.dart';
import 'package:flame/components.dart' show FpsComponent;
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

import 'native_navigation_adapter.dart';

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
  final Map<String, _ActiveAnimal> _animalStatesById = {};
  final Map<String, NavigationGrid> _animalNavigationBySurface = {};
  final Map<String, PlacedEnvironmentObject> _loadedAnimalHomesById = {};
  final Map<String, EnvironmentSurfaceSample> _objectSurfacesById = {};
  final Map<String, String> _objectDepthSurfaceIdsById = {};
  final Map<String, ui.Path> _liquidOcclusionPathsById = {};
  final Set<String> _objectsWithoutLiquidOcclusionPath = {};
  final Set<String> _activeAnimalIds = {};
  final Map<EnvironmentChunkCoordinate, ui.Picture> _terrainPictures = {};
  final Map<EnvironmentRenderBand, List<PlacedEnvironmentObject>>
  _objectsByRenderBand = {};
  List<EnvironmentDepthEntity<_SceneEntry>> _staticDepthOrder = const [];
  final Map<String, List<EnvironmentDepthEntity<_SceneEntry>>>
  _staticDepthOrderBySurface = {};
  final FpsComponent _fpsComponent = FpsComponent(windowSize: 60);

  late EnvironmentDocument document;
  late final EnvironmentWorldManifest worldManifest;
  late final EnvironmentChunkStreamingManager chunkStreamer;
  late final EnvironmentCatalog environmentCatalog;
  late final CharacterCatalog characterCatalog;
  late final math.Random _movementRandom;
  late NavigationGrid navigationGrid;
  RustNavigationWorld? _nativeNavigationWorld;
  EnvironmentDebugScene? debugScene;
  EnvironmentChunkCoordinate? _streamingCenter;
  String _playerSurfaceId = environmentBaseSurfaceId;
  String? _latchedConnectorId;

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
  int _navigationRequestSerial = 0;
  int _pendingNavigationRequests = 0;
  int _lastNavigationMicros = 0;
  int _sceneDepthCacheBuildCount = 0;
  double _animalActivationClock = 0;
  Future<void>? _navigationRefresh;

  static const double playerSpeedPixelsPerSecond = 210;
  static const double elevationPixelsPerWorldUnit = 64;
  static const double _walkFramesPerSecond = 10;
  static const double _idleFramesPerSecond = 5;
  static const double _turnStepSeconds = 0.065;
  static const int _maxInactiveAssetEntries = 24;
  static const int _maxInactiveAssetBytes = 32 << 20;
  static const double _animalActivationRadius = 36;
  static const double _animalDeactivationRadius = 42;
  static const double _maximumWalkableElevationSlope = 0.75;
  static const double _liquidOpticalDepthScale = 1.25;

  static double _liquidOpticalDepth(double depth) =>
      1 - math.exp(-math.max(0, depth) / _liquidOpticalDepthScale);

  EnvironmentSurfaceSample _surfaceAt(Vector2 point, {String? surfaceId}) =>
      environmentSurfaceAtPoint(
        document,
        WorldPoint(point.x, point.y),
        preferredSurfaceId: surfaceId,
      );

  double _groundElevationAt(Vector2 point, {String? surfaceId}) => _surfaceAt(
    point,
    surfaceId: surfaceId ?? _playerSurfaceId,
  ).groundElevation;

  double _visibleSurfaceElevationAt(Vector2 point) {
    final surface = _surfaceAt(point, surfaceId: _playerSurfaceId);
    return surface.liquidSurfaceElevation ?? surface.groundElevation;
  }

  Vector2 _projectAtElevation(Vector2 point, double elevation) =>
      projection.worldToScreen(point)
        ..y -= elevation * elevationPixelsPerWorldUnit;

  double _surfaceElevationAt(String surfaceId, WorldPoint point) =>
      document.surfaceById(surfaceId)?.elevationAt(point) ?? 0;

  Vector2 _projectGround(Vector2 point, {String? surfaceId}) =>
      _projectAtElevation(
        point,
        _groundElevationAt(point, surfaceId: surfaceId),
      );

  Vector2 _screenToVisibleSurface(Vector2 projected) {
    var elevation = _visibleSurfaceElevationAt(playerPosition);
    var world = projection.screenToWorld(
      projected + Vector2(0, elevation * elevationPixelsPerWorldUnit),
    );
    for (var iteration = 0; iteration < 3; iteration++) {
      elevation = _visibleSurfaceElevationAt(world);
      world = projection.screenToWorld(
        projected + Vector2(0, elevation * elevationPixelsPerWorldUnit),
      );
    }
    return world;
  }

  final ui.Paint _targetPaint = ui.Paint()
    ..color = const ui.Color(0xFFEACB73)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _mapOutlinePaint = ui.Paint()
    ..color = const ui.Color(0x338DA596)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final ui.Paint _navigationBlockedPaint = ui.Paint()
    ..color = const ui.Color(0x55E76F51);
  final ui.Paint _navigationPathPaint = ui.Paint()
    ..color = const ui.Color(0xFF71C4FF)
    ..style = ui.PaintingStyle.stroke;
  final ui.Paint _terrainResetPaint = ui.Paint()
    ..blendMode = ui.BlendMode.clear;

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
  int get pendingNavigationRequests => _pendingNavigationRequests;
  int get lastNavigationMicros => _lastNavigationMicros;
  int get terrainPictureCount => _terrainPictures.length;
  int get sceneDepthCacheBuildCount => _sceneDepthCacheBuildCount;
  int get depthSortedObjectCount => _staticDepthOrder.length;
  int get activeAnimalCount => _activeAnimalIds.length;
  int get knownAnimalCount => _animalStatesById.length;
  String get playerSurfaceId => _playerSurfaceId;
  int? get debugRandomSeed => debugScene?.randomSeed;
  double get diagnosticsFps => _fpsComponent.fps;
  double get diagnosticsFrameMilliseconds =>
      diagnosticsFps <= 0 ? 0 : 1000 / diagnosticsFps;
  List<String> get debugRenderOrder => [
    for (final surface in _orderedSurfaces()) ...[
      for (final object in _objectsInBand(
        EnvironmentRenderBand.groundCover,
        surfaceId: surface.id,
      ))
        object.id,
      for (final entry in _depthSortedSceneEntries(surface.id)) entry.debugId,
      for (final object in _objectsInBand(
        EnvironmentRenderBand.overhead,
        surfaceId: surface.id,
      ))
        object.id,
      for (final object in _objectsInBand(
        EnvironmentRenderBand.effects,
        surfaceId: surface.id,
      ))
        object.id,
    ],
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
    _navigationRequestSerial++;
    playerPosition.setValues(
      point.x.clamp(0, worldManifest.width),
      point.y.clamp(0, worldManifest.height),
    );
    _movementWaypoints.clear();
    _turnDirections.clear();
    _turnStepRemaining = 0;
    _destination = null;
    _latchedConnectorId = null;
    _streamingCenter = null;
    await _streamAroundPlayer();
  }

  @override
  ui.Color backgroundColor() => const ui.Color(0xFF101713);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await initNeuraWorldRust();
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
    _playerSurfaceId = worldManifest.playerSpawnSurfaceId;
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
    _animalNavigationBySurface.clear();
    environmentCatalog = EnvironmentCatalog.fromJsonString(
      await rootBundle.loadString(environmentReleaseCatalogAsset),
    );
    environmentCatalog.applyGeometryOverridesFromJsonString(
      await rootBundle.loadString(environmentReleaseGeometryOverridesAsset),
    );
    _synchronizeAnimalHomes();
    _refreshAnimalActivation(force: true);
    _rebuildSceneDepthCache();
    characterCatalog = CharacterCatalog.fromJsonString(
      await rootBundle.loadString(
        'packages/neura_assets/assets/catalogs/character_catalog.json',
      ),
    );

    final usedMaterialIds = <String>{
      worldManifest.baseMaterialId,
      for (final chunk in chunkStreamer.loadedChunks.values)
        for (final region in chunk.terrainRegions)
          if (!region.resetsToDefault) region.materialId,
      for (final chunk in chunkStreamer.loadedChunks.values)
        for (final stroke in chunk.terrainStrokes) stroke.materialId,
      for (final chunk in chunkStreamer.loadedChunks.values)
        for (final surface in chunk.surfaces) surface.materialId,
      for (final chunk in chunkStreamer.loadedChunks.values)
        for (final liquid in chunk.liquidVolumes) liquid.materialId,
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
        if (asset.animalAnimation case final animation?) {
          if (_activeAnimalIds.contains(object.id)) {
            paths.addAll(
              _runtimeAnimalImagePaths(
                animation,
                _animalStatesById[object.id]?.profile,
              ),
            );
          }
        } else {
          paths.add(asset.viewFor(object.direction.name).imagePath);
        }
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
    _nativeNavigationWorld = await RustNavigationWorld.create(
      buildNativeNavigationWorldInput(
        document: document,
        catalog: environmentCatalog,
        surfaceId: _playerSurfaceId,
      ),
    );
    _applyNavigationSnapshot(_nativeNavigationWorld!.snapshot);
    _synchronizeTerrainPictures();
    if (debugScene != null) {
      diagnosticsPaused = true;
      pauseEngine();
    }
  }

  EnvironmentDocument _documentFromLoadedChunks() {
    final surfaces = <EnvironmentSurface>[];
    final surfaceIds = <String>{};
    final liquids = <EnvironmentLiquidVolume>[];
    final liquidIds = <String>{};
    final connectors = <EnvironmentSurfaceConnector>[];
    final connectorIds = <String>{};
    final regions = <TerrainRegion>[];
    final regionIds = <String>{};
    for (final chunk in chunkStreamer.loadedChunks.values) {
      final originX = chunk.coordinate.x * chunk.size;
      final originY = chunk.coordinate.y * chunk.size;
      WorldPoint globalPoint(WorldPoint point) =>
          WorldPoint(point.x + originX, point.y + originY);
      for (final surface in chunk.surfaces) {
        if (!surfaceIds.add(surface.id)) continue;
        surfaces.add(
          EnvironmentSurface(
            id: surface.id,
            name: surface.name,
            materialId: surface.materialId,
            points: [for (final point in surface.points) globalPoint(point)],
            kind: surface.kind,
            height: switch (surface.height.kind) {
              EnvironmentSurfaceHeightKind.flat =>
                EnvironmentSurfaceHeight.flat(surface.height.elevation),
              EnvironmentSurfaceHeightKind.linearRamp =>
                EnvironmentSurfaceHeight.linearRamp(
                  elevation: surface.height.elevation,
                  endElevation: surface.height.endElevation,
                  rampStart: globalPoint(surface.height.rampStart!),
                  rampEnd: globalPoint(surface.height.rampEnd!),
                ),
            },
            walkable: surface.walkable,
            drawsBaseMaterial: surface.drawsBaseMaterial,
            order: surface.order,
            visibilityGroupId: surface.visibilityGroupId,
          ),
        );
      }
      for (final liquid in chunk.liquidVolumes) {
        if (!liquidIds.add(liquid.id)) continue;
        liquids.add(
          EnvironmentLiquidVolume(
            id: liquid.id,
            name: liquid.name,
            bedSurfaceId: liquid.bedSurfaceId,
            materialId: liquid.materialId,
            points: [for (final point in liquid.points) globalPoint(point)],
            surfaceElevation: liquid.surfaceElevation,
            depth: liquid.depth,
            endDepth: liquid.endDepth,
            depthRampStart: liquid.depthRampStart == null
                ? null
                : globalPoint(liquid.depthRampStart!),
            depthRampEnd: liquid.depthRampEnd == null
                ? null
                : globalPoint(liquid.depthRampEnd!),
            edgeBlend: liquid.edgeBlend,
            opacity: liquid.opacity,
            textureScale: liquid.textureScale,
            order: liquid.order,
          ),
        );
      }
      for (final connector in chunk.surfaceConnectors) {
        if (!connectorIds.add(connector.id)) continue;
        connectors.add(
          EnvironmentSurfaceConnector(
            id: connector.id,
            fromSurfaceId: connector.fromSurfaceId,
            toSurfaceId: connector.toSurfaceId,
            from: globalPoint(connector.from),
            to: globalPoint(connector.to),
            kind: connector.kind,
            width: connector.width,
            bidirectional: connector.bidirectional,
            cost: connector.cost,
          ),
        );
      }
      for (final region in chunk.terrainRegions) {
        if (!regionIds.add(region.id)) continue;
        regions.add(
          TerrainRegion(
            id: region.id,
            materialId: region.materialId,
            resetsToDefault: region.resetsToDefault,
            edgeBlend: region.edgeBlend,
            opacity: region.opacity,
            textureScale: region.textureScale,
            seed: region.seed,
            order: region.order,
            surfaceId: region.surfaceId,
            points: [
              for (final point in region.points)
                WorldPoint(point.x + originX, point.y + originY),
            ],
          ),
        );
      }
    }
    regions.sort((a, b) => a.order.compareTo(b.order));
    return EnvironmentDocument(
      id: worldManifest.id,
      name: worldManifest.name,
      width: worldManifest.width.ceil(),
      height: worldManifest.height.ceil(),
      baseMaterialId: worldManifest.baseMaterialId,
      terrainRegions: regions,
      objects: [
        for (final chunk in chunkStreamer.loadedChunks.values)
          ...chunk.worldObjects,
      ],
      terrainStrokes: [
        for (final chunk in chunkStreamer.loadedChunks.values)
          for (final stroke in chunk.terrainStrokes)
            TerrainStroke(
              materialId: stroke.materialId,
              radius: stroke.radius,
              opacity: stroke.opacity,
              resetsToBase: stroke.resetsToBase,
              seed: stroke.seed,
              spacing: stroke.spacing,
              scatter: stroke.scatter,
              sizeJitter: stroke.sizeJitter,
              opacityJitter: stroke.opacityJitter,
              surfaceId: stroke.surfaceId,
              points: [
                for (final point in stroke.points)
                  WorldPoint(
                    point.x + chunk.coordinate.x * chunk.size,
                    point.y + chunk.coordinate.y * chunk.size,
                  ),
              ],
            ),
      ],
      editorLayers: worldManifest.editorLayers,
      activeLayerId: worldManifest.activeLayerId,
      surfaces: [
        EnvironmentSurface(
          id: environmentBaseSurfaceId,
          name: 'Ground',
          materialId: worldManifest.baseMaterialId,
          points: [
            const WorldPoint(0, 0),
            WorldPoint(worldManifest.width, 0),
            WorldPoint(worldManifest.width, worldManifest.height),
            WorldPoint(0, worldManifest.height),
          ],
        ),
        ...surfaces,
      ],
      liquidVolumes: liquids,
      surfaceConnectors: connectors,
      activeSurfaceId:
          surfaceIds.contains(_playerSurfaceId) ||
              _playerSurfaceId == environmentBaseSurfaceId
          ? _playerSurfaceId
          : environmentBaseSurfaceId,
    );
  }

  Future<void> _streamAroundPlayer() async {
    final position = WorldPoint(playerPosition.x, playerPosition.y);
    final coordinate = worldManifest.coordinateFor(position);
    if (_streamingCenter == coordinate) return;
    _streamingCenter = coordinate;
    final changed = await chunkStreamer.updateAround(position);
    if (!changed) return;
    _navigationRequestSerial++;
    document = _documentFromLoadedChunks();
    _animalNavigationBySurface.clear();
    _synchronizeAnimalHomes();
    _refreshAnimalActivation(force: true);
    _rebuildSceneDepthCache();
    final refresh = _refreshNavigationAfterStreaming();
    _navigationRefresh = refresh;
    try {
      await refresh;
    } finally {
      if (identical(_navigationRefresh, refresh)) {
        _navigationRefresh = null;
      }
    }
  }

  Future<void> _refreshNavigationAfterStreaming() async {
    await _synchronizeChunkAssets();
    final nativeWorld = _nativeNavigationWorld;
    if (nativeWorld == null) return;
    final snapshot = await nativeWorld.replace(
      buildNativeNavigationWorldInput(
        document: document,
        catalog: environmentCatalog,
        surfaceId: _playerSurfaceId,
      ),
    );
    _applyNavigationSnapshot(snapshot);
  }

  void _scheduleNavigationRefresh() {
    final refresh = _refreshNavigationAfterStreaming();
    _navigationRefresh = refresh;
    unawaited(() async {
      try {
        await refresh;
      } finally {
        if (identical(_navigationRefresh, refresh)) {
          _navigationRefresh = null;
        }
      }
    }());
  }

  void _applyNavigationSnapshot(NativeNavigationSnapshot snapshot) {
    navigationGrid = NavigationGrid(
      width: worldManifest.width,
      height: worldManifest.height,
      cellSize: navigationCellSize,
      isBlocked: _isPlayerBlocked,
      blockedCells: snapshot.blockedCells,
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
        for (final region in chunk.terrainRegions)
          if (!region.resetsToDefault) region.materialId,
      for (final chunk in chunkStreamer.loadedChunks.values)
        for (final stroke in chunk.terrainStrokes) stroke.materialId,
      for (final chunk in chunkStreamer.loadedChunks.values)
        for (final surface in chunk.surfaces) surface.materialId,
      for (final chunk in chunkStreamer.loadedChunks.values)
        for (final liquid in chunk.liquidVolumes) liquid.materialId,
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
          if (asset.animalAnimation case final animation?) {
            if (_activeAnimalIds.contains(object.id)) {
              neededPaths.addAll(
                _runtimeAnimalImagePaths(
                  animation,
                  _animalStatesById[object.id]?.profile,
                ),
              );
            }
          } else {
            neededPaths.add(asset.viewFor(object.direction.name).imagePath);
          }
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

  Iterable<String> _runtimeAnimalImagePaths(
    AnimalAnimationAsset animation,
    AnimalBehaviorProfile? resolvedProfile,
  ) sync* {
    yield animation.idle.imagePath;
    final profile =
        resolvedProfile ??
        environmentCatalog.animalBehaviorProfileById(
          animation.behaviorProfileId,
        );
    if (profile == null) return;
    if (profile.walkWeight > 0) yield animation.walk.imagePath;
    if (profile.runWeight > 0) yield animation.run.imagePath;
    if (profile.actionWeight > 0) yield animation.action.imagePath;
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
    if (document.surfaces.length > 1) {
      for (final picture in _terrainPictures.values) {
        picture.dispose();
      }
      _terrainPictures.clear();
      return;
    }
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
    final layerBounds = ui.Rect.fromLTRB(
      corners.map((corner) => corner.x).reduce(math.min),
      corners.map((corner) => corner.y).reduce(math.min),
      corners.map((corner) => corner.x).reduce(math.max),
      corners.map((corner) => corner.y).reduce(math.max),
    );
    if (chunk.terrainRegions.isNotEmpty) {
      canvas.saveLayer(layerBounds, ui.Paint());
      for (final region in chunk.terrainRegions) {
        _renderTerrainRegion(
          canvas,
          TerrainRegion(
            id: region.id,
            materialId: region.materialId,
            resetsToDefault: region.resetsToDefault,
            edgeBlend: region.edgeBlend,
            opacity: region.opacity,
            textureScale: region.textureScale,
            seed: region.seed,
            order: region.order,
            surfaceId: region.surfaceId,
            points: [
              for (final point in region.points)
                WorldPoint(point.x + originX, point.y + originY),
            ],
          ),
        );
      }
      canvas.restore();
    }
    if (chunk.terrainStrokes.isNotEmpty) {
      canvas.saveLayer(layerBounds, ui.Paint());
    }
    for (final stroke in chunk.terrainStrokes) {
      _renderStroke(
        canvas,
        TerrainStroke(
          materialId: stroke.materialId,
          radius: stroke.radius,
          opacity: stroke.opacity,
          resetsToBase: stroke.resetsToBase,
          seed: stroke.seed,
          spacing: stroke.spacing,
          scatter: stroke.scatter,
          sizeJitter: stroke.sizeJitter,
          opacityJitter: stroke.opacityJitter,
          surfaceId: stroke.surfaceId,
          points: [
            for (final point in stroke.points)
              WorldPoint(point.x + originX, point.y + originY),
          ],
        ),
      );
    }
    if (chunk.terrainStrokes.isNotEmpty) canvas.restore();
    return recorder.endRecording();
  }

  @override
  void onTapDown(TapDownEvent event) {
    if (!isLoaded) return;
    final projected =
        (event.canvasPosition - size / 2) / zoom + _cameraProjectedPosition;
    final world = _screenToVisibleSurface(projected);
    unawaited(
      requestMovementAsync(
        WorldPoint(
          world.x.clamp(0.0, document.width.toDouble()),
          world.y.clamp(0.0, document.height.toDouble()),
        ),
      ),
    );
  }

  bool requestMovement(WorldPoint requested) {
    if (!isLoaded) return false;
    final requestedDestination = WorldPoint(
      requested.x.clamp(0.0, document.width.toDouble()),
      requested.y.clamp(0.0, document.height.toDouble()),
    );
    final route = navigationGrid.findPath(
      WorldPoint(playerPosition.x, playerPosition.y),
      requestedDestination,
    );
    return _applyMovementRoute(route);
  }

  Future<bool> requestMovementAsync(WorldPoint requested) async {
    if (!isLoaded) return false;
    final nativeWorld = _nativeNavigationWorld;
    if (nativeWorld == null) return requestMovement(requested);
    final requestSerial = ++_navigationRequestSerial;
    final requestedDestination = WorldPoint(
      requested.x.clamp(0.0, document.width.toDouble()),
      requested.y.clamp(0.0, document.height.toDouble()),
    );
    _pendingNavigationRequests++;
    try {
      final refresh = _navigationRefresh;
      if (refresh != null) await refresh;
      if (requestSerial != _navigationRequestSerial) return false;
      final result = await nativeWorld.findPath(
        start: NativeNavigationPoint(x: playerPosition.x, y: playerPosition.y),
        destination: NativeNavigationPoint(
          x: requestedDestination.x,
          y: requestedDestination.y,
        ),
      );
      if (requestSerial != _navigationRequestSerial) return false;
      final route = [
        for (final point in result.points) WorldPoint(point.x, point.y),
      ];
      navigationGrid.recordExternalPath(
        route,
        expandedNodes: result.expandedNodes,
      );
      _lastNavigationMicros = result.elapsedMicros;
      return _applyMovementRoute(route);
    } finally {
      _pendingNavigationRequests--;
    }
  }

  bool _applyMovementRoute(Iterable<WorldPoint> route) {
    final wasMoving = isMoving;
    _movementWaypoints
      ..clear()
      ..addAll(
        directionAlignedWaypoints(
          playerPosition,
          [for (final point in route) Vector2(point.x, point.y)],
          initialFacing: _facing,
          turnRandom: _movementRandom,
          isWalkable: _isPlayerSegmentWalkable,
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

  bool _isBlockedOnSurface(WorldPoint point, String surfaceId) {
    final support = document.surfaceById(surfaceId);
    if (support == null || !support.walkable || !support.contains(point)) {
      return true;
    }
    final material = environmentCatalog.materialById(
      environmentMaterialAtPoint(document, point, surfaceId: surfaceId),
    );
    if (material?.blocksMovement ?? false) return true;
    final sample = environmentSurfaceAtPoint(
      document,
      point,
      preferredSurfaceId: surfaceId,
    );
    final liquidMaterialId = sample.liquidMaterialId;
    if (liquidMaterialId != null &&
        (environmentCatalog.materialById(liquidMaterialId)?.blocksMovement ??
            false)) {
      return true;
    }
    for (final object in document.objects) {
      if (object.supportSurfaceId != surfaceId) continue;
      final asset = environmentCatalog.objectById(object.assetId);
      if (asset != null &&
          environmentObjectBlocksPoint(
            asset,
            object,
            point,
            actorRadius: playerNavigationRadius,
            geometry: environmentCatalog.geometryForAsset(
              asset,
              direction: object.direction.name,
            ),
          )) {
        return true;
      }
    }
    return false;
  }

  bool _isPlayerBlocked(WorldPoint point) =>
      _isBlockedOnSurface(point, _playerSurfaceId);

  bool _isSegmentWalkableOnSurface(
    Vector2 start,
    Vector2 end,
    String surfaceId,
  ) {
    final delta = end - start;
    final steps = math.max(1, (delta.length / (navigationCellSize / 3)).ceil());
    var previousPoint = start;
    var previousElevation = _groundElevationAt(start, surfaceId: surfaceId);
    for (var step = 0; step <= steps; step++) {
      final t = step / steps;
      final point = Vector2(start.x + delta.x * t, start.y + delta.y * t);
      if (_isBlockedOnSurface(WorldPoint(point.x, point.y), surfaceId)) {
        return false;
      }
      if (step > 0) {
        final elevation = _groundElevationAt(point, surfaceId: surfaceId);
        final horizontalDistance = point.distanceTo(previousPoint);
        final maximumElevationChange =
            horizontalDistance * _maximumWalkableElevationSlope + 0.01;
        if ((elevation - previousElevation).abs() > maximumElevationChange) {
          return false;
        }
        previousElevation = elevation;
        previousPoint = point;
      }
    }
    return true;
  }

  bool _isPlayerSegmentWalkable(Vector2 start, Vector2 end) =>
      _isSegmentWalkableOnSurface(start, end, _playerSurfaceId);

  void _synchronizeAnimalHomes() {
    _loadedAnimalHomesById.clear();
    for (final object in document.objects) {
      final asset = environmentCatalog.objectById(object.assetId);
      final animation = asset?.animalAnimation;
      if (asset == null || animation == null) continue;
      final profile =
          environmentCatalog.animalBehaviorProfileById(
            object.behaviorProfileId ?? animation.behaviorProfileId,
          ) ??
          environmentCatalog.animalBehaviorProfileById(
            animation.behaviorProfileId,
          );
      if (profile == null) continue;
      _loadedAnimalHomesById[object.id] = object;
      _animalStatesById.putIfAbsent(object.id, () {
        return _ActiveAnimal(
          id: object.id,
          asset: asset,
          profile: profile,
          home: Vector2(object.x, object.y),
          facing: object.direction,
          randomSeed: _stableAnimalSeed(object.id),
          surfaceId: object.supportSurfaceId,
        );
      });
      _animalStatesById[object.id]!.surfaceId = object.supportSurfaceId;
    }
    _activeAnimalIds.removeWhere(
      (id) => !_loadedAnimalHomesById.containsKey(id),
    );
  }

  bool _refreshAnimalActivation({bool force = false}) {
    var changed = false;
    for (final entry in _loadedAnimalHomesById.entries) {
      final animal = _animalStatesById[entry.key]!;
      final limit = _activeAnimalIds.contains(entry.key)
          ? _animalDeactivationRadius
          : _animalActivationRadius;
      final shouldBeActive =
          animal.position.distanceTo(playerPosition) <= limit;
      if (shouldBeActive) {
        changed = _activeAnimalIds.add(entry.key) || changed;
      } else {
        changed = _activeAnimalIds.remove(entry.key) || changed;
      }
    }
    if (changed && !force) unawaited(_synchronizeChunkAssets());
    return changed;
  }

  void _updateAnimals(double dt) {
    _animalActivationClock += dt;
    if (_animalActivationClock >= 0.5) {
      _animalActivationClock = 0;
      _refreshAnimalActivation();
    }
    for (final id in _activeAnimalIds.toList(growable: false)) {
      final animal = _animalStatesById[id];
      if (animal == null) continue;
      animal.animationTime += dt;
      if (animal.isMoving) {
        _updateMovingAnimal(animal, dt);
        continue;
      }
      if (animal.pathPending) continue;
      animal.remainingActivitySeconds -= dt;
      if (animal.remainingActivitySeconds <= 0) {
        _chooseNextAnimalActivity(animal);
      }
    }
  }

  void _updateMovingAnimal(_ActiveAnimal animal, double dt) {
    var remainingSeconds = dt;
    while (animal.waypoints.isNotEmpty && remainingSeconds > 0) {
      final waypoint = animal.waypoints.first;
      final delta = waypoint - animal.position;
      final projectedDistance =
          (_projectGround(waypoint, surfaceId: animal.surfaceId) -
                  _projectGround(animal.position, surfaceId: animal.surfaceId))
              .length;
      if (projectedDistance <= 0.01) {
        animal.position.setFrom(waypoint);
        animal.waypoints.removeAt(0);
        continue;
      }
      animal.facing = directionForWorldDelta(delta);
      final speed = animal.activity == _AnimalActivity.run
          ? animal.profile.runSpeedPixelsPerSecond
          : animal.profile.walkSpeedPixelsPerSecond;
      final remainingPixels = speed * remainingSeconds;
      if (remainingPixels >= projectedDistance) {
        animal.position.setFrom(waypoint);
        animal.waypoints.removeAt(0);
        remainingSeconds -= projectedDistance / speed;
      } else {
        animal.position.add(delta * (remainingPixels / projectedDistance));
        remainingSeconds = 0;
      }
    }
    if (animal.waypoints.isEmpty) {
      animal.setActivity(_AnimalActivity.idle, duration: 0.35);
    }
  }

  void _chooseNextAnimalActivity(_ActiveAnimal animal) {
    final profile = animal.profile;
    var idleWeight = profile.idleWeight;
    var actionWeight = profile.actionWeight;
    var walkWeight = profile.roamingRadius > 0 ? profile.walkWeight : 0.0;
    var runWeight = profile.roamingRadius > 0 ? profile.runWeight : 0.0;
    final total = idleWeight + actionWeight + walkWeight + runWeight;
    if (total <= 0) {
      animal.setActivity(_AnimalActivity.idle, duration: 2);
      return;
    }
    var choice = animal.random.nextDouble() * total;
    if ((choice -= idleWeight) < 0) {
      animal.setActivity(
        _AnimalActivity.idle,
        duration: animal.randomDuration(),
      );
      return;
    }
    if ((choice -= actionWeight) < 0) {
      animal.setActivity(
        _AnimalActivity.action,
        duration: animal.randomDuration() * 0.65,
      );
      return;
    }
    final activity = (choice -= walkWeight) < 0
        ? _AnimalActivity.walk
        : _AnimalActivity.run;
    unawaited(_requestAnimalPath(animal, activity));
  }

  Future<void> _requestAnimalPath(
    _ActiveAnimal animal,
    _AnimalActivity activity,
  ) async {
    if (animal.pathPending || animal.profile.roamingRadius <= 0) return;
    animal.pathPending = true;
    final serial = ++animal.pathSerial;
    final angle = animal.random.nextDouble() * math.pi * 2;
    final distance =
        animal.profile.roamingRadius *
        (0.25 + math.sqrt(animal.random.nextDouble()) * 0.7);
    final target = Vector2(
      (animal.home.x + math.cos(angle) * distance).clamp(
        0.0,
        worldManifest.width,
      ),
      (animal.home.y + math.sin(angle) * distance).clamp(
        0.0,
        worldManifest.height,
      ),
    );
    try {
      final refresh = _navigationRefresh;
      if (refresh != null) await refresh;
      if (serial != animal.pathSerial ||
          !_activeAnimalIds.contains(animal.id)) {
        return;
      }
      final nativeWorld = animal.surfaceId == _playerSurfaceId
          ? _nativeNavigationWorld
          : null;
      final fallbackGrid = animal.surfaceId == _playerSurfaceId
          ? navigationGrid
          : _animalNavigationBySurface.putIfAbsent(
              animal.surfaceId,
              () => NavigationGrid(
                width: worldManifest.width,
                height: worldManifest.height,
                cellSize: navigationCellSize,
                isBlocked: (point) =>
                    _isBlockedOnSurface(point, animal.surfaceId),
              ),
            );
      final route = nativeWorld == null
          ? fallbackGrid.findPath(
              WorldPoint(animal.position.x, animal.position.y),
              WorldPoint(target.x, target.y),
            )
          : [
              for (final point in (await nativeWorld.findPath(
                start: NativeNavigationPoint(
                  x: animal.position.x,
                  y: animal.position.y,
                ),
                destination: NativeNavigationPoint(x: target.x, y: target.y),
              )).points)
                WorldPoint(point.x, point.y),
            ];
      if (serial != animal.pathSerial ||
          !_activeAnimalIds.contains(animal.id)) {
        return;
      }
      final aligned = directionAlignedWaypoints(
        animal.position,
        [for (final point in route) Vector2(point.x, point.y)],
        initialFacing: animal.facing,
        turnRandom: animal.random,
        isWalkable: (start, end) =>
            _isSegmentWalkableOnSurface(start, end, animal.surfaceId),
      );
      final radius = animal.profile.roamingRadius + navigationCellSize;
      if (aligned.isEmpty ||
          aligned.any((point) => point.distanceTo(animal.home) > radius)) {
        animal.setActivity(_AnimalActivity.idle, duration: 0.8);
        return;
      }
      animal.waypoints
        ..clear()
        ..addAll(aligned);
      animal.setActivity(activity);
      animal.facing = directionForWorldDelta(
        animal.waypoints.first - animal.position,
      );
    } catch (_) {
      if (serial == animal.pathSerial) {
        animal.waypoints.clear();
        animal.setActivity(_AnimalActivity.idle, duration: 1.0);
      }
    } finally {
      if (serial == animal.pathSerial) animal.pathPending = false;
    }
  }

  static int _stableAnimalSeed(String id) {
    var hash = 0x811C9DC5;
    for (final codeUnit in id.codeUnits) {
      hash = ((hash ^ codeUnit) * 0x01000193) & 0x7FFFFFFF;
    }
    return hash;
  }

  @override
  void update(double dt) {
    super.update(dt);
    _updateAnimals(dt);
    if (_movementWaypoints.isEmpty) {
      _updateConnectorLatch();
      _animationTime += dt;
      return;
    }
    final hadMovement = _movementWaypoints.isNotEmpty;

    var remainingSeconds = dt;
    while (_movementWaypoints.isNotEmpty && remainingSeconds > 0) {
      final waypoint = _movementWaypoints.first;
      final delta = waypoint - playerPosition;
      final projectedDistance =
          (_projectGround(waypoint) - _projectGround(playerPosition)).length;
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
    if (hadMovement) _trySurfaceConnectorTransition();

    if (_movementWaypoints.isEmpty) {
      _destination = null;
      _turnDirections.clear();
      _turnStepRemaining = 0;
      _animationTime = 0;
    } else {
      _animationTime += dt;
    }
  }

  void _updateConnectorLatch() {
    final id = _latchedConnectorId;
    if (id == null) return;
    EnvironmentSurfaceConnector? connector;
    for (final candidate in document.surfaceConnectors) {
      if (candidate.id == id) {
        connector = candidate;
        break;
      }
    }
    if (connector == null) {
      _latchedConnectorId = null;
      return;
    }
    final endpoint = connector.fromSurfaceId == _playerSurfaceId
        ? connector.from
        : connector.toSurfaceId == _playerSurfaceId
        ? connector.to
        : null;
    if (endpoint == null) {
      _latchedConnectorId = null;
      return;
    }
    final distance = playerPosition.distanceTo(Vector2(endpoint.x, endpoint.y));
    if (distance > connector.width + playerNavigationRadius) {
      _latchedConnectorId = null;
    }
  }

  bool _trySurfaceConnectorTransition() {
    _updateConnectorLatch();
    if (_latchedConnectorId != null) return false;
    for (final connector in document.surfaceConnectors) {
      WorldPoint? entry;
      WorldPoint? exit;
      String? destinationSurfaceId;
      if (connector.fromSurfaceId == _playerSurfaceId) {
        entry = connector.from;
        exit = connector.to;
        destinationSurfaceId = connector.toSurfaceId;
      } else if (connector.bidirectional &&
          connector.toSurfaceId == _playerSurfaceId) {
        entry = connector.to;
        exit = connector.from;
        destinationSurfaceId = connector.fromSurfaceId;
      }
      if (entry == null || exit == null || destinationSurfaceId == null) {
        continue;
      }
      final entryDistance = playerPosition.distanceTo(
        Vector2(entry.x, entry.y),
      );
      if (entryDistance > connector.width / 2 + playerNavigationRadius) {
        continue;
      }
      _playerSurfaceId = destinationSurfaceId;
      playerPosition.setValues(exit.x, exit.y);
      _latchedConnectorId = connector.id;
      _navigationRequestSerial++;
      _movementWaypoints.clear();
      _turnDirections.clear();
      _turnStepRemaining = 0;
      _destination = null;
      _animalNavigationBySurface.clear();
      _scheduleNavigationRefresh();
      unawaited(_streamAroundPlayer());
      return true;
    }
    return false;
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

    if (document.surfaces.length > 1) {
      _renderLayeredEnvironment(canvas);
    } else {
      _renderBaseGround(canvas);
      _renderChunkTerrain(canvas);
      if (document.liquidVolumes.isNotEmpty) {
        _renderScene(
          canvas,
          environmentBaseSurfaceId,
          liquidPass: _LiquidSpritePass.submerged,
        );
      }
      _renderLiquidVolumes(canvas);
      _renderScene(
        canvas,
        environmentBaseSurfaceId,
        liquidPass: _LiquidSpritePass.exposed,
      );
    }
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
    final image = _loadedImages[material.texturePath]!;
    final texelsPerWorldUnitX =
        image.width / material.effectiveRepeatWorldWidth;
    final texelsPerWorldUnitY =
        image.height / material.effectiveRepeatWorldHeight;
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
          originX * texelsPerWorldUnitX,
          originY * texelsPerWorldUnitY,
          (maxX - originX) * texelsPerWorldUnitX,
          (maxY - originY) * texelsPerWorldUnitY,
        ),
      );
    }
  }

  List<EnvironmentSurface> _orderedSurfaces() =>
      [...document.surfaces]..sort((a, b) {
        final order = a.order.compareTo(b.order);
        if (order != 0) return order;
        return a.height.elevation.compareTo(b.height.elevation);
      });

  void _renderLayeredEnvironment(ui.Canvas canvas) {
    for (final surface in _orderedSurfaces()) {
      final surfacePath = _surfaceProjectedPath(surface);
      final layerBounds = surfacePath.getBounds().inflate(
        projection.tileWidth * 3,
      );
      canvas.save();
      canvas.clipPath(surfacePath);
      if (surface.id == environmentBaseSurfaceId) {
        _renderBaseGround(canvas);
      } else if (surface.drawsBaseMaterial) {
        _renderPhysicalSurface(canvas, surface);
      }
      final regions = document.terrainRegions.where(
        (region) => region.surfaceId == surface.id,
      );
      if (regions.isNotEmpty) {
        canvas.saveLayer(layerBounds, ui.Paint());
        for (final region in regions) {
          _renderTerrainRegion(canvas, region);
        }
        canvas.restore();
      }
      final strokes = document.terrainStrokes.where(
        (stroke) => stroke.surfaceId == surface.id,
      );
      if (strokes.isNotEmpty) {
        canvas.saveLayer(layerBounds, ui.Paint());
        for (final stroke in strokes) {
          _renderStroke(canvas, stroke);
        }
        canvas.restore();
      }
      final liquids =
          document.liquidVolumes
              .where((liquid) => liquid.bedSurfaceId == surface.id)
              .toList()
            ..sort((a, b) => a.order.compareTo(b.order));
      if (liquids.isNotEmpty) {
        _renderScene(
          canvas,
          surface.id,
          liquidPass: _LiquidSpritePass.submerged,
        );
      }
      for (final liquid in liquids) {
        _renderLiquidVolume(canvas, liquid);
      }
      canvas.restore();
      _renderScene(canvas, surface.id, liquidPass: _LiquidSpritePass.exposed);
    }
  }

  ui.Path _surfaceProjectedPath(EnvironmentSurface surface) {
    final path = ui.Path();
    for (var index = 0; index < surface.points.length; index++) {
      final point = surface.points[index];
      final projected = _projectAtElevation(
        Vector2(point.x, point.y),
        surface.elevationAt(point),
      );
      index == 0
          ? path.moveTo(projected.x, projected.y)
          : path.lineTo(projected.x, projected.y);
    }
    return path..close();
  }

  void _renderPhysicalSurface(ui.Canvas canvas, EnvironmentSurface surface) {
    _renderTerrainRegion(
      canvas,
      TerrainRegion(
        id: 'surface-fill:${surface.id}',
        materialId: surface.materialId,
        points: surface.points,
        surfaceId: surface.id,
      ),
    );
  }

  void _renderLiquidVolumes(ui.Canvas canvas) {
    final liquids = [...document.liquidVolumes]
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final liquid in liquids) {
      _renderLiquidVolume(canvas, liquid);
    }
  }

  void _renderLiquidVolume(
    ui.Canvas canvas,
    EnvironmentLiquidVolume liquid, {
    ui.BlendMode? blendMode,
  }) {
    if (liquid.points.length < 3) return;
    final material = environmentCatalog.materialById(liquid.materialId);
    final basePaint = _repeatingPaints[liquid.materialId];
    final image = material == null ? null : _loadedImages[material.texturePath];
    if (material == null || basePaint?.shader == null || image == null) return;
    final path = ui.Path();
    for (var index = 0; index < liquid.points.length; index++) {
      final point = liquid.points[index];
      final projected = _projectAtElevation(
        Vector2(point.x, point.y),
        liquid.surfaceElevation,
      );
      index == 0
          ? path.moveTo(projected.x, projected.y)
          : path.lineTo(projected.x, projected.y);
    }
    path.close();
    final minX = liquid.points.map((point) => point.x).reduce(math.min);
    final minY = liquid.points.map((point) => point.y).reduce(math.min);
    final maxX = liquid.points.map((point) => point.x).reduce(math.max);
    final maxY = liquid.points.map((point) => point.y).reduce(math.max);
    final texelsPerWorldUnitX =
        image.width /
        (material.effectiveRepeatWorldWidth * liquid.textureScale);
    final texelsPerWorldUnitY =
        image.height /
        (material.effectiveRepeatWorldHeight * liquid.textureScale);
    final softness = liquid.edgeBlend.clamp(0, 3).toDouble();
    final sigma = softness * projection.halfHeight;
    final bounds = path.getBounds().inflate(math.max(1, sigma * 3));
    canvas.saveLayer(
      bounds,
      ui.Paint()..blendMode = blendMode ?? ui.BlendMode.srcOver,
    );
    final paint = ui.Paint()
      ..shader = basePaint!.shader
      ..blendMode = ui.BlendMode.srcOver;
    final expandedMin = WorldPoint(minX - softness, minY - softness);
    final expandedMax = WorldPoint(maxX + softness, maxY + softness);
    ui.Color liquidVertexColor(WorldPoint point) {
      final opticalDepth = _liquidOpticalDepth(liquid.depthAt(point));
      final depthOpacity = 0.15 + 0.85 * opticalDepth;
      final tintStrength = 0.8 * opticalDepth;
      int tintChannel(int deepWater) =>
          (255 + (deepWater - 255) * tintStrength).round();
      return ui.Color.fromRGBO(
        tintChannel(88),
        tintChannel(126),
        tintChannel(150),
        liquid.opacity * depthOpacity,
      );
    }

    _drawTexturedWorldQuad(
      canvas,
      expandedMin,
      expandedMax,
      paint,
      ui.Rect.fromLTRB(
        (minX - softness) * texelsPerWorldUnitX,
        (minY - softness) * texelsPerWorldUnitY,
        (maxX + softness) * texelsPerWorldUnitX,
        (maxY + softness) * texelsPerWorldUnitY,
      ),
      elevation: liquid.surfaceElevation,
      vertexColors: [
        liquidVertexColor(expandedMin),
        liquidVertexColor(WorldPoint(expandedMax.x, expandedMin.y)),
        liquidVertexColor(expandedMax),
        liquidVertexColor(WorldPoint(expandedMin.x, expandedMax.y)),
      ],
    );
    final maskPaint = ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..maskFilter = softness == 0
          ? null
          : ui.MaskFilter.blur(ui.BlurStyle.normal, sigma);
    canvas.saveLayer(bounds, ui.Paint()..blendMode = ui.BlendMode.dstIn);
    canvas.drawPath(path, maskPaint);
    canvas.restore();
    canvas.restore();
  }

  void _renderChunkTerrain(ui.Canvas canvas) {
    if (_hasElevatedTerrain) {
      for (final region in document.terrainRegions) {
        _renderTerrainRegion(canvas, region);
      }
      for (final stroke in document.terrainStrokes) {
        _renderStroke(canvas, stroke);
      }
      return;
    }
    for (final coordinate in chunkStreamer.loadedChunks.keys) {
      final picture = _terrainPictures[coordinate];
      if (picture != null) canvas.drawPicture(picture);
    }
  }

  bool get _hasElevatedTerrain => document.surfaces.any(
    (surface) =>
        surface.height.elevation != 0 || surface.height.endElevation != 0,
  );

  void _renderStroke(ui.Canvas canvas, TerrainStroke stroke) {
    if (stroke.points.isEmpty) return;
    if (stroke.resetsToBase) {
      final path = ui.Path();
      for (var index = 0; index < stroke.points.length; index++) {
        final point = stroke.points[index];
        final projected = _projectAtElevation(
          Vector2(point.x, point.y),
          _surfaceElevationAt(stroke.surfaceId, point),
        );
        index == 0
            ? path.moveTo(projected.x, projected.y)
            : path.lineTo(projected.x, projected.y);
      }
      canvas.drawPath(path..close(), _terrainResetPaint);
      return;
    }
    final material = environmentCatalog.materialById(stroke.materialId);
    final paint = _decalPaints[stroke.materialId];
    if (material == null || paint == null) return;
    final image = _loadedImages[material.decalPath]!;
    for (final stamp in terrainStrokeStamps(stroke)) {
      paint.color = ui.Color.fromRGBO(255, 255, 255, stamp.opacity);
      _drawStamp(
        canvas,
        stamp.center,
        stamp.radius,
        paint,
        image,
        elevation: _surfaceElevationAt(stroke.surfaceId, stamp.center),
      );
    }
  }

  void _renderTerrainRegion(ui.Canvas canvas, TerrainRegion region) {
    if (region.points.length < 3) return;
    final path = ui.Path();
    for (var index = 0; index < region.points.length; index++) {
      final point = region.points[index];
      final projected = _projectAtElevation(
        Vector2(point.x, point.y),
        _surfaceElevationAt(region.surfaceId, point),
      );
      index == 0
          ? path.moveTo(projected.x, projected.y)
          : path.lineTo(projected.x, projected.y);
    }
    path.close();
    if (region.resetsToDefault) {
      canvas.drawPath(path, _terrainResetPaint);
      return;
    }
    final material = environmentCatalog.materialById(region.materialId);
    final paint = _repeatingPaints[region.materialId];
    if (material == null || paint == null) return;
    final image = _loadedImages[material.texturePath];
    if (image == null) return;
    final minX = region.points.map((point) => point.x).reduce(math.min);
    final minY = region.points.map((point) => point.y).reduce(math.min);
    final maxX = region.points.map((point) => point.x).reduce(math.max);
    final maxY = region.points.map((point) => point.y).reduce(math.max);
    final texelsPerWorldUnitX =
        image.width /
        (material.effectiveRepeatWorldWidth * region.textureScale);
    final texelsPerWorldUnitY =
        image.height /
        (material.effectiveRepeatWorldHeight * region.textureScale);
    final softness = region.edgeBlend.clamp(0, 3).toDouble();
    final needsMask = softness > 0 || region.opacity < 0.999;
    final sigma = softness * projection.halfHeight;
    final expandedMin = WorldPoint(minX - softness, minY - softness);
    final expandedMax = WorldPoint(maxX + softness, maxY + softness);
    final layerBounds = path.getBounds().inflate(math.max(1, sigma * 3));
    if (needsMask) {
      canvas.saveLayer(layerBounds, ui.Paint());
    } else {
      canvas.save();
      canvas.clipPath(path);
    }
    _drawTexturedWorldQuad(
      canvas,
      expandedMin,
      expandedMax,
      paint,
      ui.Rect.fromLTRB(
        expandedMin.x * texelsPerWorldUnitX,
        expandedMin.y * texelsPerWorldUnitY,
        expandedMax.x * texelsPerWorldUnitX,
        expandedMax.y * texelsPerWorldUnitY,
      ),
      elevation: _surfaceElevationAt(region.surfaceId, region.points.first),
    );
    if (needsMask) {
      canvas.saveLayer(layerBounds, ui.Paint()..blendMode = ui.BlendMode.dstIn);
      canvas.drawPath(
        path,
        ui.Paint()
          ..color = ui.Color.fromRGBO(
            255,
            255,
            255,
            region.opacity.clamp(0.05, 1),
          )
          ..maskFilter = softness == 0
              ? null
              : ui.MaskFilter.blur(ui.BlurStyle.normal, sigma),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  void _drawStamp(
    ui.Canvas canvas,
    WorldPoint center,
    double radius,
    ui.Paint paint,
    ui.Image image, {
    double elevation = 0,
    ui.BlendMode blendMode = ui.BlendMode.srcOver,
  }) {
    _drawTexturedWorldQuad(
      canvas,
      WorldPoint(center.x - radius, center.y - radius),
      WorldPoint(center.x + radius, center.y + radius),
      paint,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      elevation: elevation,
      blendMode: blendMode,
    );
  }

  void _drawTexturedWorldQuad(
    ui.Canvas canvas,
    WorldPoint min,
    WorldPoint max,
    ui.Paint paint,
    ui.Rect textureRect, {
    double elevation = 0,
    ui.BlendMode blendMode = ui.BlendMode.srcOver,
    List<ui.Color>? vertexColors,
  }) {
    final corners = [
      projection.worldToScreen(Vector2(min.x, min.y)),
      projection.worldToScreen(Vector2(max.x, min.y)),
      projection.worldToScreen(Vector2(max.x, max.y)),
      projection.worldToScreen(Vector2(min.x, max.y)),
    ];
    if (elevation != 0) {
      for (final corner in corners) {
        corner.y -= elevation * elevationPixelsPerWorldUnit;
      }
    }
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
      colors: vertexColors == null
          ? null
          : Int32List.fromList([
              for (final color in vertexColors) color.toARGB32(),
            ]),
    );
    canvas.drawVertices(
      vertices,
      vertexColors == null ? blendMode : ui.BlendMode.modulate,
      paint,
    );
  }

  void _renderScene(
    ui.Canvas canvas,
    String surfaceId, {
    required _LiquidSpritePass liquidPass,
  }) {
    _renderObjectBand(
      canvas,
      EnvironmentRenderBand.groundCover,
      surfaceId: surfaceId,
      liquidPass: liquidPass,
    );

    final staticOrder =
        _staticDepthOrderBySurface[surfaceId] ??
        const <EnvironmentDepthEntity<_SceneEntry>>[];
    final dynamicEntries = _dynamicDepthEntries(surfaceId, staticOrder);
    var dynamicIndex = 0;
    for (var index = 0; index <= staticOrder.length; index++) {
      while (dynamicIndex < dynamicEntries.length &&
          dynamicEntries[dynamicIndex].insertionIndex == index) {
        _renderDynamicSceneEntry(
          canvas,
          dynamicEntries[dynamicIndex].entity.value,
          liquidPass: liquidPass,
        );
        dynamicIndex++;
      }
      if (index < staticOrder.length) {
        _renderObject(
          canvas,
          staticOrder[index].value.object!,
          liquidPass: liquidPass,
        );
      }
    }

    _renderObjectBand(
      canvas,
      EnvironmentRenderBand.overhead,
      surfaceId: surfaceId,
      liquidPass: liquidPass,
    );
    _renderObjectBand(
      canvas,
      EnvironmentRenderBand.effects,
      surfaceId: surfaceId,
      liquidPass: liquidPass,
    );
  }

  void _renderObjectBand(
    ui.Canvas canvas,
    EnvironmentRenderBand band, {
    required String surfaceId,
    required _LiquidSpritePass liquidPass,
  }) {
    for (final object in _objectsInBand(band, surfaceId: surfaceId)) {
      _renderObject(canvas, object, liquidPass: liquidPass);
    }
  }

  Iterable<PlacedEnvironmentObject> _objectsInBand(
    EnvironmentRenderBand band, {
    String? surfaceId,
  }) {
    final objects = _objectsByRenderBand[band] ?? const [];
    return surfaceId == null
        ? objects
        : objects.where(
            (object) =>
                (_objectDepthSurfaceIdsById[object.id] ??
                    object.supportSurfaceId) ==
                surfaceId,
          );
  }

  void _rebuildSceneDepthCache() {
    _objectSurfacesById.clear();
    _objectDepthSurfaceIdsById.clear();
    _liquidOcclusionPathsById.clear();
    _objectsWithoutLiquidOcclusionPath.clear();
    final objectsByBand =
        <EnvironmentRenderBand, List<PlacedEnvironmentObject>>{
          for (final band in EnvironmentRenderBand.values) band: [],
        };
    for (final object in document.objects) {
      final asset = environmentCatalog.objectById(object.assetId);
      if (asset != null && !asset.isAnimal) {
        final surface = _surfaceAt(
          Vector2(object.x, object.y),
          surfaceId: object.supportSurfaceId,
        );
        _objectSurfacesById[object.id] = surface;
        final geometry = environmentCatalog.geometryForAsset(
          asset,
          direction: object.direction.name,
        );
        _objectDepthSurfaceIdsById[object.id] = environmentObjectDepthSurfaceId(
          document: document,
          asset: asset,
          object: object,
          objectElevation: _objectElevation(object, asset, surface: surface),
          geometry: geometry,
        );
        objectsByBand[asset.renderBand]!.add(object);
      }
    }
    for (final entry in objectsByBand.entries) {
      entry.value.sort((a, b) {
        final aAsset = environmentCatalog.objectById(a.assetId)!;
        final bAsset = environmentCatalog.objectById(b.assetId)!;
        final depth = aAsset
            .depthAt(a.x, a.y, instanceSortBias: a.sortBias)
            .compareTo(bAsset.depthAt(b.x, b.y, instanceSortBias: b.sortBias));
        return depth != 0 ? depth : a.x.compareTo(b.x);
      });
    }
    _objectsByRenderBand
      ..clear()
      ..addEntries(
        objectsByBand.entries.map(
          (entry) => MapEntry(entry.key, List.unmodifiable(entry.value)),
        ),
      );

    final entities = <EnvironmentDepthEntity<_SceneEntry>>[];
    for (final object in _objectsInBand(EnvironmentRenderBand.depthSorted)) {
      final asset = environmentCatalog.objectById(object.assetId)!;
      final geometry = environmentCatalog.geometryForAsset(
        asset,
        direction: object.direction.name,
      );
      entities.add(
        EnvironmentDepthEntity(
          id: object.id,
          value: _SceneEntry.object(object),
          contact: WorldPoint(
            object.x + asset.sortAnchorX,
            object.y + asset.sortAnchorY,
          ),
          depth: asset.depthAt(
            object.x,
            object.y,
            instanceSortBias: object.sortBias,
          ),
          tieBreaker: object.x,
          footprintOutlines: [
            for (final footprint in geometry.footprints)
              environmentShapeOutline(footprint, object),
          ],
          footprintDepthBias: asset.defaultSortBias + object.sortBias,
        ),
      );
    }
    _staticDepthOrderBySurface.clear();
    for (final surface in document.surfaces) {
      final ordered = sortEnvironmentDepthEntities(
        entities
            .where(
              (entity) => _objectDepthSurfaceIdsById[entity.id] == surface.id,
            )
            .toList(),
      );
      _staticDepthOrderBySurface[surface.id] = List.unmodifiable(ordered);
    }
    _staticDepthOrder = List.unmodifiable([
      for (final surface in _orderedSurfaces())
        ...?_staticDepthOrderBySurface[surface.id],
    ]);
    _sceneDepthCacheBuildCount++;
  }

  EnvironmentDepthEntity<_SceneEntry> _playerDepthEntity() {
    final actor = WorldPoint(playerPosition.x, playerPosition.y);
    return EnvironmentDepthEntity(
      id: 'player',
      value: const _SceneEntry.player(),
      contact: actor,
      depth: actor.x + actor.y,
      tieBreaker: double.infinity,
    );
  }

  EnvironmentDepthEntity<_SceneEntry> _animalDepthEntity(_ActiveAnimal animal) {
    final actor = WorldPoint(animal.position.x, animal.position.y);
    return EnvironmentDepthEntity(
      id: animal.id,
      value: _SceneEntry.animal(animal.id),
      contact: actor,
      depth: actor.x + actor.y,
      tieBreaker: actor.x,
    );
  }

  List<_DynamicDepthEntry> _dynamicDepthEntries(
    String surfaceId,
    List<EnvironmentDepthEntity<_SceneEntry>> staticOrder,
  ) {
    final entities = <EnvironmentDepthEntity<_SceneEntry>>[
      if (_playerSurfaceId == surfaceId) _playerDepthEntity(),
      for (final id in _activeAnimalIds)
        if (_animalStatesById[id] case final animal?)
          if (animal.surfaceId == surfaceId) _animalDepthEntity(animal),
    ];
    final entries = [
      for (final entity in entities)
        _DynamicDepthEntry(
          insertionIndex: environmentDepthInsertionIndex(staticOrder, entity),
          entity: entity,
        ),
    ];
    entries.sort((left, right) {
      final insertion = left.insertionIndex.compareTo(right.insertionIndex);
      if (insertion != 0) return insertion;
      final depth = left.entity.depth.compareTo(right.entity.depth);
      if (depth != 0) return depth;
      return left.entity.id.compareTo(right.entity.id);
    });
    return entries;
  }

  void _renderDynamicSceneEntry(
    ui.Canvas canvas,
    _SceneEntry entry, {
    required _LiquidSpritePass liquidPass,
  }) {
    if (liquidPass == _LiquidSpritePass.submerged) return;
    if (entry.isPlayer) {
      _renderPlayer(canvas);
      return;
    }
    final animalId = entry.animalId;
    if (animalId != null) {
      final animal = _animalStatesById[animalId];
      if (animal != null) _renderAnimal(canvas, animal);
    }
  }

  List<_SceneEntry> _depthSortedSceneEntries(String surfaceId) {
    final staticOrder =
        _staticDepthOrderBySurface[surfaceId] ??
        const <EnvironmentDepthEntity<_SceneEntry>>[];
    final dynamicEntries = _dynamicDepthEntries(surfaceId, staticOrder);
    var dynamicIndex = 0;
    final entries = <_SceneEntry>[];
    for (var index = 0; index <= staticOrder.length; index++) {
      while (dynamicIndex < dynamicEntries.length &&
          dynamicEntries[dynamicIndex].insertionIndex == index) {
        entries.add(dynamicEntries[dynamicIndex++].entity.value);
      }
      if (index < staticOrder.length) {
        entries.add(staticOrder[index].value);
      }
    }
    return entries;
  }

  void _renderObject(
    ui.Canvas canvas,
    PlacedEnvironmentObject object, {
    required _LiquidSpritePass liquidPass,
  }) {
    final asset = environmentCatalog.objectById(object.assetId);
    if (asset == null) return;
    final surface =
        _objectSurfacesById[object.id] ??
        _surfaceAt(
          Vector2(object.x, object.y),
          surfaceId: object.supportSurfaceId,
        );
    if (liquidPass == _LiquidSpritePass.submerged &&
        (!surface.hasLiquid ||
            _liquidInteractionFor(object, asset) ==
                EnvironmentLiquidInteraction.ignore)) {
      return;
    }
    final view = asset.viewFor(object.direction.name);
    final image = _loadedImages[view.imagePath];
    if (image == null) return;
    final width =
        (view.logicalWidth > 0 ? view.logicalWidth : image.width) *
        asset.renderScale;
    final height =
        (view.logicalHeight > 0 ? view.logicalHeight : image.height) *
        asset.renderScale;
    final anchor = _projectAtElevation(
      Vector2(object.x, object.y),
      _objectElevation(object, asset, surface: surface),
    );
    final destination = ui.Rect.fromLTWH(
      anchor.x - width * view.pivotX,
      anchor.y - height * view.pivotY,
      width,
      height,
    );
    final liquidOcclusionPath = surface.hasLiquid
        ? _cachedLiquidOcclusionPath(object, asset, surface, destination)
        : null;
    _drawObjectFrame(
      canvas,
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      destination,
      object,
      asset,
      surface: surface,
      liquidOcclusionPath: liquidOcclusionPath,
      liquidPass: liquidPass,
    );
  }

  ui.Path? _cachedLiquidOcclusionPath(
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset,
    EnvironmentSurfaceSample surface,
    ui.Rect destination,
  ) {
    final cached = _liquidOcclusionPathsById[object.id];
    if (cached != null) return cached;
    if (_objectsWithoutLiquidOcclusionPath.contains(object.id)) return null;
    final geometry = environmentCatalog.geometryForAsset(
      asset,
      direction: object.direction.name,
    );
    final boundary = environmentFootprintFrontBoundary([
      for (final footprint in geometry.footprints)
        environmentShapeOutline(footprint, object),
    ]);
    if (boundary.length < 2) {
      _objectsWithoutLiquidOcclusionPath.add(object.id);
      return null;
    }
    final projected = [
      for (final point in boundary)
        _projectAtElevation(
          Vector2(point.x, point.y),
          surface.liquidSurfaceElevation!,
        ),
    ];
    final path = ui.Path()
      ..moveTo(destination.left, projected.first.y)
      ..lineTo(projected.first.x, projected.first.y);
    for (final point in projected.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    path
      ..lineTo(destination.right, projected.last.y)
      ..lineTo(destination.right, destination.bottom)
      ..lineTo(destination.left, destination.bottom)
      ..close();
    _liquidOcclusionPathsById[object.id] = path;
    return path;
  }

  EnvironmentLiquidInteraction _liquidInteractionFor(
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset,
  ) {
    if (object.liquidInteraction != EnvironmentLiquidInteraction.automatic) {
      return object.liquidInteraction;
    }
    final words = <String>{
      asset.family.toLowerCase(),
      asset.name.toLowerCase(),
      for (final tag in asset.tags) tag.toLowerCase(),
    }.join(' ');
    return words.contains('boat') || words.contains('ship')
        ? EnvironmentLiquidInteraction.float
        : EnvironmentLiquidInteraction.submerge;
  }

  double _objectElevation(
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset, {
    EnvironmentSurfaceSample? surface,
  }) {
    surface ??= _surfaceAt(
      Vector2(object.x, object.y),
      surfaceId: object.supportSurfaceId,
    );
    final interaction = _liquidInteractionFor(object, asset);
    if (surface.hasLiquid &&
        interaction == EnvironmentLiquidInteraction.float) {
      return surface.liquidSurfaceElevation! -
          object.liquidDraft +
          object.verticalOffset;
    }
    return surface.groundElevation + object.verticalOffset;
  }

  void _drawObjectFrame(
    ui.Canvas canvas,
    ui.Image image,
    ui.Rect source,
    ui.Rect destination,
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset, {
    EnvironmentSurfaceSample? surface,
    ui.Path? liquidOcclusionPath,
    required _LiquidSpritePass liquidPass,
  }) {
    surface ??= _surfaceAt(
      Vector2(object.x, object.y),
      surfaceId: object.supportSurfaceId,
    );
    final interaction = _liquidInteractionFor(object, asset);
    if (!surface.hasLiquid ||
        interaction == EnvironmentLiquidInteraction.ignore) {
      if (liquidPass == _LiquidSpritePass.exposed) {
        canvas.drawImageRect(image, source, destination, ui.Paint());
      }
      return;
    }
    final groundAnchor = projection.worldToScreen(Vector2(object.x, object.y));
    final waterline =
        groundAnchor.y -
        surface.liquidSurfaceElevation! * elevationPixelsPerWorldUnit;
    final overlayTop = math.max(destination.top, waterline);
    if (liquidOcclusionPath == null && overlayTop >= destination.bottom) {
      if (liquidPass == _LiquidSpritePass.exposed) {
        canvas.drawImageRect(image, source, destination, ui.Paint());
      }
      return;
    }

    canvas.save();
    if (liquidPass == _LiquidSpritePass.submerged) {
      if (liquidOcclusionPath != null) {
        canvas.clipPath(liquidOcclusionPath);
      } else {
        canvas.clipRect(
          ui.Rect.fromLTRB(
            destination.left,
            overlayTop,
            destination.right,
            destination.bottom,
          ),
        );
      }
    } else if (liquidOcclusionPath != null) {
      canvas.clipPath(
        ui.Path.combine(
          ui.PathOperation.difference,
          ui.Path()..addRect(destination),
          liquidOcclusionPath,
        ),
      );
    } else if (overlayTop > destination.top) {
      canvas.clipRect(
        ui.Rect.fromLTRB(
          destination.left,
          destination.top,
          destination.right,
          overlayTop,
        ),
      );
    } else {
      canvas.clipRect(ui.Rect.zero);
    }
    canvas.drawImageRect(image, source, destination, ui.Paint());
    canvas.restore();
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
    final position = _projectGround(playerPosition);
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

  void _renderAnimal(ui.Canvas canvas, _ActiveAnimal animal) {
    final animation = animal.asset.animalAnimation!;
    final clip = animation.clipFor(animal.activity.name);
    final image = _loadedImages[clip.imagePath];
    if (image == null) return;
    final rawFrame = (animal.animationTime * clip.framesPerSecond).floor();
    final frame = clip.pingPong && clip.frames > 1
        ? () {
            final period = clip.frames * 2 - 2;
            final phase = rawFrame % period;
            return phase < clip.frames ? phase : period - phase;
          }()
        : rawFrame % clip.frames;
    final row = animation.rowForDirection(animal.facing.name);
    final sourceWidth = image.width / clip.frames;
    final sourceHeight = image.height / animation.directionRows.length;
    final view = animal.asset.views.values.first;
    final position = _projectGround(
      animal.position,
      surfaceId: animal.surfaceId,
    );
    final width = animation.frameWidth * animal.asset.renderScale;
    final height = animation.frameHeight * animal.asset.renderScale;
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
        frame * sourceWidth,
        row * sourceHeight,
        sourceWidth,
        sourceHeight,
      ),
      ui.Rect.fromLTWH(
        position.x - width * view.pivotX,
        position.y - height * view.pivotY,
        width,
        height,
      ),
      ui.Paint(),
    );
  }

  void _renderTarget(ui.Canvas canvas) {
    final target = _destination;
    if (target == null) return;
    final center = _projectGround(target);
    final points = [
      _projectGround(target + Vector2(-0.28, -0.28)),
      _projectGround(target + Vector2(0.28, -0.28)),
      _projectGround(target + Vector2(0.28, 0.28)),
      _projectGround(target + Vector2(-0.28, 0.28)),
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
        _depthDebugLabel(asset, object),
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

  String _depthDebugLabel(
    EnvironmentObjectAsset asset,
    PlacedEnvironmentObject object,
  ) {
    final depth = asset.depthAt(
      object.x,
      object.y,
      instanceSortBias: object.sortBias,
    );
    final span = environmentObjectFootprintDepthSpan(
      asset,
      object,
      geometry: environmentCatalog.geometryForAsset(
        asset,
        direction: object.direction.name,
      ),
    );
    return span == null
        ? '${asset.renderBand.name} ${depth.toStringAsFixed(2)}'
        : '${asset.renderBand.name} ${depth.toStringAsFixed(2)} '
              '[${span.back.toStringAsFixed(2)}..${span.front.toStringAsFixed(2)}]';
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
      final geometry = environmentCatalog.geometryForAsset(
        asset,
        direction: object.direction.name,
      );
      for (final footprint in geometry.footprints) {
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
    _navigationPathPaint.strokeWidth = 3 / zoom;
    final cell = navigationGrid.cellSize;
    final minX = math.max(0.0, playerPosition.x - 5);
    final maxX = math.min(worldManifest.width, playerPosition.x + 5);
    final minY = math.max(0.0, playerPosition.y - 5);
    final maxY = math.min(worldManifest.height, playerPosition.y + 5);
    for (var y = minY; y <= maxY; y += cell) {
      for (var x = minX; x <= maxX; x += cell) {
        final point = WorldPoint(x + cell / 2, y + cell / 2);
        if (!navigationGrid.isCellBlocked(point)) continue;
        final center = projection.worldToScreen(Vector2(point.x, point.y));
        canvas.drawCircle(
          center.toOffset(),
          2.2 / zoom,
          _navigationBlockedPaint,
        );
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
      canvas.drawPath(path, _navigationPathPaint);
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
    _navigationRequestSerial++;
    _nativeNavigationWorld?.close();
    _nativeNavigationWorld = null;
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

  Vector2 get _cameraProjectedPosition => _projectGround(playerPosition);
}

class _CharacterImages {
  const _CharacterImages({required this.idle, required this.walk});

  final ui.Image idle;
  final ui.Image walk;
}

enum _AnimalActivity { idle, walk, run, action }

enum _LiquidSpritePass { submerged, exposed }

class _ActiveAnimal {
  _ActiveAnimal({
    required this.id,
    required this.asset,
    required this.profile,
    required Vector2 home,
    required this.facing,
    required int randomSeed,
    required this.surfaceId,
  }) : home = home.clone(),
       position = home.clone(),
       random = math.Random(randomSeed) {
    remainingActivitySeconds = randomDuration();
  }

  final String id;
  final EnvironmentObjectAsset asset;
  final AnimalBehaviorProfile profile;
  final Vector2 home;
  final Vector2 position;
  final math.Random random;
  final List<Vector2> waypoints = [];
  String surfaceId;
  EnvironmentDirection facing;
  _AnimalActivity activity = _AnimalActivity.idle;
  double animationTime = 0;
  double remainingActivitySeconds = 0;
  bool pathPending = false;
  int pathSerial = 0;

  bool get isMoving => waypoints.isNotEmpty;

  double randomDuration() =>
      profile.minimumPauseSeconds +
      random.nextDouble() *
          (profile.maximumPauseSeconds - profile.minimumPauseSeconds);

  void setActivity(_AnimalActivity value, {double duration = 0}) {
    if (activity != value) animationTime = 0;
    activity = value;
    remainingActivitySeconds = duration;
  }
}

class _DynamicDepthEntry {
  const _DynamicDepthEntry({
    required this.insertionIndex,
    required this.entity,
  });

  final int insertionIndex;
  final EnvironmentDepthEntity<_SceneEntry> entity;
}

class _SceneEntry {
  const _SceneEntry._({this.object, this.animalId, this.isPlayer = false});

  factory _SceneEntry.object(PlacedEnvironmentObject object) =>
      _SceneEntry._(object: object);

  const _SceneEntry.player() : this._(isPlayer: true);

  factory _SceneEntry.animal(String id) => _SceneEntry._(animalId: id);

  final PlacedEnvironmentObject? object;
  final String? animalId;
  final bool isPlayer;

  String get debugId => object?.id ?? animalId ?? 'player';
}
