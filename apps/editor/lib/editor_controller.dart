import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

enum EnvironmentEditorMode { paint, place, select, collision, erase }

enum GeometryRole { footprint, blocking, walkable }

enum GeometryShapeType { circle, ellipse, rectangle, capsule, polygon }

class EditorController extends ChangeNotifier {
  EditorController(this._document, {required this.catalog});

  final EnvironmentCatalog catalog;
  EnvironmentDocument _document;

  EnvironmentDocument get document => _document;

  EnvironmentEditorMode _mode = EnvironmentEditorMode.paint;
  EnvironmentEditorMode get mode => _mode;
  bool get isObjectSelectionMode =>
      _mode == EnvironmentEditorMode.select ||
      _mode == EnvironmentEditorMode.collision;

  String _selectedMaterialId = 'ow3.ground.earth';
  String get selectedMaterialId => _selectedMaterialId;

  String _selectedObjectAssetId = 'ow3.tree.blossom';
  String get selectedObjectAssetId => _selectedObjectAssetId;

  double _brushRadius = 2.2;
  double get brushRadius => _brushRadius;

  WorldPoint? _hoveredPoint;
  WorldPoint? get hoveredPoint => _hoveredPoint;

  final Set<String> _selectedObjectIds = {};
  String? _primarySelectedObjectId;
  String? get selectedObjectId => _primarySelectedObjectId;
  Set<String> get selectedObjectIds => Set.unmodifiable(_selectedObjectIds);

  List<PlacedEnvironmentObject> get selectedObjects => [
    for (final object in _document.objects)
      if (_selectedObjectIds.contains(object.id)) object,
  ];

  PlacedEnvironmentObject? get selectedObject {
    final id = _primarySelectedObjectId;
    if (id == null) return null;
    for (final object in _document.objects) {
      if (object.id == id) return object;
    }
    return null;
  }

  String? _hoveredObjectId;
  String? get hoveredObjectId => _hoveredObjectId;

  List<String> _overlapCandidateIds = const [];
  List<String> get overlapCandidateIds =>
      List.unmodifiable(_overlapCandidateIds);

  EditorLayer get activeLayer =>
      _document.editorLayerById(_document.activeLayerId)!;

  GeometryRole _geometryRole = GeometryRole.blocking;
  GeometryRole get geometryRole => _geometryRole;
  int _geometryShapeIndex = 0;
  int get geometryShapeIndex => _geometryShapeIndex;

  EnvironmentAssetGeometry? get selectedAssetGeometry {
    final object = selectedObject;
    if (object == null) return null;
    final asset = catalog.objectById(object.assetId);
    return asset == null ? null : catalog.geometryForAsset(asset);
  }

  EnvironmentGeometryShape? get selectedGeometryShape {
    final geometry = selectedAssetGeometry;
    if (geometry == null) return null;
    switch (_geometryRole) {
      case GeometryRole.footprint:
        return geometry.footprint;
      case GeometryRole.blocking:
        return _geometryShapeIndex < geometry.blocking.length
            ? geometry.blocking[_geometryShapeIndex]
            : null;
      case GeometryRole.walkable:
        return _geometryShapeIndex < geometry.walkable.length
            ? geometry.walkable[_geometryShapeIndex]
            : null;
    }
  }

  final List<_EditorSnapshot> _undo = [];
  final List<_EditorSnapshot> _redo = [];
  _EditorSnapshot? _gestureBefore;
  TerrainStroke? _activeStroke;
  bool _gestureChanged = false;
  bool _placedThisGesture = false;
  int _nextObjectId = 100;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void selectPaintMaterial(EnvironmentMaterial material) {
    _mode = EnvironmentEditorMode.paint;
    _selectedMaterialId = material.id;
    _brushRadius = material.defaultRadius;
    notifyListeners();
  }

  void selectObjectAsset(EnvironmentObjectAsset object) {
    _mode = EnvironmentEditorMode.place;
    _selectedObjectAssetId = object.id;
    notifyListeners();
  }

  void selectMode(EnvironmentEditorMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
  }

  void selectGeometryRole(GeometryRole role) {
    if (_geometryRole == role) return;
    _geometryRole = role;
    _geometryShapeIndex = 0;
    notifyListeners();
  }

  void selectGeometryShapeIndex(int index) {
    if (_geometryShapeIndex == index) return;
    _geometryShapeIndex = index;
    notifyListeners();
  }

  void replaceSelectedGeometryShape(EnvironmentGeometryShape shape) {
    _mutateSelectedGeometry((geometry) {
      switch (_geometryRole) {
        case GeometryRole.footprint:
          return geometry.copyWith(footprint: shape, reviewed: false);
        case GeometryRole.blocking:
          final shapes = [...geometry.blocking];
          if (_geometryShapeIndex >= shapes.length) return geometry;
          shapes[_geometryShapeIndex] = shape;
          return geometry.copyWith(blocking: shapes, reviewed: false);
        case GeometryRole.walkable:
          final shapes = [...geometry.walkable];
          if (_geometryShapeIndex >= shapes.length) return geometry;
          shapes[_geometryShapeIndex] = shape;
          return geometry.copyWith(walkable: shapes, reviewed: false);
      }
    });
  }

  void addGeometryShape(GeometryShapeType type) {
    final shape = switch (type) {
      GeometryShapeType.circle => const EnvironmentCircle(
        center: EnvironmentGeometryPoint(0, 0),
        radius: 0.25,
      ),
      GeometryShapeType.ellipse => const EnvironmentEllipse(
        center: EnvironmentGeometryPoint(0, 0),
        radius: EnvironmentGeometryPoint(0.3, 0.2),
      ),
      GeometryShapeType.rectangle => const EnvironmentRectangle(
        center: EnvironmentGeometryPoint(0, 0),
        size: EnvironmentGeometryPoint(0.6, 0.4),
      ),
      GeometryShapeType.capsule => const EnvironmentCapsule(
        start: EnvironmentGeometryPoint(-0.3, 0),
        end: EnvironmentGeometryPoint(0.3, 0),
        radius: 0.1,
      ),
      GeometryShapeType.polygon => const EnvironmentPolygon(
        points: [
          EnvironmentGeometryPoint(-0.3, -0.2),
          EnvironmentGeometryPoint(0.3, -0.2),
          EnvironmentGeometryPoint(0.3, 0.2),
          EnvironmentGeometryPoint(-0.3, 0.2),
        ],
      ),
    };
    _mutateSelectedGeometry((geometry) {
      switch (_geometryRole) {
        case GeometryRole.footprint:
          _geometryShapeIndex = 0;
          return geometry.copyWith(footprint: shape, reviewed: false);
        case GeometryRole.blocking:
          final shapes = [...geometry.blocking, shape];
          _geometryShapeIndex = shapes.length - 1;
          return geometry.copyWith(blocking: shapes, reviewed: false);
        case GeometryRole.walkable:
          final shapes = [...geometry.walkable, shape];
          _geometryShapeIndex = shapes.length - 1;
          return geometry.copyWith(walkable: shapes, reviewed: false);
      }
    });
  }

  void deleteSelectedGeometryShape() {
    if (selectedGeometryShape == null) return;
    _mutateSelectedGeometry((geometry) {
      switch (_geometryRole) {
        case GeometryRole.footprint:
          return geometry.copyWith(clearFootprint: true, reviewed: false);
        case GeometryRole.blocking:
          final shapes = [...geometry.blocking]..removeAt(_geometryShapeIndex);
          _geometryShapeIndex = math.max(0, _geometryShapeIndex - 1);
          return geometry.copyWith(blocking: shapes, reviewed: false);
        case GeometryRole.walkable:
          final shapes = [...geometry.walkable]..removeAt(_geometryShapeIndex);
          _geometryShapeIndex = math.max(0, _geometryShapeIndex - 1);
          return geometry.copyWith(walkable: shapes, reviewed: false);
      }
    });
  }

  void markSelectedGeometryReviewed() {
    _mutateSelectedGeometry((geometry) => geometry.copyWith(reviewed: true));
  }

  void resetSelectedGeometryOverride() {
    final object = selectedObject;
    if (object == null ||
        !catalog.geometryOverrides.containsKey(object.assetId)) {
      return;
    }
    _recordImmediate(() => catalog.removeGeometryOverride(object.assetId));
    _geometryShapeIndex = 0;
  }

  Future<void> saveGeometryOverrides() =>
      saveEnvironmentGeometryOverrides(catalog.geometryOverridesToJsonString());

  void setBrushRadius(double value) {
    _brushRadius = value.clamp(0.5, 5);
    notifyListeners();
  }

  void hover(WorldPoint? point) {
    if (_hoveredPoint?.x == point?.x && _hoveredPoint?.y == point?.y) return;
    _hoveredPoint = point;
    notifyListeners();
  }

  void hoverObjects(Iterable<String> objectIds) {
    final candidates = objectIds.where(_isObjectSelectable).toList();
    final hovered = candidates.isEmpty ? null : candidates.first;
    if (_hoveredObjectId == hovered &&
        _sameStrings(_overlapCandidateIds, candidates)) {
      return;
    }
    _hoveredObjectId = hovered;
    _overlapCandidateIds = candidates;
    notifyListeners();
  }

  void selectCandidates(Iterable<String> objectIds, {bool additive = false}) {
    final candidates = objectIds.where(_isObjectSelectable).toList();
    if (candidates.isEmpty) {
      if (!additive) clearSelection();
      return;
    }
    var selectedId = candidates.first;
    if (!additive &&
        _sameStrings(_overlapCandidateIds, candidates) &&
        _primarySelectedObjectId != null) {
      final current = candidates.indexOf(_primarySelectedObjectId!);
      if (current >= 0) {
        selectedId = candidates[(current + 1) % candidates.length];
      }
    }
    if (additive) {
      if (!_selectedObjectIds.remove(selectedId)) {
        _selectedObjectIds.add(selectedId);
        _primarySelectedObjectId = selectedId;
      } else if (_primarySelectedObjectId == selectedId) {
        _primarySelectedObjectId = _lastOrNull(_selectedObjectIds);
      }
    } else {
      _selectedObjectIds
        ..clear()
        ..add(selectedId);
      _primarySelectedObjectId = selectedId;
    }
    _overlapCandidateIds = candidates;
    notifyListeners();
  }

  void selectObjectIds(
    Iterable<String> objectIds, {
    bool additive = false,
    bool toggle = false,
  }) {
    final ids = objectIds.where(_isObjectSelectable).toList();
    if (!additive && !toggle) _selectedObjectIds.clear();
    for (final id in ids) {
      if (toggle && _selectedObjectIds.contains(id)) {
        _selectedObjectIds.remove(id);
      } else {
        _selectedObjectIds.add(id);
        _primarySelectedObjectId = id;
      }
    }
    _primarySelectedObjectId ??= _lastOrNull(_selectedObjectIds);
    if (_selectedObjectIds.isEmpty) _primarySelectedObjectId = null;
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedObjectIds.isEmpty) return;
    _selectedObjectIds.clear();
    _primarySelectedObjectId = null;
    notifyListeners();
  }

  void beginGesture() {
    _gestureBefore = _snapshot();
    _gestureChanged = false;
    _placedThisGesture = false;
    _activeStroke = null;
  }

  void applyAt(WorldPoint point) {
    if (!_document.contains(point.x, point.y)) return;
    _hoveredPoint = point;
    switch (_mode) {
      case EnvironmentEditorMode.paint:
        _paint(point);
      case EnvironmentEditorMode.place:
        if (!_placedThisGesture) _place(point);
      case EnvironmentEditorMode.select:
      case EnvironmentEditorMode.collision:
        _selectNearest(point);
      case EnvironmentEditorMode.erase:
        if (!_placedThisGesture) _eraseNearest(point);
    }
    notifyListeners();
  }

  void endGesture() {
    final before = _gestureBefore;
    if (_gestureChanged && before != null) {
      _undo.add(before);
      if (_undo.length > 100) _undo.removeAt(0);
      _redo.clear();
    }
    _gestureBefore = null;
    _activeStroke = null;
    _gestureChanged = false;
    _placedThisGesture = false;
    notifyListeners();
  }

  void moveSelectedTo(WorldPoint point) {
    final object = selectedObject;
    if (object == null || !_document.contains(point.x, point.y)) return;
    _recordImmediate(() {
      object
        ..x = point.x
        ..y = point.y;
    });
  }

  void moveSelectedDuringGesture(WorldPoint point) {
    final object = selectedObject;
    if (object == null || !_document.contains(point.x, point.y)) return;
    object
      ..x = point.x
      ..y = point.y;
    _gestureChanged = true;
    _hoveredPoint = point;
    notifyListeners();
  }

  void moveSelectionDuringGesture(WorldPoint from, WorldPoint to) {
    if (_selectedObjectIds.isEmpty) return;
    final dx = to.x - from.x;
    final dy = to.y - from.y;
    final selected = selectedObjects;
    if (selected.any(
      (object) => !_document.contains(object.x + dx, object.y + dy),
    )) {
      return;
    }
    for (final object in selected) {
      object
        ..x += dx
        ..y += dy;
    }
    _gestureChanged = true;
    _hoveredPoint = to;
    notifyListeners();
  }

  void rotateSelected() {
    final selected = selectedObjects;
    if (selected.isEmpty) return;
    _recordImmediate(() {
      for (final object in selected) {
        object.direction = object.direction.next;
      }
    });
  }

  void adjustSelectedVerticalOffset(double delta) {
    final selected = selectedObjects;
    if (selected.isEmpty) return;
    _recordImmediate(() {
      for (final object in selected) {
        object.verticalOffset = (object.verticalOffset + delta).clamp(-10, 10);
      }
    });
  }

  void adjustSelectedSortBias(double delta) {
    final selected = selectedObjects;
    if (selected.isEmpty) return;
    _recordImmediate(() {
      for (final object in selected) {
        object.sortBias = (object.sortBias + delta).clamp(-5, 5);
        if (object.sortBias.abs() < 0.0001) object.sortBias = 0;
      }
    });
  }

  void deleteSelected() {
    if (_selectedObjectIds.isEmpty) return;
    _recordImmediate(() {
      _document.objects.removeWhere(
        (object) => _selectedObjectIds.contains(object.id),
      );
      _selectedObjectIds.clear();
      _primarySelectedObjectId = null;
    });
  }

  void setActiveLayer(String layerId) {
    if (_document.editorLayerById(layerId) == null ||
        _document.activeLayerId == layerId) {
      return;
    }
    _document.activeLayerId = layerId;
    notifyListeners();
  }

  void addLayer({String? parentId}) {
    final parent = parentId ?? _document.activeLayerId;
    var suffix = _document.editorLayers.length + 1;
    var id = 'layer_$suffix';
    while (_document.editorLayerById(id) != null) {
      id = 'layer_${++suffix}';
    }
    _recordImmediate(() {
      _document.editorLayers.add(
        EditorLayer(id: id, name: 'Layer $suffix', parentId: parent),
      );
      _document.activeLayerId = id;
    });
  }

  void renameLayer(String layerId, String name) {
    final layer = _document.editorLayerById(layerId);
    final trimmed = name.trim();
    if (layer == null || trimmed.isEmpty || layer.name == trimmed) return;
    _recordImmediate(() => layer.name = trimmed);
  }

  bool deleteLayer(String layerId) {
    if (layerId == EnvironmentDocument.rootLayerId ||
        _document.objects.any((object) => object.editorLayerId == layerId) ||
        _document.editorLayers.any((layer) => layer.parentId == layerId)) {
      return false;
    }
    final layer = _document.editorLayerById(layerId);
    if (layer == null) return false;
    _recordImmediate(() {
      _document.editorLayers.remove(layer);
      if (_document.activeLayerId == layerId) {
        _document.activeLayerId =
            layer.parentId ?? EnvironmentDocument.rootLayerId;
      }
    });
    return true;
  }

  void toggleLayerVisibility(String layerId) {
    final layer = _document.editorLayerById(layerId);
    if (layer == null) return;
    _recordImmediate(() => layer.visible = !layer.visible);
    _normalizeSelection();
  }

  void toggleLayerLocked(String layerId) {
    final layer = _document.editorLayerById(layerId);
    if (layer == null) return;
    _recordImmediate(() => layer.locked = !layer.locked);
    _normalizeSelection();
  }

  void moveSelectionToLayer(String layerId) {
    if (_document.editorLayerById(layerId) == null ||
        _selectedObjectIds.isEmpty) {
      return;
    }
    _recordImmediate(() {
      for (final object in selectedObjects) {
        object.editorLayerId = layerId;
      }
    });
  }

  bool isLayerVisible(String layerId) {
    var layer = _document.editorLayerById(layerId);
    final visited = <String>{};
    while (layer != null && visited.add(layer.id)) {
      if (!layer.visible) return false;
      layer = layer.parentId == null
          ? null
          : _document.editorLayerById(layer.parentId!);
    }
    return true;
  }

  bool isLayerLocked(String layerId) {
    var layer = _document.editorLayerById(layerId);
    final visited = <String>{};
    while (layer != null && visited.add(layer.id)) {
      if (layer.locked) return true;
      layer = layer.parentId == null
          ? null
          : _document.editorLayerById(layer.parentId!);
    }
    return false;
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(_snapshot());
    _restore(_undo.removeLast());
    _normalizeSelection();
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(_snapshot());
    _restore(_redo.removeLast());
    _normalizeSelection();
    notifyListeners();
  }

  void replaceDocument(EnvironmentDocument document) {
    _undo.add(_snapshot());
    _document = document;
    _redo.clear();
    _selectedObjectIds.clear();
    _primarySelectedObjectId = null;
    notifyListeners();
  }

  void replaceDocumentFromStreaming(EnvironmentDocument document) {
    _document = document;
    _normalizeSelection();
    notifyListeners();
  }

  void _paint(WorldPoint point) {
    var stroke = _activeStroke;
    if (stroke == null) {
      stroke = TerrainStroke(
        materialId: _selectedMaterialId,
        radius: _brushRadius,
        opacity: 0.88,
        points: [],
      );
      _document.terrainStrokes.add(stroke);
      _activeStroke = stroke;
    }
    if (stroke.points.isNotEmpty) {
      final last = stroke.points.last;
      final distance = math.sqrt(
        math.pow(point.x - last.x, 2) + math.pow(point.y - last.y, 2),
      );
      if (distance < _brushRadius * 0.16) return;
    }
    stroke.points.add(point);
    _gestureChanged = true;
  }

  void _place(WorldPoint point) {
    if (!isLayerVisible(_document.activeLayerId) ||
        isLayerLocked(_document.activeLayerId)) {
      return;
    }
    final object = PlacedEnvironmentObject(
      id: 'object_${_nextObjectId++}',
      assetId: _selectedObjectAssetId,
      x: point.x,
      y: point.y,
      editorLayerId: _document.activeLayerId,
    );
    _document.objects.add(object);
    _selectedObjectIds
      ..clear()
      ..add(object.id);
    _primarySelectedObjectId = object.id;
    _placedThisGesture = true;
    _gestureChanged = true;
  }

  void _selectNearest(WorldPoint point) {
    final object = _nearestObject(point, maxDistance: 1.25);
    _selectedObjectIds.clear();
    if (object != null) _selectedObjectIds.add(object.id);
    _primarySelectedObjectId = object?.id;
    _placedThisGesture = true;
  }

  void _eraseNearest(WorldPoint point) {
    final object = _nearestObject(point, maxDistance: 1.25);
    if (object != null) {
      _document.objects.remove(object);
      _selectedObjectIds.remove(object.id);
      if (_primarySelectedObjectId == object.id) {
        _primarySelectedObjectId = _lastOrNull(_selectedObjectIds);
      }
      _gestureChanged = true;
    }
    _placedThisGesture = true;
  }

  PlacedEnvironmentObject? _nearestObject(
    WorldPoint point, {
    required double maxDistance,
  }) {
    PlacedEnvironmentObject? best;
    var bestDistance = maxDistance;
    for (final object in _document.objects.reversed) {
      if (!_isObjectSelectable(object.id)) continue;
      final distance = math.sqrt(
        math.pow(point.x - object.x, 2) + math.pow(point.y - object.y, 2),
      );
      if (distance <= bestDistance) {
        best = object;
        bestDistance = distance;
      }
    }
    return best;
  }

  void _recordImmediate(VoidCallback mutation) {
    _undo.add(_snapshot());
    mutation();
    _redo.clear();
    notifyListeners();
  }

  void _mutateSelectedGeometry(
    EnvironmentAssetGeometry Function(EnvironmentAssetGeometry geometry)
    mutation,
  ) {
    final object = selectedObject;
    if (object == null) return;
    final asset = catalog.objectById(object.assetId);
    if (asset == null) return;
    final updated = mutation(catalog.geometryForAsset(asset));
    _recordImmediate(() => catalog.setGeometryOverride(asset.id, updated));
  }

  _EditorSnapshot _snapshot() => _EditorSnapshot(
    document: _document.toJsonString(pretty: false),
    geometryOverrides: catalog.geometryOverridesToJsonString(pretty: false),
  );

  void _restore(_EditorSnapshot snapshot) {
    _document = EnvironmentDocument.fromJsonString(snapshot.document);
    catalog.replaceGeometryOverridesFromJsonString(snapshot.geometryOverrides);
  }

  void _normalizeSelection() {
    _selectedObjectIds.removeWhere((id) => !_isObjectSelectable(id));
    if (!_selectedObjectIds.contains(_primarySelectedObjectId)) {
      _primarySelectedObjectId = _lastOrNull(_selectedObjectIds);
    }
  }

  bool _isObjectSelectable(String id) {
    PlacedEnvironmentObject? object;
    for (final candidate in _document.objects) {
      if (candidate.id == id) {
        object = candidate;
        break;
      }
    }
    return object != null &&
        isLayerVisible(object.editorLayerId) &&
        !isLayerLocked(object.editorLayerId);
  }

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  static String? _lastOrNull(Iterable<String> values) {
    String? result;
    for (final value in values) {
      result = value;
    }
    return result;
  }
}

class _EditorSnapshot {
  const _EditorSnapshot({
    required this.document,
    required this.geometryOverrides,
  });

  final String document;
  final String geometryOverrides;
}
