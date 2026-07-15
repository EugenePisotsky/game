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
  static const int _terrainRasterResolution = 1024;
  static const double _spatialCellSize = 256;
  static const int _editorObjectMaximumDimension = 512;
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
  int get terrainRasterBytes =>
      _terrainRasters.length *
      _terrainRasterResolution *
      _terrainRasterResolution *
      4;
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
  final ui.Paint _hoverPaint = ui.Paint()
    ..color = const ui.Color(0xFF78C6A3)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
  final ui.Paint _marqueePaint = ui.Paint()
    ..color = const ui.Color(0xAA78C6A3)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final ui.Paint _footprintPaint = ui.Paint()
    ..color = const ui.Color(0xDD4EA8DE)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2;
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
      for (final stroke in controller.document.terrainStrokes)
        stroke.materialId,
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
    final preloadPaths = <String>{};
    for (final object in controller.document.objects) {
      final asset = controller.catalog.objectById(object.assetId);
      if (asset == null) continue;
      final anchor = projection
          .worldToScreen(Vector2(object.x, object.y))
          .toOffset();
      if (preloadBounds.contains(anchor)) {
        preloadPaths.add(asset.viewFor(object.direction.name).imagePath);
      }
    }
    await Future.wait([
      for (final path in preloadPaths)
        _loadImage(path, maximumDimension: _editorObjectMaximumDimension),
    ]);
    requestFrame(frames: 3);
  }

  Future<ui.Image?> _loadImage(String path, {int? maximumDimension}) async {
    final loaded = _loadedImages[path];
    if (loaded != null) {
      _touchImage(path);
      return loaded;
    }
    if (!_loadingImages.add(path)) return null;
    try {
      final loaded = await _loadUncachedImage(
        path,
        maximumDimension: maximumDimension,
      );
      final image = loaded.image;
      _loadedImages[path] = image;
      _sprites[path] = Sprite(image);
      _sourceImageSizes[path] = (loaded.sourceWidth, loaded.sourceHeight);
      _touchImage(path);
      _imageRevision++;
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
    await _loadImage(
      asset.viewFor(object.direction.name).imagePath,
      maximumDimension: _editorObjectMaximumDimension,
    );
  }

  WorldPoint? worldAtScreen(Vector2 screen) {
    if (!isLoaded) return null;
    final projected = _projectedAtScreen(screen);
    final world = projection.screenToWorld(projected);
    final point = WorldPoint(world.x, world.y);
    return controller.document.contains(point.x, point.y) ? point : null;
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

      _renderBaseGround(canvas);
      if (loadedChunks == null) {
        for (final stroke in controller.document.terrainStrokes) {
          _renderStroke(canvas, stroke);
        }
      } else {
        _synchronizeTerrainRasters();
        _renderRasterChunkTerrain(canvas);
        final activeStroke = controller.activeTerrainStroke;
        if (activeStroke != null) _renderStroke(canvas, activeStroke);
      }
      _renderObjectBand(canvas, EnvironmentRenderBand.groundCover);
      _renderObjectBand(canvas, EnvironmentRenderBand.depthSorted);
      _renderObjectBand(canvas, EnvironmentRenderBand.overhead);
      _renderObjectBand(canvas, EnvironmentRenderBand.effects);
      _renderPathPreview(canvas);
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
    final texelsPerWorldUnit = 64.0;
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
          document.width * texelsPerWorldUnit,
          document.height * texelsPerWorldUnit,
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
          minX * texelsPerWorldUnit,
          minY * texelsPerWorldUnit,
          (maxX - minX) * texelsPerWorldUnit,
          (maxY - minY) * texelsPerWorldUnit,
        ),
        image,
      );
    }
  }

  void _renderStroke(ui.Canvas canvas, TerrainStroke stroke) {
    if (stroke.points.isEmpty) return;
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
      _drawStamp(canvas, stamp.center, stamp.radius, paint, image);
    }
  }

  void _synchronizeTerrainRasters() {
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
      final isCached =
          _terrainRasters.containsKey(coordinate) ||
          _emptyTerrainRasters.contains(coordinate);
      if (!isCached && coordinate != _terrainBakeInFlight) {
        _dirtyTerrainChunks.add(coordinate);
      }
    }

    if (_terrainBakeInFlight == null && _dirtyTerrainChunks.isNotEmpty) {
      final coordinate = _dirtyTerrainChunks.first;
      _dirtyTerrainChunks.remove(coordinate);
      unawaited(_bakeTerrainChunk(coordinate));
    }
  }

  void _renderRasterChunkTerrain(ui.Canvas canvas) {
    final activeStroke = controller.activeTerrainStroke;
    final visible = _visibleProjectedBounds;
    for (final coordinate in loadedChunks!.call()) {
      if (!_chunkProjectedBounds(coordinate).overlaps(visible)) continue;
      final needsFallback =
          _dirtyTerrainChunks.contains(coordinate) ||
          _terrainBakeInFlight == coordinate ||
          (!_terrainRasters.containsKey(coordinate) &&
              !_emptyTerrainRasters.contains(coordinate));
      if (needsFallback) {
        canvas
          ..save()
          ..clipPath(_chunkPath(coordinate));
        for (final stroke in controller.document.terrainStrokes) {
          if (!identical(stroke, activeStroke) &&
              _strokeAffectsChunk(stroke, coordinate)) {
            _renderStroke(canvas, stroke);
          }
        }
        canvas.restore();
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

  Future<void> _bakeTerrainChunk(EnvironmentChunkCoordinate coordinate) async {
    final activeStroke = controller.activeTerrainStroke;
    final strokes = controller.document.terrainStrokes
        .where(
          (stroke) =>
              !identical(stroke, activeStroke) &&
              _strokeAffectsChunk(stroke, coordinate),
        )
        .toList();
    for (final stroke in strokes) {
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
    if (strokes.isEmpty) {
      _terrainRasters.remove(coordinate)?.dispose();
      _emptyTerrainRasters.add(coordinate);
      return;
    }

    _terrainBakeInFlight = coordinate;
    final generation = _terrainCacheGeneration;
    final originX = coordinate.x * chunkSize;
    final originY = coordinate.y * chunkSize;
    final pixelsPerWorldUnit = _terrainRasterResolution / chunkSize;
    final recorder = ui.PictureRecorder();
    final rasterCanvas = ui.Canvas(recorder);
    for (final stroke in strokes) {
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
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(
        _terrainRasterResolution,
        _terrainRasterResolution,
      );
      if (generation != _terrainCacheGeneration ||
          !loadedChunks!.call().contains(coordinate)) {
        image.dispose();
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
      image,
    );
  }

  void _drawTexturedWorldQuad(
    ui.Canvas canvas,
    WorldPoint min,
    WorldPoint max,
    ui.Paint paint,
    ui.Rect textureRect,
    ui.Image image,
  ) {
    final corners = [
      projection.worldToScreen(Vector2(min.x, min.y)),
      projection.worldToScreen(Vector2(max.x, min.y)),
      projection.worldToScreen(Vector2(max.x, max.y)),
      projection.worldToScreen(Vector2(min.x, max.y)),
    ];
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
    );
    canvas.drawVertices(vertices, ui.BlendMode.srcOver, paint);
  }

  void _renderObjectBand(ui.Canvas canvas, EnvironmentRenderBand band) {
    final entries = _renderEntriesByBand[band]!;
    final visible = _visibleProjectedBounds;
    _renderCandidateCount += entries.length;
    for (final entry in entries) {
      if (!entry.projectedBounds.overlaps(visible)) continue;
      _visibleSpriteCount++;
      final object = entry.object;
      final view = entry.view;
      final sprite = _sprites[view.imagePath];
      if (sprite == null) {
        _loadObjectView(object);
        continue;
      }
      _touchImage(view.imagePath);
      sprite.render(
        canvas,
        position: projection.worldToScreen(Vector2(object.x, object.y))
          ..y -= object.verticalOffset * elevationPixelsPerWorldUnit,
        size: Vector2(
          entry.projectedBounds.width,
          entry.projectedBounds.height,
        ),
        anchor: Anchor(view.pivotX, view.pivotY),
      );
    }
  }

  void _renderPathPreview(ui.Canvas canvas) {
    if (controller.mode != EnvironmentEditorMode.path) return;
    final start = controller.pathStart;
    final end = controller.pathEnd;
    if (start != null && end != null) {
      final startScreen = projection
          .worldToScreen(Vector2(start.x, start.y))
          .toOffset();
      final endScreen = projection
          .worldToScreen(Vector2(end.x, end.y))
          .toOffset();
      canvas.drawLine(startScreen, endScreen, _pathPreviewLinePaint);
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
        _loadImage(
          view.imagePath,
          maximumDimension: _editorObjectMaximumDimension,
        );
        continue;
      }
      _touchImage(view.imagePath);
      sprite.render(
        canvas,
        position: projection.worldToScreen(
          Vector2(placement.point.x, placement.point.y),
        ),
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
        final handle = projection
            .worldToScreen(Vector2(point.x, point.y))
            .toOffset();
        canvas
          ..drawCircle(handle, 6, _pathHandleFillPaint)
          ..drawCircle(handle, 6, _pathHandleStrokePaint);
      }
    }
  }

  void _renderSelection(ui.Canvas canvas) {
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
    }
  }

  void _renderGeometry(ui.Canvas canvas) {
    final selected = controller.selectedObject;
    if (selected != null) _renderGeometryMeasurementGrid(canvas, selected);
    for (final object in controller.document.objects) {
      if (!controller.isLayerVisible(object.editorLayerId)) continue;
      final asset = controller.catalog.objectById(object.assetId);
      if (asset == null) continue;
      final geometry = controller.catalog.geometryForAsset(asset);
      final footprint = geometry.footprint;
      if (footprint != null) {
        _drawGeometryShape(canvas, footprint, object, _footprintPaint);
      }
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
      }
    }
    final cursor = controller.hoveredPoint;
    if (cursor != null) {
      const actorRadius = 0.18;
      final blocked = _isNavigationBlocked(cursor, actorRadius: actorRadius);
      final points = [
        for (var index = 0; index < 24; index++)
          WorldPoint(
            cursor.x + math.cos(index * math.pi / 12) * actorRadius,
            cursor.y + math.sin(index * math.pi / 12) * actorRadius,
          ),
      ];
      final first = projection.worldToScreen(
        Vector2(points.first.x, points.first.y),
      );
      final path = ui.Path()..moveTo(first.x, first.y);
      for (final point in points.skip(1)) {
        final projected = projection.worldToScreen(Vector2(point.x, point.y));
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
    for (var offset = -radius; offset <= radius; offset += spacing) {
      _drawWorldLine(
        canvas,
        WorldPoint(object.x - radius, object.y + offset),
        WorldPoint(object.x + radius, object.y + offset),
        _geometryGridPaint,
      );
      _drawWorldLine(
        canvas,
        WorldPoint(object.x + offset, object.y - radius),
        WorldPoint(object.x + offset, object.y + radius),
        _geometryGridPaint,
      );
    }
  }

  void _renderGeometryAnchors(
    ui.Canvas canvas,
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset,
  ) {
    final pivot = projection.worldToScreen(Vector2(object.x, object.y))
      ..y -= object.verticalOffset * elevationPixelsPerWorldUnit;
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
    );
    canvas.drawCircle(
      sort.toOffset(),
      5 / zoom,
      ui.Paint()
        ..color = const ui.Color(0xFFE9C46A)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2 / zoom,
    );
  }

  void _drawWorldLine(
    ui.Canvas canvas,
    WorldPoint start,
    WorldPoint end,
    ui.Paint paint,
  ) {
    final a = projection.worldToScreen(Vector2(start.x, start.y));
    final b = projection.worldToScreen(Vector2(end.x, end.y));
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
      builder.addText(
        '${asset.renderBand.name} ${asset.depthAt(object.x, object.y, instanceSortBias: object.sortBias).toStringAsFixed(2)}',
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
            geometry: controller.catalog.geometryForAsset(asset),
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

  ui.Rect? _objectProjectedBounds(PlacedEnvironmentObject object) {
    _ensureRenderIndex();
    return _renderEntriesById[object.id]?.projectedBounds;
  }

  ui.Rect _objectProjectedBoundsFor(
    PlacedEnvironmentObject object,
    EnvironmentObjectAsset asset,
    EnvironmentObjectView view,
    int sourceWidth,
    int sourceHeight,
  ) {
    final width = sourceWidth * asset.renderScale;
    final height = sourceHeight * asset.renderScale;
    final anchor = projection.worldToScreen(Vector2(object.x, object.y))
      ..y -= object.verticalOffset * elevationPixelsPerWorldUnit;
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
    final bounds = _objectProjectedBoundsFor(
      object,
      asset,
      view,
      sourceSize.$1,
      sourceSize.$2,
    );
    final entry = _EditorRenderEntry(
      object: object,
      asset: asset,
      view: view,
      projectedBounds: bounds,
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

class _TerrainRaster {
  const _TerrainRaster(this.image, this.paint);

  final ui.Image image;
  final ui.Paint paint;

  void dispose() => image.dispose();
}

class _EditorRenderEntry {
  const _EditorRenderEntry({
    required this.object,
    required this.asset,
    required this.view,
    required this.projectedBounds,
    required this.depth,
  });

  final PlacedEnvironmentObject object;
  final EnvironmentObjectAsset asset;
  final EnvironmentObjectView view;
  final ui.Rect projectedBounds;
  final double depth;
}
