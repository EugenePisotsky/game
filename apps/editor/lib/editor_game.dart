import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/cache.dart';
import 'package:flame/components.dart' show Anchor;
import 'package:flame/game.dart';
import 'package:flame/sprite.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

import 'editor_controller.dart';

class EditorGame extends FlameGame {
  EditorGame(this.controller) {
    images = Images(prefix: neuraAssetPrefix);
  }

  final EditorController controller;
  final IsometricProjection projection = const IsometricProjection();
  final Vector2 _panOffset = Vector2.zero();
  final Vector2 _panVelocity = Vector2.zero();
  final Map<String, ui.Image> _loadedImages = {};
  final Set<String> _loadingImages = {};
  final Map<String, ui.Paint> _repeatingPaints = {};
  final Map<String, ui.Paint> _decalPaints = {};
  bool _isPanning = false;
  double zoom = 0.42;

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
      path.startsWith('environment_generated/')
      ? loadGeneratedEnvironmentImage(path)
      : images.load(path);

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
    final projected =
        (screen - size / 2 - _panOffset) / zoom + _mapCenterScreen;
    final world = projection.screenToWorld(projected);
    final point = WorldPoint(world.x, world.y);
    return controller.document.contains(point.x, point.y) ? point : null;
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
    for (final stroke in controller.document.terrainStrokes) {
      _renderStroke(canvas, stroke);
    }
    _renderMapOutline(canvas);
    _renderObjects(canvas);
    _renderCursor(canvas);
    canvas.restore();
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

  void _renderObjects(ui.Canvas canvas) {
    final objects = [...controller.document.objects]
      ..sort((a, b) {
        final depth = (a.x + a.y).compareTo(b.x + b.y);
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
        position: projection.worldToScreen(Vector2(object.x, object.y)),
        size: Vector2(
          image.width * asset.renderScale,
          image.height * asset.renderScale,
        ),
        anchor: Anchor(view.pivotX, view.pivotY),
      );
    }
    final selected = controller.selectedObject;
    if (selected != null) {
      _drawWorldDiamond(
        canvas,
        WorldPoint(selected.x, selected.y),
        0.55,
        _selectionPaint,
      );
    }
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

  Vector2 get _mapCenterScreen => projection.worldToScreen(
    Vector2(controller.document.width / 2, controller.document.height / 2),
  );
}
