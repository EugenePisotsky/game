import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/cache.dart';
import 'package:flame/components.dart' show Anchor, FpsComponent;
import 'package:flame/game.dart';
import 'package:flame/sprite.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

import 'editor_controller.dart';

class EditorGame extends FlameGame {
  EditorGame(
    this.controller, {
    this.loadedChunks,
    this.playerSpawn,
    WorldPoint? initialWorldCenter,
    this.chunkSize = 32,
  }) : _viewCenterWorld = initialWorldCenter {
    images = Images(prefix: neuraAssetPrefix);
  }

  final EditorController controller;
  final Set<EnvironmentChunkCoordinate> Function()? loadedChunks;
  final WorldPoint Function()? playerSpawn;
  final double chunkSize;
  WorldPoint? _viewCenterWorld;
  final IsometricProjection projection = const IsometricProjection();
  final Vector2 _panOffset = Vector2.zero();
  final Vector2 _panVelocity = Vector2.zero();
  final Map<String, ui.Image> _loadedImages = {};
  final Map<String, Sprite> _sprites = {};
  final Map<String, (int, int)> _sourceImageSizes = {};
  final Map<String, int> _imageLastUsedFrame = {};
  final Set<String> _materialImagePaths = {};
  final Set<String> _loadingImages = {};
  final Map<String, ui.Paint> _repeatingPaints = {};
  final Map<String, ui.Paint> _decalPaints = {};
  final Map<EnvironmentChunkCoordinate, _TerrainRaster> _terrainRasters = {};
  final Set<EnvironmentChunkCoordinate> _emptyTerrainRasters = {};
  final Set<EnvironmentChunkCoordinate> _dirtyTerrainChunks = {};
  EnvironmentChunkCoordinate? _terrainBakeInFlight;
  int _seenTerrainRevision = -1;
  int _terrainCacheGeneration = 0;
  final FpsComponent _fpsComponent = FpsComponent(windowSize: 60);
  final Stopwatch _performanceWatch = Stopwatch();
  final Map<String, _EditorRenderEntry> _renderEntriesById = {};
  final Map<EnvironmentRenderBand, List<_EditorRenderEntry>>
  _renderEntriesByBand = {
    for (final band in EnvironmentRenderBand.values) band: [],
  };
  final Map<(int, int), List<_EditorRenderEntry>> _spatialRenderEntries = {};
  int _seenSceneRevision = -1;
  int _imageRevision = 0;
  int _seenImageRevision = -1;
  int _updateMicroseconds = 0;
  int _renderMicroseconds = 0;
  int _renderCandidateCount = 0;
  int _visibleSpriteCount = 0;
  int _lastHitTestCandidateCount = 0;
  int _lastHitTestMicroseconds = 0;
  int _renderIndexFullRebuildCount = 0;
  int _renderIndexIncrementalUpdateCount = 0;
  int _frameNumber = 0;
  int _requestedFrames = 3;
  bool _autoPaused = false;
  bool _isPanning = false;
  ui.Rect? _marqueeScreenRect;
  double zoom = 0.42;
  bool showDiagnostics = true;
  bool showRenderDebug = false;
  bool showGeometryDebug = false;
  bool showChunkDebug = false;
  bool showNavigationDebug = false;
  bool diagnosticsPaused = false;

  static const double elevationPixelsPerWorldUnit = 64;
  static const int _terrainRasterLowResolution = 1024;
  static const int _terrainRasterHighResolution = 2048;
  static const double _terrainHighResolutionZoom = 0.3;
  static const double _terrainHighResolutionMargin = 512;
  static const double _terrainDirectRenderZoom = 0.7;
  static const double _spatialCellSize = 256;
  static const double _liquidOpticalDepthScale = 1.25;

  static double _liquidOpticalDepth(double depth) =>
      1 - math.exp(-math.max(0, depth) / _liquidOpticalDepthScale);
  static const int _editorObjectBaseDimension = 512;
  static const int _editorObjectMaximumDimension = 4096;
  static const int _imageCacheBudgetBytes = 160 << 20;

  int get decodedImageCount => _loadedImages.length;
  int get decodedImageBytes => _loadedImages.values.fold(
    0,
    (sum, image) => sum + image.width * image.height * 4,
  );
  int get pendingImageCount => _loadingImages.length;
  int get terrainPictureCount =>
      _terrainRasters.length + _emptyTerrainRasters.length;
  int get terrainRasterCount => _terrainRasters.length;
  int get terrainRasterBytes => _terrainRasters.values.fold(
    0,
    (bytes, raster) => bytes + raster.image.width * raster.image.height * 4,
  );
  int get highResolutionTerrainRasterCount => _terrainRasters.values
      .where((raster) => raster.resolution == _terrainRasterHighResolution)
      .length;
  bool get usesDirectTerrainRendering =>
      loadedChunks != null &&
      (zoom >= _terrainDirectRenderZoom || _hasElevatedTerrain);

  bool get _hasElevatedTerrain => controller.document.surfaces.any(
    (surface) =>
        surface.height.elevation != 0 || surface.height.endElevation != 0,
  );
  int get pendingTerrainBakeCount =>
      _dirtyTerrainChunks.length + (_terrainBakeInFlight == null ? 0 : 1);
  int get updateTime => _updateMicroseconds ~/ 1000;
  int get renderTime => _renderMicroseconds ~/ 1000;
  double get updateMilliseconds => _updateMicroseconds / 1000;
  double get renderMilliseconds => _renderMicroseconds / 1000;
  int get renderCandidateCount => _renderCandidateCount;
  int get visibleSpriteCount => _visibleSpriteCount;
  int get culledSpriteCount => _renderCandidateCount - _visibleSpriteCount;
  int get lastHitTestCandidateCount => _lastHitTestCandidateCount;
  double get lastHitTestMilliseconds => _lastHitTestMicroseconds / 1000;
  int get renderIndexFullRebuildCount => _renderIndexFullRebuildCount;
  int get renderIndexIncrementalUpdateCount =>
      _renderIndexIncrementalUpdateCount;
  double get diagnosticsFps => _fpsComponent.fps;
  double get diagnosticsFrameMilliseconds =>
      diagnosticsFps <= 0 ? 0 : 1000 / diagnosticsFps;
  bool get isAutoIdle => _autoPaused;

  /// Wakes the Flame loop long enough to paint a stable editor frame.
  ///
  /// Unlike a running game, the editor is usually static. Keeping its loop at
  /// the display refresh rate needlessly competes with Flutter's sidebar and
  /// pointer handling. Every visual mutation calls this method; animations and
  /// asynchronous work keep the loop awake until they settle.
  void requestFrame({int frames = 2}) {
    if (frames > _requestedFrames) _requestedFrames = frames;
    if (diagnosticsPaused) return;
    if (_autoPaused || paused) {
      _autoPaused = false;
      resumeEngine();
    }
  }

  void togglePause() {
    diagnosticsPaused = !diagnosticsPaused;
    if (diagnosticsPaused) {
      _autoPaused = false;
      pauseEngine();
    } else {
      requestFrame(frames: 3);
    }
  }

  void stepDebug() {
    if (diagnosticsPaused) stepEngine();
  }

  final ui.Paint _mapOutlinePaint = ui.Paint()
    ..color = const ui.Color(0x669BB7A4)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _cursorPaint = ui.Paint()
    ..color = const ui.Color(0x99E9C46A)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _selectionPaint = ui.Paint()
    ..color = const ui.Color(0xFFE9C46A)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 3;
  final ui.Paint _animalHomePaint = ui.Paint()
    ..color = const ui.Color(0x8878C6A3)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final ui.Paint _hoverPaint = ui.Paint()
    ..color = const ui.Color(0xFF78C6A3)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _marqueePaint = ui.Paint()
    ..color = const ui.Color(0xAA78C6A3)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final ui.Paint _terrainResetPaint = ui.Paint()
    ..blendMode = ui.BlendMode.clear;
  final ui.Paint _footprintPaint = ui.Paint()
    ..color = const ui.Color(0xDD4EA8DE)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _liquidOcclusionGeometryPaint = ui.Paint()
    ..color = const ui.Color(0xFF4DE3FF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 3;
  final ui.Paint _blockingPaint = ui.Paint()
    ..color = const ui.Color(0xDDE76F51)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2.5;
  final ui.Paint _walkablePaint = ui.Paint()
    ..color = const ui.Color(0xDD6FCF97)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _clearancePaint = ui.Paint()
    ..color = const ui.Color(0xFFE9C46A)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _blockedClearancePaint = ui.Paint()
    ..color = const ui.Color(0xFFFF4D4D)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 3;
  final ui.Paint _geometryGridPaint = ui.Paint()
    ..color = const ui.Color(0x2258D68D)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1;
  final ui.Paint _selectionGeometryPaint = ui.Paint()
    ..color = const ui.Color(0xDDB987FF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _spawnPaint = ui.Paint()
    ..color = const ui.Color(0xFF64D8FF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 3;
  final ui.Paint _pathPreviewSpritePaint = ui.Paint()
    ..color = const ui.Color(0xAAFFFFFF);
  final ui.Paint _pathPreviewLinePaint = ui.Paint()
    ..color = const ui.Color(0xFF64D8FF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _pathHandleFillPaint = ui.Paint()
    ..color = const ui.Color(0xFF10241F)
    ..style = ui.PaintingStyle.fill;
  final ui.Paint _pathHandleStrokePaint = ui.Paint()
    ..color = const ui.Color(0xFF64D8FF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2.5;
  final ui.Paint _connectorPaint = ui.Paint()
    ..color = const ui.Color(0xFFB987FF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 3;
  final ui.Paint _connectorPreviewPaint = ui.Paint()
    ..color = const ui.Color(0xAAB987FF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;

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

  @override
  ui.Color backgroundColor() => const ui.Color(0xFF111713);

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    await add(_fpsComponent);
    final materialIds = <String>{
      controller.document.baseMaterialId,
      controller.selectedMaterialId,
      for (final region in controller.document.terrainRegions)
        if (!region.resetsToDefault) region.materialId,
      for (final stroke in controller.document.terrainStrokes)
        stroke.materialId,
      for (final surface in controller.document.surfaces) surface.materialId,
      for (final liquid in controller.document.liquidVolumes) liquid.materialId,
    };
    final materialPaths = <String>{};
    for (final id in materialIds) {
      final material = controller.catalog.materialById(id);
      if (material != null) {
        materialPaths
          ..add(material.texturePath)
          ..add(material.decalPath);
      }
    }
    _materialImagePaths.addAll(materialPaths);
    await Future.wait([for (final path in materialPaths) _loadImage(path)]);
    for (final id in materialIds) {
      _createMaterialPaints(id);
    }
    final preloadBounds = _visibleProjectedBounds.inflate(1024);
    final preloadRequests = <String, int>{};
    for (final object in controller.document.objects) {
      final asset = controller.catalog.objectById(object.assetId);
      if (asset == null) continue;
      final view = asset.viewFor(object.direction.name);
      final anchor = projection
          .worldToScreen(Vector2(object.x, object.y))
          .toOffset();
      if (preloadBounds.contains(anchor)) {
        final maximumDimension = _objectDecodeMaximumDimension(asset, view);
        preloadRequests.update(
          view.imagePath,
          (current) => math.max(current, maximumDimension),
          ifAbsent: () => maximumDimension,
        );
      }
    }
    await Future.wait([
      for (final request in preloadRequests.entries)
        _loadImage(request.key, maximumDimension: request.value),
    ]);
    requestFrame(frames: 3);
  }

  Future<ui.Image?> _loadImage(String path, {int? maximumDimension}) async {
    final existing = _loadedImages[path];
    if (existing != null &&
        _decodedImageMeetsRequest(path, existing, maximumDimension)) {
      _touchImage(path);
      return existing;
    }
    if (!_loadingImages.add(path)) return null;
    try {
      final loaded = await _loadUncachedImage(
        path,
        maximumDimension: maximumDimension,
      );
      final image = loaded.image;
      final previous = _loadedImages[path];
      _loadedImages[path] = image;
      _sprites[path] = Sprite(image);
      _sourceImageSizes[path] = (loaded.sourceWidth, loaded.sourceHeight);
      _touchImage(path);
      if (previous == null) {
        _imageRevision++;
      } else {
        previous.dispose();
      }
      requestFrame(frames: 2);
      return image;
    } finally {
      _loadingImages.remove(path);
      requestFrame();
    }
  }

  Future<WorkspaceEnvironmentImage> _loadUncachedImage(
    String path, {
    int? maximumDimension,
  }) => loadWorkspaceEnvironmentImageForEditor(
    path,
    maximumDimension: maximumDimension,
  );

  bool _decodedImageMeetsRequest(
    String path,
    ui.Image image,
    int? maximumDimension,
  ) {
    final sourceSize = _sourceImageSizes[path];
    if (sourceSize == null) return maximumDimension != null;
    final sourceMaximum = math.max(sourceSize.$1, sourceSize.$2);
    final requestedMaximum = math.min(
      maximumDimension ?? sourceMaximum,
      sourceMaximum,
    );
    return math.max(image.width, image.height) >= requestedMaximum;
  }

  void _touchImage(String path) {
    _imageLastUsedFrame[path] = _frameNumber;
  }

  void _evictUnusedImages() {
    var bytes = decodedImageBytes;
    if (bytes <= _imageCacheBudgetBytes) return;
    final candidates =
        _loadedImages.keys
            .where((path) => !_materialImagePaths.contains(path))
            .toList()
          ..sort(
            (a, b) => (_imageLastUsedFrame[a] ?? -1).compareTo(
              _imageLastUsedFrame[b] ?? -1,
            ),
          );
    var changed = false;
    for (final path in candidates) {
      if (bytes <= _imageCacheBudgetBytes) break;
      if ((_imageLastUsedFrame[path] ?? -1) >= _frameNumber - 30) continue;
      final image = _loadedImages.remove(path);
      if (image == null) continue;
      _sprites.remove(path);
      _imageLastUsedFrame.remove(path);
      bytes -= image.width * image.height * 4;
      image.dispose();
      changed = true;
    }
    if (changed) _imageRevision++;
  }

  Future<void> _loadMaterial(String id) async {
    if (_repeatingPaints.containsKey(id) && _decalPaints.containsKey(id)) {
      return;
    }
    final material = controller.catalog.materialById(id);
    if (material == null) return;
    _materialImagePaths
      ..add(material.texturePath)
      ..add(material.decalPath);
    final texture = await _loadImage(material.texturePath);
    final decal = await _loadImage(material.decalPath);
    if (texture == null || decal == null) return;
    _createMaterialPaints(id);
  }

  void _createMaterialPaints(String id) {
    final material = controller.catalog.materialById(id);
    if (material == null) return;
    final texture = _loadedImages[material.texturePath];
    final decal = _loadedImages[material.decalPath];
    if (texture == null || decal == null) return;
    _repeatingPaints[id] = ui.Paint()
      ..shader = ui.ImageShader(
        texture,
        ui.TileMode.repeated,
        ui.TileMode.repeated,
        _identityMatrix,
      );
    _decalPaints[id] = ui.Paint()
      ..shader = ui.ImageShader(
        decal,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        _identityMatrix,
      );
  }

  Future<void> _loadObjectView(PlacedEnvironmentObject object) async {
    final asset = controller.catalog.objectById(object.assetId);
    if (asset == null) return;
    final view = asset.viewFor(object.direction.name);
    await _loadImage(
      view.imagePath,
      maximumDimension: _objectDecodeMaximumDimension(asset, view),
    );
  }

  int _objectDecodeMaximumDimension(
    EnvironmentObjectAsset asset,
    EnvironmentObjectView view,
  ) {
    final knownSourceSize = _sourceImageSizes[view.imagePath];
    final animation = asset.animalAnimation;
    final sourceWidth =
        knownSourceSize?.$1 ??
        (animation == null
            ? view.logicalWidth
            : animation.frameWidth * animation.idle.frames);
    final sourceHeight =
        knownSourceSize?.$2 ??
        (animation == null
            ? view.logicalHeight
            : animation.frameHeight * animation.directionRows.length);
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return _editorObjectBaseDimension;
    }
    final views = ui.PlatformDispatcher.instance.views;
    final devicePixelRatio = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
    final requiredDimension =
        math.max(
          view.logicalWidth > 0 ? view.logicalWidth : sourceWidth,
          view.logicalHeight > 0 ? view.logicalHeight : sourceHeight,
        ) *
        asset.renderScale *
        zoom *
        devicePixelRatio;
    if (animation != null) {
      final frameMaximum = math.max(
        animation.frameWidth,
        animation.frameHeight,
      );
      final atlasMaximum = math.max(sourceWidth, sourceHeight);
      final requiredAtlasDimension =
          requiredDimension * atlasMaximum / frameMaximum;
      return requiredAtlasDimension.ceil().clamp(1, atlasMaximum);
    }
    for (final tier in const [512, 1024, 2048, 3072, 4096]) {
      if (requiredDimension <= tier) {
        return math.min(tier, math.max(sourceWidth, sourceHeight));
      }
    }
    return math.min(
      _editorObjectMaximumDimension,
      math.max(sourceWidth, sourceHeight),
    );
  }

  WorldPoint? worldAtScreen(Vector2 screen) {
    if (!isLoaded) return null;
    final projected = _projectedAtScreen(screen);
    final world = _projectedToVisibleSurface(projected);
    final point = WorldPoint(world.x, world.y);
    return controller.document.contains(point.x, point.y) ? point : null;
  }

  List<WorldPoint> worldPolygonForScreenRect(ui.Rect screenRect) {
    final result = <WorldPoint>[];
    for (final screen in [
      Vector2(screenRect.left, screenRect.top),
      Vector2(screenRect.right, screenRect.top),
      Vector2(screenRect.right, screenRect.bottom),
      Vector2(screenRect.left, screenRect.bottom),
    ]) {
      final world = _projectedToVisibleSurface(_projectedAtScreen(screen));
      result.add(
        WorldPoint(
          world.x.clamp(0, controller.document.width).toDouble(),
          world.y.clamp(0, controller.document.height).toDouble(),
        ),
      );
    }
    return result;
  }

  List<String> hitTestObjectIds(Vector2 screen) {
    if (!isLoaded) return const [];
    _ensureRenderIndex();
    _performanceWatch
      ..reset()
      ..start();
    final point = _projectedAtScreen(screen).toOffset();
    final candidates = <_EditorRenderEntry>[
      for (final entry
          in _spatialRenderEntries[_spatialCellFor(point)] ?? const [])
        if (!controller.isLayerLocked(entry.object.editorLayerId) &&
            entry.projectedBounds.contains(point))
          entry,
    ]..sort(_compareRenderEntries);
    _performanceWatch.stop();
    _lastHitTestCandidateCount = candidates.length;
    _lastHitTestMicroseconds = _performanceWatch.elapsedMicroseconds;
    return [for (final entry in candidates.reversed) entry.object.id];
  }

  EnvironmentGeometryHandle? hitTestSelectedGeometryHandle(
    Vector2 screen, {
    double radius = 12,
  }) {
    if (!isLoaded) return null;
    final object = controller.selectedObject;
    final shape = controller.selectedGeometryShape;
    if (object == null || shape == null) return null;
    final elevation = _surfaceAt(
      WorldPoint(object.x, object.y),
      surfaceId: object.supportSurfaceId,
    ).groundElevation;
    EnvironmentGeometryHandle? nearest;
    var nearestDistanceSquared = radius * radius;
    for (final candidate in _geometryHandlePoints(shape)) {
      final world = transformEnvironmentGeometryPoint(candidate.local, object);
      final vertexScreen = _screenForWorldPoint(world, elevation: elevation);
      final distanceSquared = vertexScreen.distanceToSquared(screen);
      if (distanceSquared <= nearestDistanceSquared) {
        nearest = candidate.handle;
        nearestDistanceSquared = distanceSquared;
      }
    }
    return nearest;
  }

  int? hitTestSelectedGeometryVertex(Vector2 screen, {double radius = 12}) {
    final handle = hitTestSelectedGeometryHandle(screen, radius: radius);
    return handle?.type == EnvironmentGeometryHandleType.polygonVertex
        ? handle!.index
        : null;
  }

  int? hitTestSelectedTerrainPoint(Vector2 screen, {double radius = 12}) {
    if (!isLoaded) return null;
    final points = controller.selectedEnvironmentAreaPoints;
    if (points == null) return null;
    int? nearest;
    var nearestDistanceSquared = radius * radius;
    for (var index = 0; index < points.length; index++) {
      final vertexScreen = _screenForWorldPoint(
        points[index],
        elevation: controller.selectedEnvironmentAreaElevationAt(points[index]),
      );
      final distanceSquared = vertexScreen.distanceToSquared(screen);
      if (distanceSquared <= nearestDistanceSquared) {
        nearest = index;
        nearestDistanceSquared = distanceSquared;
      }
    }
    return nearest;
  }

  int? hitTestSelectedLiquidDepthHandle(Vector2 screen, {double radius = 12}) {
    if (!isLoaded) return null;
    final liquid = controller.selectedLiquidVolume;
    if (liquid == null || !liquid.hasDepthRamp) return null;
    final handles = [liquid.depthRampStart!, liquid.depthRampEnd!];
    int? nearest;
    var nearestDistanceSquared = radius * radius;
    for (var index = 0; index < handles.length; index++) {
      final handleScreen = _screenForWorldPoint(
        handles[index],
        elevation: liquid.surfaceElevation,
      );
      final distanceSquared = handleScreen.distanceToSquared(screen);
      if (distanceSquared <= nearestDistanceSquared) {
        nearest = index;
        nearestDistanceSquared = distanceSquared;
      }
    }
    return nearest;
  }

  List<String> objectIdsInMarquee(
    ui.Rect screenRect, {
    bool requireContainment = false,
  }) {
    _ensureRenderIndex();
    final projectedRect = _projectedBoundsForScreenRect(screenRect);
    final entries = _entriesOverlapping(projectedRect);
    final result = <_EditorRenderEntry>[];
    for (final entry in entries) {
      if (controller.isLayerLocked(entry.object.editorLayerId)) continue;
      final projected = entry.projectedBounds;
      final bounds = _screenBoundsForProjected(projected);
      final included = requireContainment
          ? screenRect.contains(bounds.topLeft) &&
                screenRect.contains(bounds.bottomRight)
          : screenRect.overlaps(bounds);
      if (included) result.add(entry);
    }
    result.sort(_compareRenderEntries);
    return [for (final entry in result) entry.object.id];
  }

  void setSelectionMarquee(ui.Rect? rect) {
    _marqueeScreenRect = rect;
    requestFrame();
  }

  EnvironmentObjectBounds visibleWorldBounds() {
    final corners = [
      Vector2.zero(),
      Vector2(size.x, 0),
      Vector2(size.x, size.y),
      Vector2(0, size.y),
    ].map(_projectedAtScreen).map(projection.screenToWorld).toList();
    return EnvironmentObjectBounds(
      minX: corners.map((point) => point.x).reduce(math.min),
      minY: corners.map((point) => point.y).reduce(math.min),
      maxX: corners.map((point) => point.x).reduce(math.max),
      maxY: corners.map((point) => point.y).reduce(math.max),
    );
  }

  void beginPan() {
    _isPanning = true;
    _panVelocity.setZero();
    requestFrame(frames: 3);
  }

  void panByScreenDelta(Vector2 delta, {required double elapsedSeconds}) {
    _panOffset.add(delta);
    final seconds = elapsedSeconds.clamp(1 / 240, 1 / 15);
    final instantaneous = delta / seconds;
    _panVelocity
      ..scale(0.62)
      ..add(instantaneous * 0.38);
    requestFrame(frames: 3);
  }

  void endPan() {
    _isPanning = false;
    requestFrame(frames: 3);
  }

  void zoomBy(double factor) {
    zoom = (zoom * factor).clamp(0.2, 1.4);
    requestFrame(frames: 3);
  }

  void rebaseWorld(WorldPoint shift) {
    final center = _viewCenterWorld;
    if (center != null) {
      _viewCenterWorld = WorldPoint(center.x + shift.x, center.y + shift.y);
    }
    _clearTerrainRasters();
    requestFrame(frames: 3);
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    requestFrame(frames: 3);
  }

  @override
  void update(double dt) {
    _performanceWatch
      ..reset()
      ..start();
    try {
      super.update(dt);
      if (!_isPanning && _panVelocity.length2 > 1) {
        _panOffset.add(_panVelocity * dt);
        _panVelocity.scale(math.exp(-6.5 * dt));
        if (_panVelocity.length < 8) _panVelocity.setZero();
      }
      if (_frameNumber != 0 && _frameNumber % 60 == 0) {
        _evictUnusedImages();
      }
      final hasContinuousWork =
          _isPanning ||
          _panVelocity.length2 > 1 ||
          _loadingImages.isNotEmpty ||
          _terrainBakeInFlight != null ||
          _dirtyTerrainChunks.isNotEmpty;
      if (hasContinuousWork) {
        _requestedFrames = math.max(_requestedFrames, 2);
      } else if (_requestedFrames > 0) {
        _requestedFrames--;
      } else if (!diagnosticsPaused && !_autoPaused) {
        _autoPaused = true;
        pauseEngine();
      }
    } finally {
      _performanceWatch.stop();
      _updateMicroseconds = _performanceWatch.elapsedMicroseconds;
    }
  }

  @override
  void render(ui.Canvas canvas) {
    _performanceWatch
      ..reset()
      ..start();
    try {
      super.render(canvas);
      if (!isLoaded) return;
      _frameNumber++;
      _ensureRenderIndex();
      _renderCandidateCount = 0;
      _visibleSpriteCount = 0;
      canvas
        ..save()
        ..translate(size.x / 2 + _panOffset.x, size.y / 2 + _panOffset.y)
        ..scale(zoom)
        ..translate(-_mapCenterScreen.x, -_mapCenterScreen.y);

      if (controller.document.surfaces.length > 1) {
        _renderLayeredEnvironment(canvas);
      } else {
        _renderBaseGround(canvas);
        if (loadedChunks == null) {
          canvas.saveLayer(_visibleProjectedBounds, ui.Paint());
          for (final region in controller.document.terrainRegions) {
            _renderTerrainRegion(canvas, region);
          }
          canvas.restore();
          canvas.saveLayer(_visibleProjectedBounds, ui.Paint());
          for (final stroke in controller.document.terrainStrokes) {
            _renderStroke(canvas, stroke);
          }
          canvas.restore();
        } else {
          if (_hasElevatedTerrain) {
            canvas.saveLayer(_visibleProjectedBounds, ui.Paint());
            for (final region in controller.document.terrainRegions) {
              _renderTerrainRegion(canvas, region);
            }
            canvas.restore();
            canvas.saveLayer(_visibleProjectedBounds, ui.Paint());
            for (final stroke in controller.document.terrainStrokes) {
              _renderStroke(canvas, stroke);
            }
            canvas.restore();
          } else if (zoom >= _terrainDirectRenderZoom) {
            _evictStaleTerrainRasters();
            _renderDirectChunkTerrain(canvas);
          } else {
            _synchronizeTerrainRasters();
            _renderRasterChunkTerrain(canvas);
          }
          final activeStroke = controller.activeTerrainStroke;
          if (activeStroke != null) _renderStroke(canvas, activeStroke);
        }
        if (controller.document.liquidVolumes.isNotEmpty) {
          _renderAllObjectBands(
            canvas,
            liquidPass: _LiquidSpritePass.submerged,
          );
        }
        _renderLiquidVolumes(canvas);
        _renderAllObjectBands(canvas, liquidPass: _LiquidSpritePass.exposed);
      }
      _renderSurfaceConnectors(canvas);
      _renderPathPreview(canvas);
      _renderSurfacePolygonPreview(canvas);
      _renderMapOutline(canvas);
      _renderPlayerSpawn(canvas);
      if (showRenderDebug) _renderDepthDebug(canvas);
      if (showChunkDebug) _renderChunkBoundaries(canvas);
      if (controller.mode == EnvironmentEditorMode.collision ||
          showGeometryDebug) {
        _renderGeometry(canvas);
      }
      if (showNavigationDebug) _renderNavigationCells(canvas);
      _renderSelection(canvas);
      _renderCursor(canvas);
      canvas.restore();
      final marquee = _marqueeScreenRect;
      if (marquee != null) canvas.drawRect(marquee, _marqueePaint);
    } finally {
      _performanceWatch.stop();
      _renderMicroseconds = _performanceWatch.elapsedMicroseconds;
    }
  }

  void _renderBaseGround(ui.Canvas canvas) {
    final document = controller.document;
    final paint = _repeatingPaints[document.baseMaterialId];
    if (paint == null) {
      _loadMaterial(document.baseMaterialId);
      return;
    }
    final texture = controller.catalog.materialById(document.baseMaterialId)!;
    final image = _loadedImages[texture.texturePath]!;
    final texelsPerWorldUnitX = image.width / texture.effectiveRepeatWorldWidth;
    final texelsPerWorldUnitY =
        image.height / texture.effectiveRepeatWorldHeight;
    final chunks = loadedChunks?.call();
    if (chunks == null) {
      _drawTexturedWorldQuad(
        canvas,
        const WorldPoint(0, 0),
        WorldPoint(document.width.toDouble(), document.height.toDouble()),
        paint,
        ui.Rect.fromLTWH(
          0,
          0,
          document.width * texelsPerWorldUnitX,
          document.height * texelsPerWorldUnitY,
        ),
        image,
      );
      return;
    }
    final visible = _visibleProjectedBounds;
    for (final chunk in chunks) {
      if (!_chunkProjectedBounds(chunk).overlaps(visible)) continue;
      final minX = chunk.x * chunkSize;
      final minY = chunk.y * chunkSize;
      final maxX = math.min(document.width.toDouble(), minX + chunkSize);
      final maxY = math.min(document.height.toDouble(), minY + chunkSize);
      _drawTexturedWorldQuad(
        canvas,
        WorldPoint(minX, minY),
        WorldPoint(maxX, maxY),
        paint,
        ui.Rect.fromLTWH(
          minX * texelsPerWorldUnitX,
          minY * texelsPerWorldUnitY,
          (maxX - minX) * texelsPerWorldUnitX,
          (maxY - minY) * texelsPerWorldUnitY,
        ),
        image,
      );
    }
  }

  void _renderLayeredEnvironment(ui.Canvas canvas) {
    final surfaces = [...controller.document.surfaces]
      ..sort((a, b) {
        final order = a.order.compareTo(b.order);
        if (order != 0) return order;
        return a.height.elevation.compareTo(b.height.elevation);
      });
    for (final surface in surfaces) {
      if (surface.id == environmentBaseSurfaceId) {
        _renderBaseGround(canvas);
      } else if (surface.drawsBaseMaterial) {
        _renderPhysicalSurface(canvas, surface);
      }
      canvas.saveLayer(_visibleProjectedBounds, ui.Paint());
      for (final region in controller.document.terrainRegions) {
        if (region.surfaceId == surface.id) {
          _renderTerrainRegion(canvas, region);
        }
      }
      canvas.restore();
      canvas.saveLayer(_visibleProjectedBounds, ui.Paint());
      for (final stroke in controller.document.terrainStrokes) {
        if (stroke.surfaceId == surface.id) _renderStroke(canvas, stroke);
      }
      final activeStroke = controller.activeTerrainStroke;
      if (activeStroke != null && activeStroke.surfaceId == surface.id) {
        _renderStroke(canvas, activeStroke);
      }
      canvas.restore();
      final liquids =
          controller.document.liquidVolumes
              .where((liquid) => liquid.bedSurfaceId == surface.id)
              .toList()
            ..sort((a, b) => a.order.compareTo(b.order));
      if (liquids.isNotEmpty) {
        _renderAllObjectBands(
          canvas,
          surfaceId: surface.id,
          liquidPass: _LiquidSpritePass.submerged,
        );
      }
      for (final liquid in liquids) {
        _renderLiquidVolume(canvas, liquid);
      }
      _renderAllObjectBands(
        canvas,
        surfaceId: surface.id,
        liquidPass: _LiquidSpritePass.exposed,
      );
    }
  }

  void _renderAllObjectBands(
    ui.Canvas canvas, {
    String? surfaceId,
    required _LiquidSpritePass liquidPass,
  }) {
    for (final band in EnvironmentRenderBand.values) {
      _renderObjectBand(
        canvas,
        band,
        surfaceId: surfaceId,
        liquidPass: liquidPass,
      );
    }
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
    final liquids = [...controller.document.liquidVolumes]
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
    final material = controller.catalog.materialById(liquid.materialId);
    final basePaint = _repeatingPaints[liquid.materialId];
    if (material == null) return;
    if (basePaint?.shader == null ||
        !_loadedImages.containsKey(material.texturePath)) {
      _loadMaterial(liquid.materialId);
      return;
    }
    final image = _loadedImages[material.texturePath]!;
    final path = _worldPolygonPath(
      liquid.points,
      elevation: liquid.surfaceElevation,
    );
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
      image,
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

  void _renderStroke(ui.Canvas canvas, TerrainStroke stroke) {
    if (stroke.points.isEmpty) return;
    if (stroke.resetsToBase) {
      canvas.drawPath(
        _worldSurfacePolygonPath(stroke.points, stroke.surfaceId),
        _terrainResetPaint,
      );
      return;
    }
    final material = controller.catalog.materialById(stroke.materialId);
    final paint = _decalPaints[stroke.materialId];
    if (material == null) return;
    if (paint == null) {
      _loadMaterial(stroke.materialId);
      return;
    }
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
    final path = _worldSurfacePolygonPath(region.points, region.surfaceId);
    if (region.resetsToDefault) {
      canvas.drawPath(path, _terrainResetPaint);
      return;
    }
    final material = controller.catalog.materialById(region.materialId);
    final paint = _repeatingPaints[region.materialId];
    if (material == null) return;
    if (paint == null) {
      _loadMaterial(region.materialId);
      return;
    }
    final image = _loadedImages[material.texturePath]!;
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
      image,
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

  void _synchronizeTerrainRasters() {
    _evictStaleTerrainRasters();
    final chunks = loadedChunks!.call();

    final revision = controller.terrainRevision;
    if (_seenTerrainRevision != revision) {
      final changedStroke = revision == _seenTerrainRevision + 1
          ? controller.lastTerrainChangedStroke
          : null;
      for (final coordinate in chunks) {
        if (changedStroke == null ||
            _strokeAffectsChunk(changedStroke, coordinate)) {
          _dirtyTerrainChunks.add(coordinate);
        }
      }
      _seenTerrainRevision = revision;
    }

    for (final coordinate in chunks) {
      final raster = _terrainRasters[coordinate];
      final isCached =
          raster != null || _emptyTerrainRasters.contains(coordinate);
      final resolutionChanged =
          raster != null &&
          raster.resolution != _terrainResolutionForChunk(coordinate);
      if ((!isCached || resolutionChanged) &&
          coordinate != _terrainBakeInFlight) {
        _dirtyTerrainChunks.add(coordinate);
      }
    }

    if (_terrainBakeInFlight == null && _dirtyTerrainChunks.isNotEmpty) {
      final coordinate = _nextTerrainChunkToBake();
      _dirtyTerrainChunks.remove(coordinate);
      unawaited(_bakeTerrainChunk(coordinate));
    }
  }

  void _evictStaleTerrainRasters() {
    final chunks = loadedChunks!.call();
    final stale = <EnvironmentChunkCoordinate>{
      ..._terrainRasters.keys.where(
        (coordinate) => !chunks.contains(coordinate),
      ),
      ..._emptyTerrainRasters.where(
        (coordinate) => !chunks.contains(coordinate),
      ),
    };
    for (final coordinate in stale) {
      _terrainRasters.remove(coordinate)?.dispose();
      _emptyTerrainRasters.remove(coordinate);
      _dirtyTerrainChunks.remove(coordinate);
    }
    _dirtyTerrainChunks.removeWhere(
      (coordinate) => !chunks.contains(coordinate),
    );
  }

  EnvironmentChunkCoordinate _nextTerrainChunkToBake() {
    final highResolutionBounds = _visibleProjectedBounds.inflate(
      _terrainHighResolutionMargin,
    );
    for (final coordinate in _dirtyTerrainChunks) {
      if (_terrainResolutionForChunk(coordinate) ==
              _terrainRasterHighResolution &&
          _chunkProjectedBounds(coordinate).overlaps(highResolutionBounds)) {
        return coordinate;
      }
    }
    return _dirtyTerrainChunks.first;
  }

  int _terrainResolutionForChunk(EnvironmentChunkCoordinate coordinate) {
    if (zoom < _terrainHighResolutionZoom) {
      return _terrainRasterLowResolution;
    }
    final highResolutionBounds = _visibleProjectedBounds.inflate(
      _terrainHighResolutionMargin,
    );
    return _chunkProjectedBounds(coordinate).overlaps(highResolutionBounds)
        ? _terrainRasterHighResolution
        : _terrainRasterLowResolution;
  }

  void _renderRasterChunkTerrain(ui.Canvas canvas) {
    final visible = _visibleProjectedBounds;
    for (final coordinate in loadedChunks!.call()) {
      if (!_chunkProjectedBounds(coordinate).overlaps(visible)) continue;
      final needsFallback =
          _dirtyTerrainChunks.contains(coordinate) ||
          _terrainBakeInFlight == coordinate ||
          (!_terrainRasters.containsKey(coordinate) &&
              !_emptyTerrainRasters.contains(coordinate));
      if (needsFallback) {
        _renderDirectTerrainForChunk(canvas, coordinate);
        continue;
      }

      final raster = _terrainRasters[coordinate];
      if (raster == null) continue;
      final minX = coordinate.x * chunkSize;
      final minY = coordinate.y * chunkSize;
      _drawTexturedWorldQuad(
        canvas,
        WorldPoint(minX, minY),
        WorldPoint(minX + chunkSize, minY + chunkSize),
        raster.paint,
        ui.Rect.fromLTWH(
          0,
          0,
          raster.image.width.toDouble(),
          raster.image.height.toDouble(),
        ),
        raster.image,
      );
    }
  }

  void _renderDirectChunkTerrain(ui.Canvas canvas) {
    final visible = _visibleProjectedBounds;
    for (final coordinate in loadedChunks!.call()) {
      if (_chunkProjectedBounds(coordinate).overlaps(visible)) {
        _renderDirectTerrainForChunk(canvas, coordinate);
      }
    }
  }

  void _renderDirectTerrainForChunk(
    ui.Canvas canvas,
    EnvironmentChunkCoordinate coordinate,
  ) {
    final bounds = _chunkProjectedBounds(coordinate);
    canvas.saveLayer(bounds, ui.Paint());
    canvas.clipPath(_chunkPath(coordinate));
    for (final region in controller.document.terrainRegions) {
      if (_regionAffectsChunk(region, coordinate)) {
        _renderTerrainRegion(canvas, region);
      }
    }
    canvas.restore();

    final activeStroke = controller.activeTerrainStroke;
    canvas.saveLayer(bounds, ui.Paint());
    canvas.clipPath(_chunkPath(coordinate));
    for (final stroke in controller.document.terrainStrokes) {
      if (!identical(stroke, activeStroke) &&
          _strokeAffectsChunk(stroke, coordinate)) {
        _renderStroke(canvas, stroke);
      }
    }
    canvas.restore();
  }

  Future<void> _bakeTerrainChunk(EnvironmentChunkCoordinate coordinate) async {
    final resolution = _terrainResolutionForChunk(coordinate);
    final activeStroke = controller.activeTerrainStroke;
    final regions = controller.document.terrainRegions
        .where((region) => _regionAffectsChunk(region, coordinate))
        .toList();
    final strokes = controller.document.terrainStrokes
        .where(
          (stroke) =>
              !identical(stroke, activeStroke) &&
              _strokeAffectsChunk(stroke, coordinate),
        )
        .toList();
    for (final region in regions) {
      if (region.resetsToDefault) continue;
      final material = controller.catalog.materialById(region.materialId);
      if (material == null) continue;
      if (!_loadedImages.containsKey(material.texturePath)) {
        unawaited(_loadMaterial(region.materialId));
        _dirtyTerrainChunks.add(coordinate);
        return;
      }
    }
    for (final stroke in strokes) {
      if (stroke.resetsToBase) continue;
      final material = controller.catalog.materialById(stroke.materialId);
      if (material == null) continue;
      if (!_loadedImages.containsKey(material.decalPath)) {
        unawaited(_loadMaterial(stroke.materialId));
        _dirtyTerrainChunks.add(coordinate);
        return;
      }
    }

    final chunks = loadedChunks!.call();
    if (!chunks.contains(coordinate)) return;
    if (regions.isEmpty && strokes.isEmpty) {
      _terrainRasters.remove(coordinate)?.dispose();
      _emptyTerrainRasters.add(coordinate);
      return;
    }

    _terrainBakeInFlight = coordinate;
    final generation = _terrainCacheGeneration;
    final originX = coordinate.x * chunkSize;
    final originY = coordinate.y * chunkSize;
    final pixelsPerWorldUnit = resolution / chunkSize;
    final recorder = ui.PictureRecorder();
    final rasterCanvas = ui.Canvas(recorder);
    final rasterBounds = ui.Rect.fromLTWH(
      0,
      0,
      resolution.toDouble(),
      resolution.toDouble(),
    );
    rasterCanvas.saveLayer(rasterBounds, ui.Paint());
    for (final region in regions) {
      _renderRasterTerrainRegion(
        rasterCanvas,
        region,
        originX: originX,
        originY: originY,
        pixelsPerWorldUnit: pixelsPerWorldUnit,
      );
    }
    rasterCanvas.restore();
    rasterCanvas.saveLayer(rasterBounds, ui.Paint());
    for (final stroke in strokes) {
      if (stroke.resetsToBase) {
        final path = ui.Path();
        for (var index = 0; index < stroke.points.length; index++) {
          final point = stroke.points[index];
          final x = (point.x - originX) * pixelsPerWorldUnit;
          final y = (point.y - originY) * pixelsPerWorldUnit;
          index == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
        }
        rasterCanvas.drawPath(path..close(), _terrainResetPaint);
        continue;
      }
      final material = controller.catalog.materialById(stroke.materialId);
      if (material == null) continue;
      final image = _loadedImages[material.decalPath];
      if (image == null) continue;
      final source = ui.Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final paint = ui.Paint()..filterQuality = ui.FilterQuality.low;
      for (final stamp in terrainStrokeStamps(stroke)) {
        paint.color = ui.Color.fromRGBO(255, 255, 255, stamp.opacity);
        final radius = stamp.radius * pixelsPerWorldUnit;
        final centerX = (stamp.center.x - originX) * pixelsPerWorldUnit;
        final centerY = (stamp.center.y - originY) * pixelsPerWorldUnit;
        rasterCanvas.drawImageRect(
          image,
          source,
          ui.Rect.fromLTWH(
            centerX - radius,
            centerY - radius,
            radius * 2,
            radius * 2,
          ),
          paint,
        );
      }
    }
    rasterCanvas.restore();
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(resolution, resolution);
      if (generation != _terrainCacheGeneration ||
          !loadedChunks!.call().contains(coordinate)) {
        image.dispose();
        return;
      }
      if (resolution != _terrainResolutionForChunk(coordinate)) {
        image.dispose();
        _dirtyTerrainChunks.add(coordinate);
        return;
      }
      final raster = _TerrainRaster(
        image,
        ui.Paint()
          ..filterQuality = ui.FilterQuality.low
          ..shader = ui.ImageShader(
            image,
            ui.TileMode.clamp,
            ui.TileMode.clamp,
            _identityMatrix,
          ),
      );
      _terrainRasters.remove(coordinate)?.dispose();
      _terrainRasters[coordinate] = raster;
      _emptyTerrainRasters.remove(coordinate);
    } catch (_) {
      if (generation == _terrainCacheGeneration &&
          loadedChunks!.call().contains(coordinate)) {
        _dirtyTerrainChunks.add(coordinate);
      }
    } finally {
      picture.dispose();
      if (generation == _terrainCacheGeneration) {
        _terrainBakeInFlight = null;
      }
      requestFrame(frames: 2);
    }
  }

  bool _strokeAffectsChunk(
    TerrainStroke stroke,
    EnvironmentChunkCoordinate coordinate,
  ) {
    if (stroke.points.isEmpty) return false;
    final extent = stroke.maximumStampExtent;
    final minX =
        stroke.points.map((point) => point.x).reduce(math.min) - extent;
    final minY =
        stroke.points.map((point) => point.y).reduce(math.min) - extent;
    final maxX =
        stroke.points.map((point) => point.x).reduce(math.max) + extent;
    final maxY =
        stroke.points.map((point) => point.y).reduce(math.max) + extent;
    return EnvironmentObjectBounds(
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
    ).overlapsChunk(coordinate, chunkSize);
  }

  bool _regionAffectsChunk(
    TerrainRegion region,
    EnvironmentChunkCoordinate coordinate,
  ) {
    if (region.points.length < 3) return false;
    final minX = region.points.map((point) => point.x).reduce(math.min);
    final minY = region.points.map((point) => point.y).reduce(math.min);
    final maxX = region.points.map((point) => point.x).reduce(math.max);
    final maxY = region.points.map((point) => point.y).reduce(math.max);
    return EnvironmentObjectBounds(
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
    ).overlapsChunk(coordinate, chunkSize);
  }

  void _renderRasterTerrainRegion(
    ui.Canvas canvas,
    TerrainRegion region, {
    required double originX,
    required double originY,
    required double pixelsPerWorldUnit,
  }) {
    final path = ui.Path();
    for (var index = 0; index < region.points.length; index++) {
      final point = region.points[index];
      final x = (point.x - originX) * pixelsPerWorldUnit;
      final y = (point.y - originY) * pixelsPerWorldUnit;
      index == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    path.close();
    if (region.resetsToDefault) {
      canvas.drawPath(path, _terrainResetPaint);
      return;
    }
    final material = controller.catalog.materialById(region.materialId);
    if (material == null) return;
    final image = _loadedImages[material.texturePath];
    if (image == null) return;
    final tileWorldWidth =
        material.effectiveRepeatWorldWidth * region.textureScale;
    final tileWorldHeight =
        material.effectiveRepeatWorldHeight * region.textureScale;
    if (tileWorldWidth <= 0 || tileWorldHeight <= 0) return;
    final softness = region.edgeBlend.clamp(0, 3).toDouble();
    final minX = math.max(
      originX,
      region.points.map((point) => point.x).reduce(math.min) - softness,
    );
    final minY = math.max(
      originY,
      region.points.map((point) => point.y).reduce(math.min) - softness,
    );
    final maxX = math.min(
      originX + chunkSize,
      region.points.map((point) => point.x).reduce(math.max) + softness,
    );
    final maxY = math.min(
      originY + chunkSize,
      region.points.map((point) => point.y).reduce(math.max) + softness,
    );
    final firstTileX = (minX / tileWorldWidth).floor();
    final firstTileY = (minY / tileWorldHeight).floor();
    final lastTileX = (maxX / tileWorldWidth).ceil();
    final lastTileY = (maxY / tileWorldHeight).ceil();
    final source = ui.Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.low;
    final needsMask = softness > 0 || region.opacity < 0.999;
    final layerBounds = ui.Rect.fromLTWH(
      0,
      0,
      chunkSize * pixelsPerWorldUnit,
      chunkSize * pixelsPerWorldUnit,
    );
    if (needsMask) {
      canvas.saveLayer(layerBounds, ui.Paint());
    } else {
      canvas.save();
      canvas.clipPath(path);
    }
    for (var tileY = firstTileY; tileY < lastTileY; tileY++) {
      for (var tileX = firstTileX; tileX < lastTileX; tileX++) {
        canvas.drawImageRect(
          image,
          source,
          ui.Rect.fromLTWH(
            (tileX * tileWorldWidth - originX) * pixelsPerWorldUnit,
            (tileY * tileWorldHeight - originY) * pixelsPerWorldUnit,
            tileWorldWidth * pixelsPerWorldUnit,
            tileWorldHeight * pixelsPerWorldUnit,
          ),
          paint,
        );
      }
    }
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
              : ui.MaskFilter.blur(
                  ui.BlurStyle.normal,
                  softness * pixelsPerWorldUnit,
                ),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  ui.Path _worldPolygonPath(List<WorldPoint> points, {double elevation = 0}) {
    final path = ui.Path();
    for (var index = 0; index < points.length; index++) {
      final projected = projection.worldToScreen(
        Vector2(points[index].x, points[index].y),
      );
      projected.y -= elevation * elevationPixelsPerWorldUnit;
      index == 0
          ? path.moveTo(projected.x, projected.y)
          : path.lineTo(projected.x, projected.y);
    }
    return path..close();
  }

  double _surfaceElevationAt(String surfaceId, WorldPoint point) =>
      controller.document.surfaceById(surfaceId)?.elevationAt(point) ?? 0;

  ui.Path _worldSurfacePolygonPath(List<WorldPoint> points, String surfaceId) {
    final path = ui.Path();
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final projected = projection.worldToScreen(Vector2(point.x, point.y));
      projected.y -=
          _surfaceElevationAt(surfaceId, point) * elevationPixelsPerWorldUnit;
      index == 0
          ? path.moveTo(projected.x, projected.y)
          : path.lineTo(projected.x, projected.y);
    }
    return path..close();
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
      image,
      elevation: elevation,
      blendMode: blendMode,
    );
  }

  void _drawTexturedWorldQuad(
    ui.Canvas canvas,
    WorldPoint min,
    WorldPoint max,
    ui.Paint paint,
    ui.Rect textureRect,
    ui.Image image, {
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
    final positions = Float32List.fromList([
      for (final corner in corners) ...[corner.x, corner.y],
    ]);
    final textureCoordinates = Float32List.fromList([
      textureRect.left,
      textureRect.top,
      textureRect.right,
      textureRect.top,
      textureRect.right,
      textureRect.bottom,
      textureRect.left,
      textureRect.bottom,
    ]);
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangleFan,
      positions,
      textureCoordinates: textureCoordinates,
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

  EnvironmentSurfaceSample _surfaceAt(WorldPoint point, {String? surfaceId}) =>
      environmentSurfaceAtPoint(
        controller.document,
        point,
        preferredSurfaceId: surfaceId,
      );

  Vector2 _projectedToVisibleSurface(Vector2 projected) {
    var world = projection.screenToWorld(projected);
    for (var iteration = 0; iteration < 4; iteration++) {
      final surface = _surfaceAt(WorldPoint(world.x, world.y));
      final elevation =
          surface.liquidSurfaceElevation ?? surface.groundElevation;
      world = projection.screenToWorld(
        projected + Vector2(0, elevation * elevationPixelsPerWorldUnit),
      );
    }
    return world;
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
      WorldPoint(object.x, object.y),
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
      WorldPoint(object.x, object.y),
      surfaceId: object.supportSurfaceId,
    );
    final interaction = _liquidInteractionFor(object, asset);
    final submerges =
        surface.hasLiquid && interaction != EnvironmentLiquidInteraction.ignore;
    if (!submerges) {
      if (liquidPass == _LiquidSpritePass.exposed) {
        canvas.drawImageRect(image, source, destination, ui.Paint());
      }
      return;
    }

    final anchor = projection.worldToScreen(Vector2(object.x, object.y));
    final waterline =
        anchor.y -
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

  void _renderObjectBand(
    ui.Canvas canvas,
    EnvironmentRenderBand band, {
    String? surfaceId,
    required _LiquidSpritePass liquidPass,
  }) {
    final entries = _renderEntriesByBand[band]!;
    final visible = _visibleProjectedBounds;
    if (liquidPass == _LiquidSpritePass.exposed) {
      _renderCandidateCount += surfaceId == null
          ? entries.length
          : entries.where((entry) => entry.depthSurfaceId == surfaceId).length;
    }
    for (final entry in entries) {
      if (surfaceId != null && entry.depthSurfaceId != surfaceId) {
        continue;
      }
      if (!entry.projectedBounds.overlaps(visible)) continue;
      if (liquidPass == _LiquidSpritePass.submerged &&
          (!entry.surface.hasLiquid ||
              _liquidInteractionFor(entry.object, entry.asset) ==
                  EnvironmentLiquidInteraction.ignore)) {
        continue;
      }
      if (liquidPass == _LiquidSpritePass.exposed) _visibleSpriteCount++;
      final object = entry.object;
      final view = entry.view;
      final sprite = _sprites[view.imagePath];
      final requestedDimension = _objectDecodeMaximumDimension(
        entry.asset,
        view,
      );
      if (sprite == null ||
          !_decodedImageMeetsRequest(
            view.imagePath,
            sprite.image,
            requestedDimension,
          )) {
        unawaited(
          _loadImage(view.imagePath, maximumDimension: requestedDimension),
        );
      }
      if (sprite == null) {
        continue;
      }
      _touchImage(view.imagePath);
      final animation = entry.asset.animalAnimation;
      if (animation != null) {
        final image = sprite.image;
        final clip = animation.idle;
        final cellWidth = image.width / clip.frames;
        final cellHeight = image.height / animation.directionRows.length;
        final row = animation.rowForDirection(object.direction.name);
        _drawObjectFrame(
          canvas,
          image,
          ui.Rect.fromLTWH(0, row * cellHeight, cellWidth, cellHeight),
          entry.projectedBounds,
          object,
          entry.asset,
          surface: entry.surface,
          liquidOcclusionPath: entry.liquidOcclusionPath,
          liquidPass: liquidPass,
        );
        continue;
      }
      _drawObjectFrame(
        canvas,
        sprite.image,
        ui.Rect.fromLTWH(
          0,
          0,
          sprite.image.width.toDouble(),
          sprite.image.height.toDouble(),
        ),
        entry.projectedBounds,
        object,
        entry.asset,
        surface: entry.surface,
        liquidOcclusionPath: entry.liquidOcclusionPath,
        liquidPass: liquidPass,
      );
    }
  }

  void _renderPathPreview(ui.Canvas canvas) {
    if (controller.mode != EnvironmentEditorMode.path) return;
    final start = controller.pathStart;
    final end = controller.pathEnd;
    if (start != null && end != null) {
      final startSurface = _surfaceAt(start);
      final endSurface = _surfaceAt(end);
      final startScreen = projection.worldToScreen(Vector2(start.x, start.y))
        ..y -=
            (startSurface.liquidSurfaceElevation ??
                startSurface.groundElevation) *
            elevationPixelsPerWorldUnit;
      final endScreen = projection.worldToScreen(Vector2(end.x, end.y))
        ..y -=
            (endSurface.liquidSurfaceElevation ?? endSurface.groundElevation) *
            elevationPixelsPerWorldUnit;
      canvas.drawLine(
        startScreen.toOffset(),
        endScreen.toOffset(),
        _pathPreviewLinePaint,
      );
    }
    final asset = controller.catalog.objectById(
      controller.selectedObjectAssetId,
    );
    if (asset == null) return;
    for (final placement in controller.pathPreviewPlacements) {
      final view = asset.viewFor(placement.direction.name);
      final sprite = _sprites[view.imagePath];
      final sourceSize = _sourceImageSizes[view.imagePath];
      if (sprite == null || sourceSize == null) {
        unawaited(
          _loadImage(
            view.imagePath,
            maximumDimension: _objectDecodeMaximumDimension(asset, view),
          ),
        );
        continue;
      }
      final requestedDimension = _objectDecodeMaximumDimension(asset, view);
      if (!_decodedImageMeetsRequest(
        view.imagePath,
        sprite.image,
        requestedDimension,
      )) {
        unawaited(
          _loadImage(view.imagePath, maximumDimension: requestedDimension),
        );
      }
      _touchImage(view.imagePath);
      final position = projection.worldToScreen(
        Vector2(placement.point.x, placement.point.y),
      );
      position.y -=
          _surfaceAt(
            placement.point,
            surfaceId: controller.document.activeSurfaceId,
          ).groundElevation *
          elevationPixelsPerWorldUnit;
      sprite.render(
        canvas,
        position: position,
        size: Vector2(
          sourceSize.$1 * asset.renderScale,
          sourceSize.$2 * asset.renderScale,
        ),
        anchor: Anchor(view.pivotX, view.pivotY),
        overridePaint: _pathPreviewSpritePaint,
      );
    }
    if (start != null && end != null) {
      for (final point in [start, end]) {
        final surface = _surfaceAt(
          point,
          surfaceId: controller.document.activeSurfaceId,
        );
        final elevation =
            surface.liquidSurfaceElevation ?? surface.groundElevation;
        final projected = projection.worldToScreen(Vector2(point.x, point.y))
          ..y -= elevation * elevationPixelsPerWorldUnit;
        final handle = projected.toOffset();
        canvas
          ..drawCircle(handle, 6, _pathHandleFillPaint)
          ..drawCircle(handle, 6, _pathHandleStrokePaint);
      }
    }
  }

  Vector2 _projectConnectorPoint(WorldPoint point, String surfaceId) {
    final elevation =
        controller.document.surfaceById(surfaceId)?.elevationAt(point) ?? 0;
    return projection.worldToScreen(Vector2(point.x, point.y))
      ..y -= elevation * elevationPixelsPerWorldUnit;
  }

  void _renderSurfaceConnectors(ui.Canvas canvas) {
    if (controller.mode != EnvironmentEditorMode.connector &&
        !showGeometryDebug) {
      return;
    }
    for (final connector in controller.document.surfaceConnectors) {
      final from = _projectConnectorPoint(
        connector.from,
        connector.fromSurfaceId,
      );
      final to = _projectConnectorPoint(connector.to, connector.toSurfaceId);
      canvas
        ..drawLine(from.toOffset(), to.toOffset(), _connectorPaint)
        ..drawCircle(from.toOffset(), 6, _pathHandleFillPaint)
        ..drawCircle(from.toOffset(), 6, _connectorPaint)
        ..drawCircle(to.toOffset(), 6, _pathHandleFillPaint)
        ..drawCircle(to.toOffset(), 6, _connectorPaint);
    }
    if (controller.mode != EnvironmentEditorMode.connector) return;
    final start = controller.connectorStart;
    final target = controller.connectorTargetSurface;
    final hover = controller.hoveredPoint;
    if (start == null || target == null) return;
    final from = _projectConnectorPoint(
      start,
      controller.document.activeSurfaceId,
    );
    final to = hover == null ? from : _projectConnectorPoint(hover, target.id);
    canvas
      ..drawLine(from.toOffset(), to.toOffset(), _connectorPreviewPaint)
      ..drawCircle(from.toOffset(), 6, _pathHandleFillPaint)
      ..drawCircle(from.toOffset(), 6, _connectorPaint);
  }

  void _renderSelection(ui.Canvas canvas) {
    final areaPoints = controller.selectedEnvironmentAreaPoints;
    if (areaPoints != null) {
      final path = ui.Path();
      for (var index = 0; index < areaPoints.length; index++) {
        final point = areaPoints[index];
        final projected = projection.worldToScreen(Vector2(point.x, point.y))
          ..y -=
              controller.selectedEnvironmentAreaElevationAt(point) *
              elevationPixelsPerWorldUnit;
        index == 0
            ? path.moveTo(projected.x, projected.y)
            : path.lineTo(projected.x, projected.y);
      }
      canvas.drawPath(path..close(), _selectionPaint);
      if (controller.mode == EnvironmentEditorMode.editGround) {
        for (final point in areaPoints) {
          final projected = projection.worldToScreen(Vector2(point.x, point.y))
            ..y -=
                controller.selectedEnvironmentAreaElevationAt(point) *
                elevationPixelsPerWorldUnit;
          canvas
            ..drawCircle(projected.toOffset(), 6, _pathHandleFillPaint)
            ..drawCircle(projected.toOffset(), 6, _pathHandleStrokePaint);
        }
        final liquid = controller.selectedLiquidVolume;
        if (liquid != null && liquid.hasDepthRamp) {
          final start = projection.worldToScreen(
            Vector2(liquid.depthRampStart!.x, liquid.depthRampStart!.y),
          )..y -= liquid.surfaceElevation * elevationPixelsPerWorldUnit;
          final end = projection.worldToScreen(
            Vector2(liquid.depthRampEnd!.x, liquid.depthRampEnd!.y),
          )..y -= liquid.surfaceElevation * elevationPixelsPerWorldUnit;
          canvas
            ..drawLine(
              start.toOffset(),
              end.toOffset(),
              _liquidOcclusionGeometryPaint,
            )
            ..drawCircle(start.toOffset(), 8, _pathHandleFillPaint)
            ..drawCircle(start.toOffset(), 8, _liquidOcclusionGeometryPaint)
            ..drawCircle(end.toOffset(), 8, _pathHandleFillPaint)
            ..drawCircle(end.toOffset(), 8, _selectionGeometryPaint);
        }
      }
    }
    final hoveredId = controller.hoveredObjectId;
    if (hoveredId != null &&
        !controller.selectedObjectIds.contains(hoveredId)) {
      final hovered = _objectById(hoveredId);
      final bounds = hovered == null ? null : _objectProjectedBounds(hovered);
      if (bounds != null) canvas.drawRect(bounds, _hoverPaint);
    }
    for (final selected in controller.selectedObjects) {
      final bounds = _objectProjectedBounds(selected);
      if (bounds != null) canvas.drawRect(bounds, _selectionPaint);
      final asset = controller.catalog.objectById(selected.assetId);
      final animation = asset?.animalAnimation;
      final profile = animation == null
          ? null
          : controller.animalBehaviorProfileFor(selected);
      if (profile != null && profile.roamingRadius > 0) {
        final points = [
          for (var index = 0; index < 48; index++)
            WorldPoint(
              selected.x +
                  math.cos(index * math.pi / 24) * profile.roamingRadius,
              selected.y +
                  math.sin(index * math.pi / 24) * profile.roamingRadius,
            ),
        ];
        canvas.drawPath(_worldPolygonPath(points), _animalHomePaint);
      }
    }
  }

  void _renderSurfacePolygonPreview(ui.Canvas canvas) {
    if (controller.mode != EnvironmentEditorMode.surfacePolygon) return;
    final points = controller.surfacePolygonDraft;
    if (points.isEmpty) return;
    final preview = [
      ...points,
      ...[controller.hoveredPoint].whereType<WorldPoint>(),
    ];
    final first = projection.worldToScreen(
      Vector2(preview.first.x, preview.first.y),
    );
    final path = ui.Path()..moveTo(first.x, first.y);
    for (final point in preview.skip(1)) {
      final projected = projection.worldToScreen(Vector2(point.x, point.y));
      path.lineTo(projected.x, projected.y);
    }
    canvas.drawPath(path, _pathPreviewLinePaint);
    for (final point in points) {
      final projected = projection.worldToScreen(Vector2(point.x, point.y));
      canvas
        ..drawCircle(projected.toOffset(), 6, _pathHandleFillPaint)
        ..drawCircle(projected.toOffset(), 6, _pathHandleStrokePaint);
    }
  }

  void _renderGeometry(ui.Canvas canvas) {
    final selected = controller.selectedObject;
    if (selected != null) _renderGeometryMeasurementGrid(canvas, selected);
    for (final object in controller.document.objects) {
      if (!controller.isLayerVisible(object.editorLayerId)) continue;
      final asset = controller.catalog.objectById(object.assetId);
      if (asset == null) continue;
      final geometry = controller.catalog.geometryForAsset(
        asset,
        direction: object.direction.name,
      );
      for (final footprint in geometry.footprints) {
        _drawGeometryShape(canvas, footprint, object, _footprintPaint);
      }
      _drawLiquidOcclusionBoundary(canvas, object, asset, geometry);
      for (final shape in geometry.blocking) {
        _drawGeometryShape(canvas, shape, object, _blockingPaint);
      }
      for (final shape in geometry.walkable) {
        _drawGeometryShape(canvas, shape, object, _walkablePaint);
      }
      for (final shape in geometry.selection) {
        _drawGeometryShape(canvas, shape, object, _selectionGeometryPaint);
      }
      if (object.id == selected?.id) {
        _renderGeometryAnchors(canvas, object, asset);
        _renderSelectedGeometryHandles(canvas, object);
      }
    }
    final cursor = controller.hoveredPoint;
    if (cursor != null) {
      const actorRadius = 0.18;
      final blocked = _isNavigationBlocked(cursor, actorRadius: actorRadius);
      final surface = _surfaceAt(cursor);
      final elevation =
          surface.liquidSurfaceElevation ?? surface.groundElevation;
      final points = [
        for (var index = 0; index < 24; index++)
          WorldPoint(
            cursor.x + math.cos(index * math.pi / 12) * actorRadius,
            cursor.y + math.sin(index * math.pi / 12) * actorRadius,
          ),
      ];
      final first = projection.worldToScreen(
        Vector2(points.first.x, points.first.y),
      )..y -= elevation * elevationPixelsPerWorldUnit;
      final path = ui.Path()..moveTo(first.x, first.y);
      for (final point in points.skip(1)) {
        final projected = projection.worldToScreen(Vector2(point.x, point.y));
        projected.y -= elevation * elevationPixelsPerWorldUnit;
        path.lineTo(projected.x, projected.y);
      }
      canvas.drawPath(
        path..close(),
        blocked ? _blockedClearancePaint : _clearancePaint,
      );
    }
  }

  void _renderGeometryMeasurementGrid(
    ui.Canvas canvas,
    PlacedEnvironmentObject object,
  ) {
    const radius = 3.0;
    const spacing = 0.5;
    final elevation = _surfaceAt(
      WorldPoint(object.x, object.y),
      surfaceId: object.supportSurfaceId,
    ).groundElevation;
    for (var offset = -radius; offset <= radius; offset += spacing) {
      _drawWorldLine(
        canvas,
        WorldPoint(object.x - radius, object.y + offset),
        WorldPoint(object.x + radius, object.y + offset),
        _geometryGridPaint,
        elevation: elevation,
      );
      _drawWorldLine(
        canvas,
        WorldPoint(object.x + offset, object.y - radius),
        WorldPoint(object.x + offset, object.y + radius),
        _geometryGridPaint,
        elevation: elevation,
      );
    }
  }

  void _renderGeometryAnchors(
    ui.Canvas canvas,
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset,
  ) {
    final pivot = projection.worldToScreen(Vector2(object.x, object.y))
      ..y -= _objectElevation(object, asset) * elevationPixelsPerWorldUnit;
    final pivotPaint = ui.Paint()
      ..color = const ui.Color(0xDDB987FF)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2 / zoom;
    final size = 7 / zoom;
    canvas
      ..drawLine(
        pivot.toOffset() + ui.Offset(-size, 0),
        pivot.toOffset() + ui.Offset(size, 0),
        pivotPaint,
      )
      ..drawLine(
        pivot.toOffset() + ui.Offset(0, -size),
        pivot.toOffset() + ui.Offset(0, size),
        pivotPaint,
      );
    final sort = projection.worldToScreen(
      Vector2(object.x + asset.sortAnchorX, object.y + asset.sortAnchorY),
    )..y -= _objectElevation(object, asset) * elevationPixelsPerWorldUnit;
    canvas.drawCircle(
      sort.toOffset(),
      5 / zoom,
      ui.Paint()
        ..color = const ui.Color(0xFFE9C46A)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2 / zoom,
    );
  }

  void _renderSelectedGeometryHandles(
    ui.Canvas canvas,
    PlacedEnvironmentObject object,
  ) {
    final shape = controller.selectedGeometryShape;
    if (shape == null) return;
    final elevation = _surfaceAt(
      WorldPoint(object.x, object.y),
      surfaceId: object.supportSurfaceId,
    ).groundElevation;
    final fill = ui.Paint()
      ..color = const ui.Color(0xFFF7D774)
      ..style = ui.PaintingStyle.fill;
    final outline = ui.Paint()
      ..color = const ui.Color(0xFF181A1B)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2 / zoom;
    for (final candidate in _geometryHandlePoints(shape)) {
      final world = transformEnvironmentGeometryPoint(candidate.local, object);
      final projected = projection.worldToScreen(Vector2(world.x, world.y))
        ..y -= elevation * elevationPixelsPerWorldUnit;
      final center = projected.toOffset();
      if (candidate.handle.type == EnvironmentGeometryHandleType.center) {
        final extent = 5 / zoom;
        canvas
          ..drawRect(
            ui.Rect.fromCenter(
              center: center,
              width: extent * 2,
              height: extent * 2,
            ),
            fill,
          )
          ..drawRect(
            ui.Rect.fromCenter(
              center: center,
              width: extent * 2,
              height: extent * 2,
            ),
            outline,
          );
      } else {
        canvas
          ..drawCircle(center, 6 / zoom, fill)
          ..drawCircle(center, 6 / zoom, outline);
      }
    }
  }

  void _drawWorldLine(
    ui.Canvas canvas,
    WorldPoint start,
    WorldPoint end,
    ui.Paint paint, {
    double elevation = 0,
  }) {
    final a = projection.worldToScreen(Vector2(start.x, start.y));
    final b = projection.worldToScreen(Vector2(end.x, end.y));
    if (elevation != 0) {
      a.y -= elevation * elevationPixelsPerWorldUnit;
      b.y -= elevation * elevationPixelsPerWorldUnit;
    }
    canvas.drawLine(a.toOffset(), b.toOffset(), paint);
  }

  void _renderDepthDebug(ui.Canvas canvas) {
    final paint = ui.Paint()..color = const ui.Color(0xFFE9C46A);
    for (final object in controller.document.objects) {
      if (!controller.isLayerVisible(object.editorLayerId)) continue;
      final asset = controller.catalog.objectById(object.assetId);
      if (asset == null) continue;
      final point = projection.worldToScreen(
        Vector2(object.x + asset.sortAnchorX, object.y + asset.sortAnchorY),
      );
      canvas.drawCircle(point.toOffset(), 4 / zoom, paint);
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(fontSize: 10 / zoom),
      )..pushStyle(ui.TextStyle(color: const ui.Color(0xFFE9C46A)));
      final depth = asset.depthAt(
        object.x,
        object.y,
        instanceSortBias: object.sortBias,
      );
      final span = environmentObjectFootprintDepthSpan(
        asset,
        object,
        geometry: controller.catalog.geometryForAsset(
          asset,
          direction: object.direction.name,
        ),
      );
      builder.addText(
        span == null
            ? '${asset.renderBand.name} ${depth.toStringAsFixed(2)}'
            : '${asset.renderBand.name} ${depth.toStringAsFixed(2)} '
                  '[${span.back.toStringAsFixed(2)}..${span.front.toStringAsFixed(2)}]',
      );
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: 170 / zoom));
      canvas.drawParagraph(
        paragraph,
        point.toOffset() + ui.Offset(7 / zoom, -7 / zoom),
      );
    }
  }

  void _renderNavigationCells(ui.Canvas canvas) {
    final cursor = controller.hoveredPoint;
    if (cursor == null) return;
    const cell = 0.4;
    const radius = 4.0;
    final blockedPaint = ui.Paint()..color = const ui.Color(0x55E76F51);
    final openPaint = ui.Paint()..color = const ui.Color(0x2258D68D);
    for (var y = cursor.y - radius; y <= cursor.y + radius; y += cell) {
      for (var x = cursor.x - radius; x <= cursor.x + radius; x += cell) {
        if (!controller.document.contains(x, y)) continue;
        final point = WorldPoint(x + cell / 2, y + cell / 2);
        final blocked = _isNavigationBlocked(point);
        final projected = projection.worldToScreen(Vector2(point.x, point.y));
        canvas.drawCircle(
          projected.toOffset(),
          1.8 / zoom,
          blocked ? blockedPaint : openPaint,
        );
      }
    }
  }

  bool _isNavigationBlocked(WorldPoint point, {double actorRadius = 0.18}) {
    final material = controller.catalog.materialById(
      environmentMaterialAtPoint(controller.document, point),
    );
    if (material?.blocksMovement ?? false) return true;
    return controller.document.objects.any((object) {
      final asset = controller.catalog.objectById(object.assetId);
      return asset != null &&
          environmentObjectBlocksPoint(
            asset,
            object,
            point,
            actorRadius: actorRadius,
            geometry: controller.catalog.geometryForAsset(
              asset,
              direction: object.direction.name,
            ),
          );
    });
  }

  void _drawGeometryShape(
    ui.Canvas canvas,
    EnvironmentGeometryShape shape,
    PlacedEnvironmentObject object,
    ui.Paint paint,
  ) {
    final points = environmentShapeOutline(shape, object);
    if (points.isEmpty) return;
    final elevation = _surfaceAt(
      WorldPoint(object.x, object.y),
      surfaceId: object.supportSurfaceId,
    ).groundElevation;
    final first = projection.worldToScreen(
      Vector2(points.first.x, points.first.y),
    )..y -= elevation * elevationPixelsPerWorldUnit;
    final path = ui.Path()..moveTo(first.x, first.y);
    for (final point in points.skip(1)) {
      final projected = projection.worldToScreen(Vector2(point.x, point.y));
      projected.y -= elevation * elevationPixelsPerWorldUnit;
      path.lineTo(projected.x, projected.y);
    }
    canvas.drawPath(path..close(), paint);
  }

  void _drawLiquidOcclusionBoundary(
    ui.Canvas canvas,
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset,
    EnvironmentAssetGeometry geometry,
  ) {
    final surface = _surfaceAt(
      WorldPoint(object.x, object.y),
      surfaceId: object.supportSurfaceId,
    );
    if (!surface.hasLiquid ||
        _liquidInteractionFor(object, asset) ==
            EnvironmentLiquidInteraction.ignore) {
      return;
    }
    final boundary = environmentFootprintFrontBoundary([
      for (final footprint in geometry.footprints)
        environmentShapeOutline(footprint, object),
    ]);
    if (boundary.length < 2) return;
    final first = projection.worldToScreen(
      Vector2(boundary.first.x, boundary.first.y),
    )..y -= surface.liquidSurfaceElevation! * elevationPixelsPerWorldUnit;
    final path = ui.Path()..moveTo(first.x, first.y);
    for (final point in boundary.skip(1)) {
      final projected = projection.worldToScreen(Vector2(point.x, point.y))
        ..y -= surface.liquidSurfaceElevation! * elevationPixelsPerWorldUnit;
      path.lineTo(projected.x, projected.y);
    }
    canvas.drawPath(path, _liquidOcclusionGeometryPaint);
  }

  ui.Rect? _objectProjectedBounds(PlacedEnvironmentObject object) {
    _ensureRenderIndex();
    return _renderEntriesById[object.id]?.projectedBounds;
  }

  ui.Rect _objectProjectedBoundsFor(
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset,
    EnvironmentObjectView view,
    int sourceWidth,
    int sourceHeight, {
    EnvironmentSurfaceSample? surface,
  }) {
    final width =
        (view.logicalWidth > 0 ? view.logicalWidth : sourceWidth) *
        asset.renderScale;
    final height =
        (view.logicalHeight > 0 ? view.logicalHeight : sourceHeight) *
        asset.renderScale;
    final anchor = projection.worldToScreen(Vector2(object.x, object.y))
      ..y -=
          _objectElevation(object, asset, surface: surface) *
          elevationPixelsPerWorldUnit;
    return ui.Rect.fromLTWH(
      anchor.x - width * view.pivotX,
      anchor.y - height * view.pivotY,
      width,
      height,
    );
  }

  ui.Rect _screenBoundsForProjected(ui.Rect rect) {
    final topLeft =
        (Vector2(rect.left, rect.top) - _mapCenterScreen) * zoom +
        size / 2 +
        _panOffset;
    return ui.Rect.fromLTWH(
      topLeft.x,
      topLeft.y,
      rect.width * zoom,
      rect.height * zoom,
    );
  }

  Vector2 _projectedAtScreen(Vector2 screen) =>
      (screen - size / 2 - _panOffset) / zoom + _mapCenterScreen;

  Vector2 _screenForWorldPoint(WorldPoint point, {double elevation = 0}) {
    final projected = projection.worldToScreen(Vector2(point.x, point.y));
    projected.y -= elevation * elevationPixelsPerWorldUnit;
    return (projected - _mapCenterScreen) * zoom + size / 2 + _panOffset;
  }

  ui.Rect get _visibleProjectedBounds =>
      _projectedBoundsForScreenRect(ui.Rect.fromLTWH(0, 0, size.x, size.y))
          .inflate(8 / zoom);

  ui.Rect _projectedBoundsForScreenRect(ui.Rect screenRect) {
    final topLeft = _projectedAtScreen(Vector2(screenRect.left, screenRect.top))
        .toOffset();
    final bottomRight = _projectedAtScreen(
      Vector2(screenRect.right, screenRect.bottom),
    ).toOffset();
    return ui.Rect.fromPoints(topLeft, bottomRight);
  }

  ui.Rect _chunkProjectedBounds(EnvironmentChunkCoordinate coordinate) =>
      _chunkPath(coordinate).getBounds();

  (int, int) _spatialCellFor(ui.Offset point) => (
    (point.dx / _spatialCellSize).floor(),
    (point.dy / _spatialCellSize).floor(),
  );

  Iterable<_EditorRenderEntry> _entriesOverlapping(ui.Rect bounds) sync* {
    final minCell = _spatialCellFor(bounds.topLeft);
    final maxCell = _spatialCellFor(bounds.bottomRight);
    final seen = <String>{};
    for (var y = minCell.$2; y <= maxCell.$2; y++) {
      for (var x = minCell.$1; x <= maxCell.$1; x++) {
        for (final entry in _spatialRenderEntries[(x, y)] ?? const []) {
          if (seen.add(entry.object.id) &&
              entry.projectedBounds.overlaps(bounds)) {
            yield entry;
          }
        }
      }
    }
  }

  void _ensureRenderIndex() {
    if (_seenSceneRevision == controller.sceneRevision &&
        _seenImageRevision == _imageRevision) {
      return;
    }
    final changedObjectIds = controller.lastSceneChangedObjectIds;
    final canUpdateObjectsIncrementally =
        _seenSceneRevision >= 0 &&
        controller.sceneRevision == _seenSceneRevision + 1 &&
        _seenImageRevision == _imageRevision &&
        changedObjectIds != null;
    if (canUpdateObjectsIncrementally) {
      for (final id in changedObjectIds) {
        _refreshRenderEntry(id);
      }
      _renderIndexIncrementalUpdateCount++;
      _seenSceneRevision = controller.sceneRevision;
      return;
    }
    _rebuildRenderIndex();
  }

  void _rebuildRenderIndex() {
    _renderIndexFullRebuildCount++;
    _renderEntriesById.clear();
    for (final entries in _renderEntriesByBand.values) {
      entries.clear();
    }
    _spatialRenderEntries.clear();
    for (final object in controller.document.objects) {
      if (!controller.isLayerVisible(object.editorLayerId)) continue;
      final asset = controller.catalog.objectById(object.assetId);
      if (asset == null) continue;
      final view = asset.viewFor(object.direction.name);
      final sourceSize = _sourceImageSizes[view.imagePath];
      if (sourceSize == null) {
        final anchor = projection
            .worldToScreen(Vector2(object.x, object.y))
            .toOffset();
        if (_visibleProjectedBounds.inflate(2048).contains(anchor)) {
          unawaited(_loadObjectView(object));
        }
        continue;
      }
      _addRenderEntry(object, asset, view, sourceSize, keepBandSorted: false);
    }
    for (final entries in _renderEntriesByBand.values) {
      entries.sort(_compareRenderEntries);
    }
    _seenSceneRevision = controller.sceneRevision;
    _seenImageRevision = _imageRevision;
  }

  void _refreshRenderEntry(String objectId) {
    _removeRenderEntry(objectId);
    final object = controller.objectById(objectId);
    if (object == null || !controller.isLayerVisible(object.editorLayerId)) {
      return;
    }
    final asset = controller.catalog.objectById(object.assetId);
    if (asset == null) return;
    final view = asset.viewFor(object.direction.name);
    final sourceSize = _sourceImageSizes[view.imagePath];
    if (sourceSize == null) {
      unawaited(_loadObjectView(object));
      return;
    }
    _addRenderEntry(object, asset, view, sourceSize, keepBandSorted: true);
  }

  void _addRenderEntry(
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset,
    EnvironmentObjectView view,
    (int, int) sourceSize, {
    required bool keepBandSorted,
  }) {
    final surface = _surfaceAt(
      WorldPoint(object.x, object.y),
      surfaceId: object.supportSurfaceId,
    );
    final bounds = _objectProjectedBoundsFor(
      object,
      asset,
      view,
      sourceSize.$1,
      sourceSize.$2,
      surface: surface,
    );
    final liquidOcclusionPath = surface.hasLiquid
        ? _liquidOcclusionPath(object, asset, surface, bounds)
        : null;
    final geometry = controller.catalog.geometryForAsset(
      asset,
      direction: object.direction.name,
    );
    final depthSurfaceId = environmentObjectDepthSurfaceId(
      document: controller.document,
      asset: asset,
      object: object,
      objectElevation: _objectElevation(object, asset, surface: surface),
      geometry: geometry,
    );
    final entry = _EditorRenderEntry(
      object: object,
      asset: asset,
      view: view,
      projectedBounds: bounds,
      surface: surface,
      liquidOcclusionPath: liquidOcclusionPath,
      depthSurfaceId: depthSurfaceId,
      depth: asset.depthAt(
        object.x,
        object.y,
        instanceSortBias: object.sortBias,
      ),
    );
    _renderEntriesById[object.id] = entry;
    final bandEntries = _renderEntriesByBand[asset.renderBand]!;
    if (keepBandSorted) {
      var low = 0;
      var high = bandEntries.length;
      while (low < high) {
        final middle = (low + high) >> 1;
        if (_compareRenderEntries(bandEntries[middle], entry) <= 0) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      bandEntries.insert(low, entry);
    } else {
      bandEntries.add(entry);
    }
    final minCell = _spatialCellFor(bounds.topLeft);
    final maxCell = _spatialCellFor(bounds.bottomRight);
    for (var y = minCell.$2; y <= maxCell.$2; y++) {
      for (var x = minCell.$1; x <= maxCell.$1; x++) {
        (_spatialRenderEntries[(x, y)] ??= []).add(entry);
      }
    }
  }

  ui.Path? _liquidOcclusionPath(
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset,
    EnvironmentSurfaceSample surface,
    ui.Rect destination,
  ) {
    final geometry = controller.catalog.geometryForAsset(
      asset,
      direction: object.direction.name,
    );
    final boundary = environmentFootprintFrontBoundary([
      for (final footprint in geometry.footprints)
        environmentShapeOutline(footprint, object),
    ]);
    if (boundary.length < 2) return null;
    final projected = [
      for (final point in boundary)
        projection.worldToScreen(Vector2(point.x, point.y))
          ..y -= surface.liquidSurfaceElevation! * elevationPixelsPerWorldUnit,
    ];
    final path = ui.Path()
      ..moveTo(destination.left, projected.first.y)
      ..lineTo(projected.first.x, projected.first.y);
    for (final point in projected.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    return path
      ..lineTo(destination.right, projected.last.y)
      ..lineTo(destination.right, destination.bottom)
      ..lineTo(destination.left, destination.bottom)
      ..close();
  }

  void _removeRenderEntry(String objectId) {
    final entry = _renderEntriesById.remove(objectId);
    if (entry == null) return;
    _renderEntriesByBand[entry.asset.renderBand]!.remove(entry);
    final minCell = _spatialCellFor(entry.projectedBounds.topLeft);
    final maxCell = _spatialCellFor(entry.projectedBounds.bottomRight);
    for (var y = minCell.$2; y <= maxCell.$2; y++) {
      for (var x = minCell.$1; x <= maxCell.$1; x++) {
        final cell = (x, y);
        final entries = _spatialRenderEntries[cell];
        entries?.remove(entry);
        if (entries?.isEmpty ?? false) _spatialRenderEntries.remove(cell);
      }
    }
  }

  int _compareRenderEntries(_EditorRenderEntry a, _EditorRenderEntry b) {
    final band = a.asset.renderBand.index.compareTo(b.asset.renderBand.index);
    if (band != 0) return band;
    final depth = a.depth.compareTo(b.depth);
    return depth != 0 ? depth : a.object.x.compareTo(b.object.x);
  }

  PlacedEnvironmentObject? _objectById(String id) => controller.objectById(id);

  void _renderCursor(ui.Canvas canvas) {
    final point = controller.hoveredPoint;
    if (point == null) return;
    final radius = controller.mode == EnvironmentEditorMode.paint
        ? controller.brushRadius
        : 0.5;
    _drawWorldDiamond(canvas, point, radius, _cursorPaint);
  }

  void _drawWorldDiamond(
    ui.Canvas canvas,
    WorldPoint center,
    double radius,
    ui.Paint paint,
  ) {
    final points = [
      projection.worldToScreen(Vector2(center.x - radius, center.y - radius)),
      projection.worldToScreen(Vector2(center.x + radius, center.y - radius)),
      projection.worldToScreen(Vector2(center.x + radius, center.y + radius)),
      projection.worldToScreen(Vector2(center.x - radius, center.y + radius)),
    ];
    final path = ui.Path()..moveTo(points.first.x, points.first.y);
    for (final point in points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(path..close(), paint);
  }

  void _renderMapOutline(ui.Canvas canvas) {
    final document = controller.document;
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

  void _renderPlayerSpawn(ui.Canvas canvas) {
    final spawn = playerSpawn?.call();
    if (spawn == null) return;
    final center = projection.worldToScreen(Vector2(spawn.x, spawn.y));
    center.y -= _surfaceAt(spawn).groundElevation * elevationPixelsPerWorldUnit;
    final radius = 12 / zoom;
    canvas
      ..drawCircle(center.toOffset(), radius, _spawnPaint)
      ..drawLine(
        center.toOffset() + ui.Offset(-radius * 1.4, 0),
        center.toOffset() + ui.Offset(radius * 1.4, 0),
        _spawnPaint,
      )
      ..drawLine(
        center.toOffset() + ui.Offset(0, -radius * 1.4),
        center.toOffset() + ui.Offset(0, radius * 1.4),
        _spawnPaint,
      );
  }

  ui.Path? _loadedChunkClip() {
    final chunks = loadedChunks?.call();
    if (chunks == null) return null;
    final path = ui.Path();
    for (final chunk in chunks) {
      final minX = chunk.x * chunkSize;
      final minY = chunk.y * chunkSize;
      final points = [
        projection.worldToScreen(Vector2(minX, minY)),
        projection.worldToScreen(Vector2(minX + chunkSize, minY)),
        projection.worldToScreen(Vector2(minX + chunkSize, minY + chunkSize)),
        projection.worldToScreen(Vector2(minX, minY + chunkSize)),
      ];
      path.moveTo(points.first.x, points.first.y);
      for (final point in points.skip(1)) {
        path.lineTo(point.x, point.y);
      }
      path.close();
    }
    return path;
  }

  ui.Path _chunkPath(EnvironmentChunkCoordinate chunk) {
    final minX = chunk.x * chunkSize;
    final minY = chunk.y * chunkSize;
    final points = [
      projection.worldToScreen(Vector2(minX, minY)),
      projection.worldToScreen(Vector2(minX + chunkSize, minY)),
      projection.worldToScreen(Vector2(minX + chunkSize, minY + chunkSize)),
      projection.worldToScreen(Vector2(minX, minY + chunkSize)),
    ];
    final path = ui.Path()..moveTo(points.first.x, points.first.y);
    for (final point in points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    return path..close();
  }

  void _renderChunkBoundaries(ui.Canvas canvas) {
    final chunks = loadedChunks?.call();
    if (chunks == null) return;
    final paint = ui.Paint()
      ..color = const ui.Color(0x4458D68D)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final clip = _loadedChunkClip();
    if (clip != null) canvas.drawPath(clip, paint);
  }

  @override
  void onRemove() {
    _clearTerrainRasters();
    for (final image in _loadedImages.values) {
      image.dispose();
    }
    _loadedImages.clear();
    _sprites.clear();
    _sourceImageSizes.clear();
    _imageLastUsedFrame.clear();
    _materialImagePaths.clear();
    _renderEntriesById.clear();
    _spatialRenderEntries.clear();
    for (final entries in _renderEntriesByBand.values) {
      entries.clear();
    }
    super.onRemove();
  }

  void _clearTerrainRasters() {
    _terrainCacheGeneration++;
    for (final raster in _terrainRasters.values) {
      raster.dispose();
    }
    _terrainRasters.clear();
    _emptyTerrainRasters.clear();
    _dirtyTerrainChunks.clear();
    _terrainBakeInFlight = null;
    _seenTerrainRevision = -1;
  }

  Vector2 get _mapCenterScreen {
    final center = _viewCenterWorld;
    return projection.worldToScreen(
      center == null
          ? Vector2(
              controller.document.width / 2,
              controller.document.height / 2,
            )
          : Vector2(center.x, center.y),
    );
  }
}

List<_GeometryHandlePoint> _geometryHandlePoints(
  EnvironmentGeometryShape shape,
) => switch (shape) {
  EnvironmentCircle() => [
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.center),
      shape.center,
    ),
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.radius),
      EnvironmentGeometryPoint(shape.center.x + shape.radius, shape.center.y),
    ),
  ],
  EnvironmentEllipse() => [
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.center),
      shape.center,
    ),
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.radiusX),
      EnvironmentGeometryPoint(shape.center.x + shape.radius.x, shape.center.y),
    ),
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.radiusY),
      EnvironmentGeometryPoint(shape.center.x, shape.center.y + shape.radius.y),
    ),
  ],
  EnvironmentRectangle() => [
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.center),
      shape.center,
    ),
    for (var index = 0; index < 4; index++)
      _GeometryHandlePoint(
        EnvironmentGeometryHandle(
          EnvironmentGeometryHandleType.rectangleCorner,
          index: index,
        ),
        _rotatedGeometryOffset(
          shape.center,
          index == 0 || index == 3 ? -shape.size.x / 2 : shape.size.x / 2,
          index < 2 ? -shape.size.y / 2 : shape.size.y / 2,
          shape.rotationDegrees,
        ),
      ),
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.rotation),
      _rotatedGeometryOffset(
        shape.center,
        0,
        -shape.size.y / 2 - 0.35,
        shape.rotationDegrees,
      ),
    ),
  ],
  EnvironmentCapsule() => [
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.center),
      EnvironmentGeometryPoint(
        (shape.start.x + shape.end.x) / 2,
        (shape.start.y + shape.end.y) / 2,
      ),
    ),
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(
        EnvironmentGeometryHandleType.capsuleStart,
      ),
      shape.start,
    ),
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.capsuleEnd),
      shape.end,
    ),
    _GeometryHandlePoint(
      const EnvironmentGeometryHandle(
        EnvironmentGeometryHandleType.capsuleRadius,
      ),
      _capsuleRadiusHandle(shape),
    ),
  ],
  EnvironmentPolygon() => [
    for (var index = 0; index < shape.points.length; index++)
      _GeometryHandlePoint(
        EnvironmentGeometryHandle(
          EnvironmentGeometryHandleType.polygonVertex,
          index: index,
        ),
        shape.points[index],
      ),
  ],
};

EnvironmentGeometryPoint _rotatedGeometryOffset(
  EnvironmentGeometryPoint center,
  double x,
  double y,
  double rotationDegrees,
) {
  final angle = rotationDegrees * math.pi / 180;
  return EnvironmentGeometryPoint(
    center.x + x * math.cos(angle) - y * math.sin(angle),
    center.y + x * math.sin(angle) + y * math.cos(angle),
  );
}

EnvironmentGeometryPoint _capsuleRadiusHandle(EnvironmentCapsule capsule) {
  final center = EnvironmentGeometryPoint(
    (capsule.start.x + capsule.end.x) / 2,
    (capsule.start.y + capsule.end.y) / 2,
  );
  final dx = capsule.end.x - capsule.start.x;
  final dy = capsule.end.y - capsule.start.y;
  final length = math.sqrt(dx * dx + dy * dy);
  if (length < 0.0001) {
    return EnvironmentGeometryPoint(center.x, center.y - capsule.radius);
  }
  return EnvironmentGeometryPoint(
    center.x - dy / length * capsule.radius,
    center.y + dx / length * capsule.radius,
  );
}

class _GeometryHandlePoint {
  const _GeometryHandlePoint(this.handle, this.local);

  final EnvironmentGeometryHandle handle;
  final EnvironmentGeometryPoint local;
}

class _TerrainRaster {
  const _TerrainRaster(this.image, this.paint);

  final ui.Image image;
  final ui.Paint paint;
  int get resolution => image.width;

  void dispose() => image.dispose();
}

enum _LiquidSpritePass { submerged, exposed }

class _EditorRenderEntry {
  const _EditorRenderEntry({
    required this.object,
    required this.asset,
    required this.view,
    required this.projectedBounds,
    required this.surface,
    required this.liquidOcclusionPath,
    required this.depthSurfaceId,
    required this.depth,
  });

  final PlacedEnvironmentObject object;
  final EnvironmentObjectAsset asset;
  final EnvironmentObjectView view;
  final ui.Rect projectedBounds;
  final EnvironmentSurfaceSample surface;
  final ui.Path? liquidOcclusionPath;
  final String depthSurfaceId;
  final double depth;
}
