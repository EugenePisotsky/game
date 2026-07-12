import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

enum EnvironmentEditorMode { paint, place, select, erase }

class EditorController extends ChangeNotifier {
  EditorController(this._document, {required this.catalog});

  final EnvironmentCatalog catalog;
  EnvironmentDocument _document;

  EnvironmentDocument get document => _document;

  EnvironmentEditorMode _mode = EnvironmentEditorMode.paint;
  EnvironmentEditorMode get mode => _mode;

  String _selectedMaterialId = 'ow3.ground.earth';
  String get selectedMaterialId => _selectedMaterialId;

  String _selectedObjectAssetId = 'ow3.tree.blossom';
  String get selectedObjectAssetId => _selectedObjectAssetId;

  double _brushRadius = 2.2;
  double get brushRadius => _brushRadius;

  WorldPoint? _hoveredPoint;
  WorldPoint? get hoveredPoint => _hoveredPoint;

  String? _selectedObjectId;
  String? get selectedObjectId => _selectedObjectId;

  PlacedEnvironmentObject? get selectedObject {
    final id = _selectedObjectId;
    if (id == null) return null;
    for (final object in _document.objects) {
      if (object.id == id) return object;
    }
    return null;
  }

  final List<String> _undo = [];
  final List<String> _redo = [];
  String? _gestureBefore;
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

  void setBrushRadius(double value) {
    _brushRadius = value.clamp(0.5, 5);
    notifyListeners();
  }

  void hover(WorldPoint? point) {
    if (_hoveredPoint?.x == point?.x && _hoveredPoint?.y == point?.y) return;
    _hoveredPoint = point;
    notifyListeners();
  }

  void beginGesture() {
    _gestureBefore = _document.toJsonString(pretty: false);
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

  void rotateSelected() {
    final object = selectedObject;
    if (object == null) return;
    _recordImmediate(() => object.direction = object.direction.next);
  }

  void deleteSelected() {
    final object = selectedObject;
    if (object == null) return;
    _recordImmediate(() {
      _document.objects.remove(object);
      _selectedObjectId = null;
    });
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(_document.toJsonString(pretty: false));
    _document = EnvironmentDocument.fromJsonString(_undo.removeLast());
    _normalizeSelection();
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(_document.toJsonString(pretty: false));
    _document = EnvironmentDocument.fromJsonString(_redo.removeLast());
    _normalizeSelection();
    notifyListeners();
  }

  void replaceDocument(EnvironmentDocument document) {
    _undo.add(_document.toJsonString(pretty: false));
    _document = document;
    _redo.clear();
    _selectedObjectId = null;
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
    final object = PlacedEnvironmentObject(
      id: 'object_${_nextObjectId++}',
      assetId: _selectedObjectAssetId,
      x: point.x,
      y: point.y,
    );
    _document.objects.add(object);
    _selectedObjectId = object.id;
    _placedThisGesture = true;
    _gestureChanged = true;
  }

  void _selectNearest(WorldPoint point) {
    final object = _nearestObject(point, maxDistance: 1.25);
    _selectedObjectId = object?.id;
    _placedThisGesture = true;
  }

  void _eraseNearest(WorldPoint point) {
    final object = _nearestObject(point, maxDistance: 1.25);
    if (object != null) {
      _document.objects.remove(object);
      if (_selectedObjectId == object.id) _selectedObjectId = null;
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
    _undo.add(_document.toJsonString(pretty: false));
    mutation();
    _redo.clear();
    notifyListeners();
  }

  void _normalizeSelection() {
    if (selectedObject == null) _selectedObjectId = null;
  }
}
