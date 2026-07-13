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

class EditorGame extends FlameGame with HasPerformanceTracker {
  EditorGame(
    this.controller, {
    this.loadedChunks,
    WorldPoint? initialWorldCenter,
    this.chunkSize = 32,
  }) : _viewCenterWorld = initialWorldCenter {
    images = Images(prefix: neuraAssetPrefix);
  }

  final EditorController controller;
  final Set<EnvironmentChunkCoordinate> Function()? loadedChunks;
  final double chunkSize;
  final WorldPoint? _viewCenterWorld;
  final IsometricProjection projection = const IsometricProjection();
  final Vector2 _panOffset = Vector2.zero();
  final Vector2 _panVelocity = Vector2.zero();
  final Map<String, ui.Image> _loadedImages = {};
  final Set<String> _loadingImages = {};
  final Map<String, ui.Paint> _repeatingPaints = {};
  final Map<String, ui.Paint> _decalPaints = {};
  final Map<EnvironmentChunkCoordinate, ui.Picture> _terrainPictures = {};
  final Map<EnvironmentChunkCoordinate, int> _terrainPictureSignatures = {};
  final FpsComponent _fpsComponent = FpsComponent(windowSize: 60);
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

  int get decodedImageCount => _loadedImages.length;
  int get decodedImageBytes => _loadedImages.values.fold(
    0,
    (sum, image) => sum + image.width * image.height * 4,
  );
  int get pendingImageCount => _loadingImages.length;
  int get terrainPictureCount => _terrainPictures.length;
  double get diagnosticsFps => _fpsComponent.fps;
  double get diagnosticsFrameMilliseconds =>
      diagnosticsFps <= 0 ? 0 : 1000 / diagnosticsFps;

  void togglePause() {
    diagnosticsPaused = !diagnosticsPaused;
    diagnosticsPaused ? pauseEngine() : resumeEngine();
  }

  void stepDebug() {
    if (diagnosticsPaused) update(1 / 60);
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
    final paths = <String>{};
    for (final id in materialIds) {
      final material = controller.catalog.materialById(id);
      if (material != null) {
        paths
          ..add(material.texturePath)
          ..add(material.decalPath);
      }
    }
    for (final object in controller.document.objects) {
      final asset = controller.catalog.objectById(object.assetId);
      if (asset != null) {
        paths.add(asset.viewFor(object.direction.name).imagePath);
      }
    }
    final pathList = paths.toList();
    final loaded = await Future.wait([
      for (final path in pathList) _loadUncachedImage(path),
    ]);
    for (var index = 0; index < pathList.length; index++) {
      _loadedImages[pathList[index]] = loaded[index];
    }
    for (final id in materialIds) {
      _createMaterialPaints(id);
    }
  }

  Future<ui.Image?> _loadImage(String path) async {
    final loaded = _loadedImages[path];
    if (loaded != null) return loaded;
    if (!_loadingImages.add(path)) return null;
    try {
      final image = await _loadUncachedImage(path);
      _loadedImages[path] = image;
      return image;
    } finally {
      _loadingImages.remove(path);
    }
  }

  Future<ui.Image> _loadUncachedImage(String path) =>
      loadWorkspaceEnvironmentImage(path);

  Future<void> _loadMaterial(String id) async {
    if (_repeatingPaints.containsKey(id) && _decalPaints.containsKey(id)) {
      return;
    }
    final material = controller.catalog.materialById(id);
    if (material == null) return;
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
    await _loadImage(asset.viewFor(object.direction.name).imagePath);
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
    final point = _projectedAtScreen(screen).toOffset();
    final candidates = <PlacedEnvironmentObject>[];
    for (final object in controller.document.objects) {
      if (!controller.isLayerVisible(object.editorLayerId) ||
          controller.isLayerLocked(object.editorLayerId)) {
        continue;
      }
      final bounds = _objectProjectedBounds(object);
      if (bounds != null && bounds.contains(point)) candidates.add(object);
    }
    candidates.sort(_compareVisualOrder);
    return [for (final object in candidates.reversed) object.id];
  }

  List<String> objectIdsInMarquee(
    ui.Rect screenRect, {
    bool requireContainment = false,
  }) {
    final result = <PlacedEnvironmentObject>[];
    for (final object in controller.document.objects) {
      if (!controller.isLayerVisible(object.editorLayerId) ||
          controller.isLayerLocked(object.editorLayerId)) {
        continue;
      }
      final projected = _objectProjectedBounds(object);
      if (projected == null) continue;
      final bounds = _screenBoundsForProjected(projected);
      final included = requireContainment
          ? screenRect.contains(bounds.topLeft) &&
                screenRect.contains(bounds.bottomRight)
          : screenRect.overlaps(bounds);
      if (included) result.add(object);
    }
    result.sort(_compareVisualOrder);
    return [for (final object in result) object.id];
  }

  void setSelectionMarquee(ui.Rect? rect) => _marqueeScreenRect = rect;

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
  }

  void panByScreenDelta(Vector2 delta, {required double elapsedSeconds}) {
    _panOffset.add(delta);
    final seconds = elapsedSeconds.clamp(1 / 240, 1 / 15);
    final instantaneous = delta / seconds;
    _panVelocity
      ..scale(0.62)
      ..add(instantaneous * 0.38);
  }

  void endPan() => _isPanning = false;

  void zoomBy(double factor) {
    zoom = (zoom * factor).clamp(0.2, 1.4);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_isPanning && _panVelocity.length2 > 1) {
      _panOffset.add(_panVelocity * dt);
      _panVelocity.scale(math.exp(-6.5 * dt));
      if (_panVelocity.length < 8) _panVelocity.setZero();
    }
  }

  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);
    if (!isLoaded) return;
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
      _renderCachedChunkTerrain(canvas);
    }
    _renderObjectBand(canvas, EnvironmentRenderBand.groundCover);
    _renderObjectBand(canvas, EnvironmentRenderBand.depthSorted);
    _renderObjectBand(canvas, EnvironmentRenderBand.overhead);
    _renderObjectBand(canvas, EnvironmentRenderBand.effects);
    _renderMapOutline(canvas);
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
    for (final chunk in chunks) {
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

  void _renderCachedChunkTerrain(ui.Canvas canvas) {
    final chunks = loadedChunks!.call();
    final stale = _terrainPictures.keys
        .where((coordinate) => !chunks.contains(coordinate))
        .toList();
    for (final coordinate in stale) {
      _terrainPictures.remove(coordinate)?.dispose();
      _terrainPictureSignatures.remove(coordinate);
    }
    for (final coordinate in chunks) {
      final strokes = controller.document.terrainStrokes
          .where((stroke) => _strokeAffectsChunk(stroke, coordinate))
          .toList();
      var ready = true;
      for (final stroke in strokes) {
        if (!_decalPaints.containsKey(stroke.materialId)) {
          _loadMaterial(stroke.materialId);
          ready = false;
        }
      }
      if (!ready) continue;
      final signature = Object.hashAll([
        controller.document.baseMaterialId,
        for (final stroke in strokes)
          Object.hash(
            stroke.materialId,
            stroke.radius,
            stroke.opacity,
            Object.hashAll([
              for (final point in stroke.points) Object.hash(point.x, point.y),
            ]),
          ),
      ]);
      if (_terrainPictureSignatures[coordinate] != signature) {
        _terrainPictures.remove(coordinate)?.dispose();
        final recorder = ui.PictureRecorder();
        final pictureCanvas = ui.Canvas(recorder)
          ..clipPath(_chunkPath(coordinate));
        for (final stroke in strokes) {
          _renderStroke(pictureCanvas, stroke);
        }
        _terrainPictures[coordinate] = recorder.endRecording();
        _terrainPictureSignatures[coordinate] = signature;
      }
      final picture = _terrainPictures[coordinate];
      if (picture != null) canvas.drawPicture(picture);
    }
  }

  bool _strokeAffectsChunk(
    TerrainStroke stroke,
    EnvironmentChunkCoordinate coordinate,
  ) {
    if (stroke.points.isEmpty) return false;
    final minX =
        stroke.points.map((point) => point.x).reduce(math.min) - stroke.radius;
    final minY =
        stroke.points.map((point) => point.y).reduce(math.min) - stroke.radius;
    final maxX =
        stroke.points.map((point) => point.x).reduce(math.max) + stroke.radius;
    final maxY =
        stroke.points.map((point) => point.y).reduce(math.max) + stroke.radius;
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
    final objects =
        controller.document.objects.where((object) {
          return controller.isLayerVisible(object.editorLayerId) &&
              controller.catalog.objectById(object.assetId)?.renderBand == band;
        }).toList()..sort((a, b) {
          final aAsset = controller.catalog.objectById(a.assetId)!;
          final bAsset = controller.catalog.objectById(b.assetId)!;
          final depth = aAsset
              .depthAt(a.x, a.y, instanceSortBias: a.sortBias)
              .compareTo(
                bAsset.depthAt(b.x, b.y, instanceSortBias: b.sortBias),
              );
          return depth != 0 ? depth : a.x.compareTo(b.x);
        });
    for (final object in objects) {
      final asset = controller.catalog.objectById(object.assetId);
      if (asset == null) continue;
      final view = asset.viewFor(object.direction.name);
      final image = _loadedImages[view.imagePath];
      if (image == null) {
        _loadObjectView(object);
        continue;
      }
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
      final blocked = controller.document.objects.any((object) {
        final asset = controller.catalog.objectById(object.assetId);
        return asset != null &&
            environmentObjectBlocksPoint(
              asset,
              object,
              cursor,
              actorRadius: actorRadius,
              geometry: controller.catalog.geometryForAsset(asset),
            );
      });
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
        final blocked = controller.document.objects.any((object) {
          final asset = controller.catalog.objectById(object.assetId);
          return asset != null &&
              environmentObjectBlocksPoint(
                asset,
                object,
                point,
                actorRadius: 0.18,
                geometry: controller.catalog.geometryForAsset(asset),
              );
        });
        final projected = projection.worldToScreen(Vector2(point.x, point.y));
        canvas.drawCircle(
          projected.toOffset(),
          1.8 / zoom,
          blocked ? blockedPaint : openPaint,
        );
      }
    }
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
    final asset = controller.catalog.objectById(object.assetId);
    if (asset == null) return null;
    final view = asset.viewFor(object.direction.name);
    final image = _loadedImages[view.imagePath];
    if (image == null) return null;
    final width = image.width * asset.renderScale;
    final height = image.height * asset.renderScale;
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

  int _compareVisualOrder(
    PlacedEnvironmentObject a,
    PlacedEnvironmentObject b,
  ) {
    final aAsset = controller.catalog.objectById(a.assetId)!;
    final bAsset = controller.catalog.objectById(b.assetId)!;
    final band = aAsset.renderBand.index.compareTo(bAsset.renderBand.index);
    if (band != 0) return band;
    final depth = aAsset
        .depthAt(a.x, a.y, instanceSortBias: a.sortBias)
        .compareTo(bAsset.depthAt(b.x, b.y, instanceSortBias: b.sortBias));
    return depth != 0 ? depth : a.x.compareTo(b.x);
  }

  PlacedEnvironmentObject? _objectById(String id) {
    for (final object in controller.document.objects) {
      if (object.id == id) return object;
    }
    return null;
  }

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
    for (final picture in _terrainPictures.values) {
      picture.dispose();
    }
    _terrainPictures.clear();
    for (final image in _loadedImages.values) {
      image.dispose();
    }
    _loadedImages.clear();
    super.onRemove();
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
