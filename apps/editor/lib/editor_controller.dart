import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

enum EnvironmentEditorMode {
  paint,
  place,
  path,
  select,
  collision,
  erase,
  spawn,
}

enum GeometryRole { footprint, blocking, walkable, selection }

enum GeometryShapeType { circle, ellipse, rectangle, capsule, polygon }

class PathPlacementPreview {
  const PathPlacementPreview({required this.point, required this.direction});

  final WorldPoint point;
  final EnvironmentDirection direction;
}

enum _PathDragHandle { start, end }

class EditorController extends ChangeNotifier {
  EditorController(this._document, {required this.catalog}) {
    _rebuildIndexes();
  }

  final EnvironmentCatalog catalog;
  final _HoverNotifier _hoverNotifier = _HoverNotifier();
  final ChangeNotifier _paletteNotifier = ChangeNotifier();
  EnvironmentDocument _document;
  final Map<String, PlacedEnvironmentObject> _objectsById = {};
  final Map<String, EditorLayer> _layersById = {};
  final Map<String, bool> _layerVisibility = {};
  final Map<String, bool> _layerLocked = {};
  int _sceneRevision = 0;
  Set<String>? _lastSceneChangedObjectIds;

  Listenable get hoverListenable => _hoverNotifier;
  Listenable get paletteListenable => _paletteNotifier;

  EnvironmentDocument get document => _document;
  int get sceneRevision => _sceneRevision;
  Set<String>? get lastSceneChangedObjectIds => _lastSceneChangedObjectIds;

  PlacedEnvironmentObject? objectById(String id) => _objectsById[id];

  EditorLayer? editorLayerById(String id) => _layersById[id];

  EnvironmentEditorMode _mode = EnvironmentEditorMode.paint;
  EnvironmentEditorMode get mode => _mode;
  bool get isObjectSelectionMode =>
      _mode == EnvironmentEditorMode.select ||
      _mode == EnvironmentEditorMode.collision;

  String _selectedMaterialId = 'ow3.ground.earth';
  String get selectedMaterialId => _selectedMaterialId;

  String _selectedObjectAssetId = 'ow3.tree.blossom';
  String get selectedObjectAssetId => _selectedObjectAssetId;
  EnvironmentDirection _placementDirection = EnvironmentDirection.south;
  EnvironmentDirection get placementDirection => _placementDirection;

  double _pathPieceLength = 3.2;
  double get pathPieceLength => _pathPieceLength;
  double _pathGap = 0;
  double get pathGap => _pathGap;
  double _pathOpening = 0;
  double get pathOpening => _pathOpening;
  int _pathDirectionOffset = 0;
  int get pathDirectionOffset => _pathDirectionOffset;
  WorldPoint? _pathStart;
  WorldPoint? get pathStart => _pathStart;
  WorldPoint? _pathEnd;
  WorldPoint? get pathEnd => _pathEnd;
  bool get hasPathDraft => _pathStart != null && _pathEnd != null;
  _PathDragHandle? _activePathDragHandle;
  bool _pathGestureStarted = false;
  List<PathPlacementPreview> get pathPreviewPlacements =>
      List.unmodifiable(_buildPathPlacements());

  double _brushRadius = 2.2;
  double get brushRadius => _brushRadius;
  double _brushFlow = 0.22;
  double get brushFlow => _brushFlow;
  double _brushScatter = 0.28;
  double get brushScatter => _brushScatter;
  int _nextStrokeSeed = 1;

  WorldPoint? _hoveredPoint;
  WorldPoint? get hoveredPoint => _hoveredPoint;

  final Set<String> _selectedObjectIds = {};
  String? _primarySelectedObjectId;
  String? get selectedObjectId => _primarySelectedObjectId;
  Set<String> get selectedObjectIds => Set.unmodifiable(_selectedObjectIds);

  List<PlacedEnvironmentObject> get selectedObjects => _selectedObjectIds
      .map((id) => _objectsById[id])
      .whereType<PlacedEnvironmentObject>()
      .toList();

  PlacedEnvironmentObject? get selectedObject {
    final id = _primarySelectedObjectId;
    return id == null ? null : _objectsById[id];
  }

  String? _hoveredObjectId;
  String? get hoveredObjectId => _hoveredObjectId;

  List<String> _overlapCandidateIds = const [];
  List<String> get overlapCandidateIds =>
      List.unmodifiable(_overlapCandidateIds);

  EditorLayer get activeLayer => _layersById[_document.activeLayerId]!;

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
      case GeometryRole.selection:
        return _geometryShapeIndex < geometry.selection.length
            ? geometry.selection[_geometryShapeIndex]
            : null;
    }
  }

  final List<_EditorCommand> _undo = [];
  final List<_EditorCommand> _redo = [];
  final Map<String, _ObjectRecord> _gestureObjectBefore = {};
  final Set<String> _gestureObjectIds = {};
  TerrainStroke? _activeStroke;
  int _terrainRevision = 0;
  TerrainStroke? _lastTerrainChangedStroke;
  bool _gestureChanged = false;
  bool _placedThisGesture = false;
  final String _objectIdNamespace = _nextObjectIdNamespace();
  int _nextObjectId = 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get terrainRevision => _terrainRevision;
  TerrainStroke? get lastTerrainChangedStroke => _lastTerrainChangedStroke;
  TerrainStroke? get activeTerrainStroke => _activeStroke;

  void selectPaintMaterial(EnvironmentMaterial material) {
    _mode = EnvironmentEditorMode.paint;
    _selectedMaterialId = material.id;
    _brushRadius = material.defaultRadius;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void selectObjectAsset(EnvironmentObjectAsset object) {
    _mode = EnvironmentEditorMode.place;
    _selectObjectAsset(object);
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void selectPathObjectAsset(EnvironmentObjectAsset object) {
    _mode = EnvironmentEditorMode.path;
    _selectObjectAsset(object);
    _pathPieceLength = _suggestedPathPieceLength(object);
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void selectMode(EnvironmentEditorMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    if (mode == EnvironmentEditorMode.path) {
      final asset = catalog.objectById(_selectedObjectAssetId);
      if (asset != null) _pathPieceLength = _suggestedPathPieceLength(asset);
    }
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setPathPieceLength(double value) {
    _pathPieceLength = value.clamp(0.25, 8);
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setPathGap(double value) {
    _pathGap = value.clamp(-1.5, 6);
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setPathOpening(double value) {
    _pathOpening = value.clamp(0, 12);
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void rotatePathOrientation() {
    _pathDirectionOffset = (_pathDirectionOffset + 1) % 8;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void applyPathDraft() {
    if (!hasPathDraft ||
        !isLayerVisible(_document.activeLayerId) ||
        isLayerLocked(_document.activeLayerId)) {
      return;
    }
    final placements = _buildPathPlacements();
    if (placements.isEmpty) return;
    final objects = [
      for (final placement in placements)
        PlacedEnvironmentObject(
          id: _newPlacedObjectId(),
          assetId: _selectedObjectAssetId,
          x: placement.point.x,
          y: placement.point.y,
          editorLayerId: _document.activeLayerId,
          direction: placement.direction,
        ),
    ];
    _recordObjectMutation(objects.map((object) => object.id), () {
      _selectedObjectIds.clear();
      for (final object in objects) {
        _document.objects.add(object);
        _selectedObjectIds.add(object.id);
        _primarySelectedObjectId = object.id;
      }
      _pathStart = null;
      _pathEnd = null;
      _activePathDragHandle = null;
    });
    _paletteNotifier.notifyListeners();
  }

  void cancelPathDraft() {
    if (!hasPathDraft) return;
    _pathStart = null;
    _pathEnd = null;
    _activePathDragHandle = null;
    notifyListeners();
    _paletteNotifier.notifyListeners();
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
        case GeometryRole.selection:
          final shapes = [...geometry.selection];
          if (_geometryShapeIndex >= shapes.length) return geometry;
          shapes[_geometryShapeIndex] = shape;
          return geometry.copyWith(selection: shapes, reviewed: false);
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
        case GeometryRole.selection:
          final shapes = [...geometry.selection, shape];
          _geometryShapeIndex = shapes.length - 1;
          return geometry.copyWith(selection: shapes, reviewed: false);
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
        case GeometryRole.selection:
          final shapes = [...geometry.selection]..removeAt(_geometryShapeIndex);
          _geometryShapeIndex = math.max(0, _geometryShapeIndex - 1);
          return geometry.copyWith(selection: shapes, reviewed: false);
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
    _recordGeometryMutation(
      object.assetId,
      () => catalog.removeGeometryOverride(object.assetId),
    );
    _geometryShapeIndex = 0;
  }

  Future<void> saveGeometryOverrides() =>
      saveEnvironmentGeometryOverrides(catalog.geometryOverridesToJsonString());

  void setBrushRadius(double value) {
    _brushRadius = value.clamp(0.5, 5);
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setBrushFlow(double value) {
    _brushFlow = value.clamp(0.05, 0.6);
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setBrushScatter(double value) {
    _brushScatter = value.clamp(0, 0.65);
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void hover(WorldPoint? point) {
    if (_hoveredPoint?.x == point?.x && _hoveredPoint?.y == point?.y) return;
    _hoveredPoint = point;
    _hoverNotifier.changed();
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
    _hoverNotifier.changed();
  }

  @override
  void dispose() {
    _hoverNotifier.dispose();
    _paletteNotifier.dispose();
    super.dispose();
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
    _gestureObjectBefore.clear();
    _gestureObjectIds.clear();
    _gestureChanged = false;
    _placedThisGesture = false;
    _activeStroke = null;
    _activePathDragHandle = null;
    _pathGestureStarted = false;
  }

  void applyAt(WorldPoint point) {
    if (!_document.contains(point.x, point.y)) return;
    _hoveredPoint = point;
    switch (_mode) {
      case EnvironmentEditorMode.paint:
        _paint(point);
      case EnvironmentEditorMode.place:
        if (!_placedThisGesture) _place(point);
      case EnvironmentEditorMode.path:
        if (!_pathGestureStarted) {
          _pathGestureStarted = true;
          _activePathDragHandle = _pathHandleNear(point);
          if (_activePathDragHandle == null) {
            _pathStart = point;
            _pathEnd = point;
            _activePathDragHandle = _PathDragHandle.end;
          }
        }
        switch (_activePathDragHandle) {
          case _PathDragHandle.start:
            _pathStart = point;
            break;
          case _PathDragHandle.end:
            _pathEnd = point;
            break;
          case null:
            break;
        }
        _hoveredPoint = point;
        _hoverNotifier.changed();
      case EnvironmentEditorMode.select:
      case EnvironmentEditorMode.collision:
        _selectNearest(point);
      case EnvironmentEditorMode.erase:
        if (!_placedThisGesture) _eraseNearest(point);
      case EnvironmentEditorMode.spawn:
        break;
    }
  }

  void endGesture() {
    final committedTerrainStroke = _gestureChanged ? _activeStroke : null;
    if (_gestureChanged) {
      final commands = <_EditorCommand>[];
      if (_gestureObjectIds.isNotEmpty) {
        commands.add(
          _ObjectDeltaCommand(
            before: Map.of(_gestureObjectBefore),
            after: _captureObjects(_gestureObjectIds),
          ),
        );
      }
      if (committedTerrainStroke != null) {
        commands.add(
          _TerrainStrokeCommand(
            index: _document.terrainStrokes.indexOf(committedTerrainStroke),
            stroke: _copyTerrainStroke(committedTerrainStroke),
          ),
        );
      }
      _pushCommand(
        commands.length == 1
            ? commands.single
            : _CompositeEditorCommand(commands),
      );
    }
    _gestureObjectBefore.clear();
    _gestureObjectIds.clear();
    _activeStroke = null;
    _activePathDragHandle = null;
    _pathGestureStarted = false;
    if (committedTerrainStroke != null) {
      _markTerrainChanged(committedTerrainStroke);
    }
    _gestureChanged = false;
    _placedThisGesture = false;
    notifyListeners();
    if (_mode == EnvironmentEditorMode.path) {
      _paletteNotifier.notifyListeners();
    }
  }

  void moveSelectedTo(WorldPoint point) {
    final object = selectedObject;
    if (object == null || !_document.contains(point.x, point.y)) return;
    _recordObjectMutation([object.id], () {
      object
        ..x = point.x
        ..y = point.y;
    });
  }

  void moveSelectedDuringGesture(WorldPoint point) {
    final object = selectedObject;
    if (object == null || !_document.contains(point.x, point.y)) return;
    _rememberGestureObjects([object]);
    object
      ..x = point.x
      ..y = point.y;
    _gestureChanged = true;
    _markObjectSceneChanged([object.id]);
    _hoveredPoint = point;
    _hoverNotifier.changed();
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
    _rememberGestureObjects(selected);
    for (final object in selected) {
      object
        ..x += dx
        ..y += dy;
    }
    _gestureChanged = true;
    _markObjectSceneChanged(selected.map((object) => object.id));
    _hoveredPoint = to;
    _hoverNotifier.changed();
  }

  void rotateSelected() {
    final selected = selectedObjects;
    if (selected.isEmpty) return;
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        final asset = catalog.objectById(object.assetId);
        if (asset == null) continue;
        final supported = _clockwiseDirections
            .where((direction) => asset.supportsDirection(direction.name))
            .toList();
        if (supported.length < 2) continue;
        final current = supported.indexOf(object.direction);
        object.direction = supported[(current + 1) % supported.length];
      }
      _rememberPlacementDirection(selected);
    });
  }

  void setSelectedDirection(EnvironmentDirection direction) {
    final selected = selectedObjects;
    if (selected.isEmpty ||
        selected.any(
          (object) =>
              !(catalog
                      .objectById(object.assetId)
                      ?.supportsDirection(direction.name) ??
                  false),
        ) ||
        selected.every((object) => object.direction == direction)) {
      return;
    }
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        object.direction = direction;
      }
      _rememberPlacementDirection(selected);
    });
  }

  void adjustSelectedVerticalOffset(double delta) {
    final selected = selectedObjects;
    if (selected.isEmpty) return;
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        object.verticalOffset = (object.verticalOffset + delta).clamp(-10, 10);
      }
    });
  }

  void adjustSelectedSortBias(double delta) {
    final selected = selectedObjects;
    if (selected.isEmpty) return;
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        object.sortBias = (object.sortBias + delta).clamp(-5, 5);
        if (object.sortBias.abs() < 0.0001) object.sortBias = 0;
      }
    });
  }

  void deleteSelected() {
    if (_selectedObjectIds.isEmpty) return;
    final ids = Set<String>.of(_selectedObjectIds);
    _recordObjectMutation(ids, () {
      _document.objects.removeWhere(
        (object) => _selectedObjectIds.contains(object.id),
      );
      _selectedObjectIds.clear();
      _primarySelectedObjectId = null;
    });
  }

  void setActiveLayer(String layerId) {
    if (_layersById[layerId] == null || _document.activeLayerId == layerId) {
      return;
    }
    _document.activeLayerId = layerId;
    notifyListeners();
  }

  void addLayer({String? parentId}) {
    final parent = parentId ?? _document.activeLayerId;
    var suffix = _document.editorLayers.length + 1;
    var id = 'layer_$suffix';
    while (_layersById[id] != null) {
      id = 'layer_${++suffix}';
    }
    _recordLayerMutation([id], () {
      _document.editorLayers.add(
        EditorLayer(id: id, name: 'Layer $suffix', parentId: parent),
      );
      _document.activeLayerId = id;
    });
  }

  void renameLayer(String layerId, String name) {
    final layer = _layersById[layerId];
    final trimmed = name.trim();
    if (layer == null || trimmed.isEmpty || layer.name == trimmed) return;
    _recordLayerMutation([layerId], () => layer.name = trimmed);
  }

  bool canReparentLayer(String layerId, String parentId) {
    if (layerId == EnvironmentDocument.rootLayerId || layerId == parentId) {
      return false;
    }
    final layer = _layersById[layerId];
    final parent = _layersById[parentId];
    if (layer == null || parent == null || layer.parentId == parentId) {
      return false;
    }
    var ancestor = parent;
    final visited = <String>{};
    while (visited.add(ancestor.id)) {
      if (ancestor.id == layerId) return false;
      final next = ancestor.parentId;
      if (next == null) break;
      final resolved = _layersById[next];
      if (resolved == null) break;
      ancestor = resolved;
    }
    return true;
  }

  bool reparentLayer(String layerId, String parentId) {
    if (!canReparentLayer(layerId, parentId)) return false;
    final layer = _layersById[layerId]!;
    _recordLayerMutation([layerId], () => layer.parentId = parentId);
    return true;
  }

  bool deleteLayer(String layerId) {
    if (layerId == EnvironmentDocument.rootLayerId ||
        _document.objects.any((object) => object.editorLayerId == layerId) ||
        _document.editorLayers.any((layer) => layer.parentId == layerId)) {
      return false;
    }
    final layer = _layersById[layerId];
    if (layer == null) return false;
    _recordLayerMutation([layerId], () {
      _document.editorLayers.remove(layer);
      if (_document.activeLayerId == layerId) {
        _document.activeLayerId =
            layer.parentId ?? EnvironmentDocument.rootLayerId;
      }
    });
    return true;
  }

  void toggleLayerVisibility(String layerId) {
    final layer = _layersById[layerId];
    if (layer == null) return;
    _recordLayerMutation([layerId], () => layer.visible = !layer.visible);
    _normalizeSelection();
  }

  void toggleLayerLocked(String layerId) {
    final layer = _layersById[layerId];
    if (layer == null) return;
    _recordLayerMutation([layerId], () => layer.locked = !layer.locked);
    _normalizeSelection();
  }

  void toggleLayerExported(String layerId) {
    if (layerId == EnvironmentDocument.rootLayerId) return;
    final layer = _layersById[layerId];
    if (layer == null) return;
    _recordLayerMutation([layerId], () => layer.exported = !layer.exported);
  }

  void moveSelectionToLayer(String layerId) {
    if (_layersById[layerId] == null || _selectedObjectIds.isEmpty) {
      return;
    }
    _recordObjectMutation(_selectedObjectIds, () {
      for (final object in selectedObjects) {
        object.editorLayerId = layerId;
      }
    });
  }

  bool isLayerVisible(String layerId) {
    final cached = _layerVisibility[layerId];
    if (cached != null) return cached;
    var layer = _layersById[layerId];
    final visited = <String>{};
    var visible = true;
    while (layer != null && visited.add(layer.id)) {
      if (!layer.visible) {
        visible = false;
        break;
      }
      layer = layer.parentId == null ? null : _layersById[layer.parentId!];
    }
    _layerVisibility[layerId] = visible;
    return visible;
  }

  bool isLayerLocked(String layerId) {
    final cached = _layerLocked[layerId];
    if (cached != null) return cached;
    var layer = _layersById[layerId];
    final visited = <String>{};
    var locked = false;
    while (layer != null && visited.add(layer.id)) {
      if (layer.locked) {
        locked = true;
        break;
      }
      layer = layer.parentId == null ? null : _layersById[layer.parentId!];
    }
    _layerLocked[layerId] = locked;
    return locked;
  }

  void undo() {
    if (!canUndo) return;
    final command = _undo.removeLast();
    command.undo(this);
    _redo.add(command);
    _markSceneChanged(objectIds: command.affectedObjectIds);
    if (command.affectsTerrain) _markTerrainChanged();
    _normalizeSelection();
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    final command = _redo.removeLast();
    command.redo(this);
    _undo.add(command);
    _markSceneChanged(objectIds: command.affectedObjectIds);
    if (command.affectsTerrain) _markTerrainChanged();
    _normalizeSelection();
    notifyListeners();
  }

  void replaceDocument(EnvironmentDocument document) {
    final command = _ReplaceDocumentCommand(
      before: _copyDocument(_document),
      after: _copyDocument(document),
    );
    _document = _copyDocument(document);
    _pushCommand(command);
    _selectedObjectIds.clear();
    _primarySelectedObjectId = null;
    _markSceneChanged();
    _markTerrainChanged();
    notifyListeners();
  }

  void replaceDocumentFromStreaming(EnvironmentDocument document) {
    _document = document;
    _markSceneChanged();
    _normalizeSelection();
    notifyListeners();
  }

  void _paint(WorldPoint point) {
    var stroke = _activeStroke;
    if (stroke == null) {
      stroke = TerrainStroke(
        materialId: _selectedMaterialId,
        radius: _brushRadius,
        opacity: _brushFlow,
        seed: _nextTerrainStrokeSeed(),
        spacing: 0.72,
        scatter: _brushScatter,
        sizeJitter: 0.18,
        opacityJitter: 0.16,
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

  void _markTerrainChanged([TerrainStroke? stroke]) {
    _terrainRevision++;
    _lastTerrainChangedStroke = stroke;
  }

  int _nextTerrainStrokeSeed() {
    final index = _document.terrainStrokes.length + _nextStrokeSeed++;
    return (index * 1103515245 + 12345) & 0x7FFFFFFF;
  }

  void _place(WorldPoint point) {
    if (!isLayerVisible(_document.activeLayerId) ||
        isLayerLocked(_document.activeLayerId)) {
      return;
    }
    final object = PlacedEnvironmentObject(
      id: _newPlacedObjectId(),
      assetId: _selectedObjectAssetId,
      x: point.x,
      y: point.y,
      editorLayerId: _document.activeLayerId,
      direction: _placementDirection,
    );
    _gestureObjectIds.add(object.id);
    _gestureObjectBefore[object.id] = const _ObjectRecord.absent();
    _document.objects.add(object);
    _objectsById[object.id] = object;
    _markObjectSceneChanged([object.id]);
    _selectedObjectIds
      ..clear()
      ..add(object.id);
    _primarySelectedObjectId = object.id;
    _placedThisGesture = true;
    _gestureChanged = true;
  }

  String _newPlacedObjectId() {
    while (true) {
      final candidate = 'object_${_objectIdNamespace}_${_nextObjectId++}';
      if (_document.objects.every((object) => object.id != candidate)) {
        return candidate;
      }
    }
  }

  List<PathPlacementPreview> _buildPathPlacements() {
    final start = _pathStart;
    final end = _pathEnd;
    final asset = catalog.objectById(_selectedObjectAssetId);
    if (start == null || end == null || asset == null) return const [];
    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final length = math.sqrt(dx * dx + dy * dy);
    final direction = _nearestSupportedPathDirection(asset, dx, dy);
    if (length < 0.001) {
      return [PathPlacementPreview(point: start, direction: direction)];
    }
    final requestedStep = math.max(0.1, _pathPieceLength + _pathGap);
    var count = (length / requestedStep).floor() + 1;
    count = math.min(500, math.max(1, count));
    if (count == 1) {
      return [
        PathPlacementPreview(
          point: WorldPoint((start.x + end.x) / 2, (start.y + end.y) / 2),
          direction: direction,
        ),
      ];
    }
    final step = count == 500 && length / requestedStep >= 500
        ? length / (count - 1)
        : requestedStep;
    final occupiedLength = (count - 1) * step;
    final firstDistance = math.max(0, (length - occupiedLength) / 2);
    final openingCenter = length / 2;
    return [
      for (var index = 0; index < count; index++)
        if (_pathOpening <= 0 ||
            (firstDistance + index * step - openingCenter).abs() >=
                _pathOpening / 2)
          PathPlacementPreview(
            point: WorldPoint(
              start.x + dx * ((firstDistance + index * step) / length),
              start.y + dy * ((firstDistance + index * step) / length),
            ),
            direction: direction,
          ),
    ];
  }

  _PathDragHandle? _pathHandleNear(WorldPoint point) {
    const handleRadius = 1.1;
    final start = _pathStart;
    final end = _pathEnd;
    if (start == null || end == null) return null;
    final startDistance = _distanceBetween(start, point);
    final endDistance = _distanceBetween(end, point);
    if (math.min(startDistance, endDistance) > handleRadius) return null;
    return startDistance <= endDistance
        ? _PathDragHandle.start
        : _PathDragHandle.end;
  }

  static double _distanceBetween(WorldPoint a, WorldPoint b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  void _selectObjectAsset(EnvironmentObjectAsset object) {
    if (_selectedObjectAssetId != object.id) {
      _selectedObjectAssetId = object.id;
      _placementDirection = _defaultDirectionFor(object);
    }
  }

  EnvironmentDirection _defaultDirectionFor(EnvironmentObjectAsset asset) {
    if (asset.supportsDirection(EnvironmentDirection.south.name)) {
      return EnvironmentDirection.south;
    }
    return _clockwiseDirections.firstWhere(
      (direction) => asset.supportsDirection(direction.name),
      orElse: () => EnvironmentDirection.south,
    );
  }

  void _rememberPlacementDirection(List<PlacedEnvironmentObject> selected) {
    if (selected.isEmpty ||
        selected.any((object) => object.assetId != _selectedObjectAssetId)) {
      return;
    }
    final direction = selected.first.direction;
    if (selected.every((object) => object.direction == direction)) {
      _placementDirection = direction;
    }
  }

  EnvironmentDirection _nearestSupportedPathDirection(
    EnvironmentObjectAsset asset,
    double dx,
    double dy,
  ) {
    final screenX = dx - dy;
    final screenY = dx + dy;
    final sector =
        ((math.atan2(screenY, screenX) / (math.pi / 4)).round() + 8) % 8;
    final desired = const [
      EnvironmentDirection.east,
      EnvironmentDirection.southEast,
      EnvironmentDirection.south,
      EnvironmentDirection.southWest,
      EnvironmentDirection.west,
      EnvironmentDirection.northWest,
      EnvironmentDirection.north,
      EnvironmentDirection.northEast,
    ][sector];
    final desiredIndex =
        (_clockwiseDirections.indexOf(desired) + _pathDirectionOffset) % 8;
    EnvironmentDirection? nearest;
    var nearestDistance = 9;
    for (final direction in _clockwiseDirections) {
      if (!asset.supportsDirection(direction.name)) continue;
      final index = _clockwiseDirections.indexOf(direction);
      final clockwise = (index - desiredIndex + 8) % 8;
      final distance = math.min(clockwise, 8 - clockwise);
      if (distance < nearestDistance) {
        nearest = direction;
        nearestDistance = distance;
      }
    }
    return nearest ?? EnvironmentDirection.south;
  }

  static double _suggestedPathPieceLength(EnvironmentObjectAsset asset) {
    if (!asset.geometry.reviewed) {
      return (3.2 * asset.renderScale).clamp(0.25, 8).toDouble();
    }
    final footprint = asset.geometry.footprint;
    final length = switch (footprint) {
      EnvironmentCapsule() =>
        math.sqrt(
              math.pow(footprint.end.x - footprint.start.x, 2) +
                  math.pow(footprint.end.y - footprint.start.y, 2),
            ) +
            footprint.radius * 2,
      EnvironmentRectangle() => math.max(
        footprint.size.x.abs(),
        footprint.size.y.abs(),
      ),
      EnvironmentEllipse() =>
        math.max(footprint.radius.x.abs(), footprint.radius.y.abs()) * 2,
      EnvironmentCircle() => footprint.radius * 2,
      EnvironmentPolygon() when footprint.points.isNotEmpty =>
        _polygonPathLength(footprint),
      _ => 3.2 * asset.renderScale,
    };
    return length.clamp(0.25, 8).toDouble();
  }

  static double _polygonPathLength(EnvironmentPolygon polygon) {
    final xs = polygon.points.map((point) => point.x);
    final ys = polygon.points.map((point) => point.y);
    return math.max(
      xs.reduce(math.max) - xs.reduce(math.min),
      ys.reduce(math.max) - ys.reduce(math.min),
    );
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
      _rememberGestureObjects([object]);
      _document.objects.remove(object);
      _objectsById.remove(object.id);
      _markObjectSceneChanged([object.id]);
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

  void _recordObjectMutation(
    Iterable<String> objectIds,
    VoidCallback mutation,
  ) {
    final ids = Set<String>.of(objectIds);
    final before = _captureObjects(ids);
    mutation();
    final after = _captureObjects(ids);
    _pushCommand(_ObjectDeltaCommand(before: before, after: after));
    _markSceneChanged(objectIds: ids);
    notifyListeners();
  }

  void _recordLayerMutation(Iterable<String> layerIds, VoidCallback mutation) {
    final ids = Set<String>.of(layerIds);
    final before = _captureLayers(ids);
    final activeLayerBefore = _document.activeLayerId;
    mutation();
    final after = _captureLayers(ids);
    _pushCommand(
      _LayerDeltaCommand(
        before: before,
        after: after,
        activeLayerBefore: activeLayerBefore,
        activeLayerAfter: _document.activeLayerId,
      ),
    );
    _markSceneChanged();
    notifyListeners();
  }

  void _recordGeometryMutation(String assetId, VoidCallback mutation) {
    final before = catalog.geometryOverrides[assetId];
    mutation();
    final after = catalog.geometryOverrides[assetId];
    _pushCommand(
      _GeometryDeltaCommand(assetId: assetId, before: before, after: after),
    );
    _markSceneChanged();
    notifyListeners();
  }

  void _rememberGestureObjects(Iterable<PlacedEnvironmentObject> objects) {
    for (final object in objects) {
      if (_gestureObjectIds.add(object.id)) {
        final index = _document.objects.indexOf(object);
        _gestureObjectBefore[object.id] = _ObjectRecord(
          index: index,
          object: _copyPlacedObject(object),
        );
      }
    }
  }

  Map<String, _ObjectRecord> _captureObjects(Iterable<String> ids) {
    final result = <String, _ObjectRecord>{};
    for (final id in ids) {
      final index = _document.objects.indexWhere((object) => object.id == id);
      result[id] = index < 0
          ? const _ObjectRecord.absent()
          : _ObjectRecord(
              index: index,
              object: _copyPlacedObject(_document.objects[index]),
            );
    }
    return result;
  }

  Map<String, _LayerRecord> _captureLayers(Iterable<String> ids) {
    final result = <String, _LayerRecord>{};
    for (final id in ids) {
      final index = _document.editorLayers.indexWhere(
        (layer) => layer.id == id,
      );
      result[id] = index < 0
          ? const _LayerRecord.absent()
          : _LayerRecord(
              index: index,
              layer: EditorLayer.fromJson(
                _document.editorLayers[index].toJson(),
              ),
            );
    }
    return result;
  }

  void _pushCommand(_EditorCommand command) {
    _undo.add(command);
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
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
    _recordGeometryMutation(
      asset.id,
      () => catalog.setGeometryOverride(asset.id, updated),
    );
  }

  void _normalizeSelection() {
    _selectedObjectIds.removeWhere((id) => !_isObjectSelectable(id));
    if (!_selectedObjectIds.contains(_primarySelectedObjectId)) {
      _primarySelectedObjectId = _lastOrNull(_selectedObjectIds);
    }
  }

  bool _isObjectSelectable(String id) {
    final object = _objectsById[id];
    return object != null &&
        isLayerVisible(object.editorLayerId) &&
        !isLayerLocked(object.editorLayerId);
  }

  void _markSceneChanged({Iterable<String>? objectIds}) {
    _sceneRevision++;
    _lastSceneChangedObjectIds = objectIds == null
        ? null
        : Set.unmodifiable(Set.of(objectIds));
    _rebuildIndexes();
  }

  void _markObjectSceneChanged(Iterable<String> objectIds) {
    _sceneRevision++;
    _lastSceneChangedObjectIds = Set.unmodifiable(Set.of(objectIds));
  }

  void _rebuildIndexes() {
    _objectsById
      ..clear()
      ..addEntries(
        _document.objects.map((object) => MapEntry(object.id, object)),
      );
    _layersById
      ..clear()
      ..addEntries(
        _document.editorLayers.map((layer) => MapEntry(layer.id, layer)),
      );
    _layerVisibility.clear();
    _layerLocked.clear();
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

class _HoverNotifier extends ChangeNotifier {
  void changed() => notifyListeners();
}

const _clockwiseDirections = [
  EnvironmentDirection.south,
  EnvironmentDirection.southWest,
  EnvironmentDirection.west,
  EnvironmentDirection.northWest,
  EnvironmentDirection.north,
  EnvironmentDirection.northEast,
  EnvironmentDirection.east,
  EnvironmentDirection.southEast,
];

int _objectIdNamespaceSequence = 0;

String _nextObjectIdNamespace() {
  final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final sequence = (_objectIdNamespaceSequence++).toRadixString(36);
  return '${timestamp}_$sequence';
}

abstract class _EditorCommand {
  const _EditorCommand();

  bool get affectsTerrain => false;
  Set<String>? get affectedObjectIds => null;

  void undo(EditorController controller);

  void redo(EditorController controller);
}

class _ObjectRecord {
  const _ObjectRecord({required this.index, required this.object});
  const _ObjectRecord.absent() : index = -1, object = null;

  final int index;
  final PlacedEnvironmentObject? object;
}

class _ObjectDeltaCommand extends _EditorCommand {
  const _ObjectDeltaCommand({required this.before, required this.after});

  final Map<String, _ObjectRecord> before;
  final Map<String, _ObjectRecord> after;

  @override
  Set<String> get affectedObjectIds => {...before.keys, ...after.keys};

  @override
  void undo(EditorController controller) => _apply(controller, before);

  @override
  void redo(EditorController controller) => _apply(controller, after);

  void _apply(EditorController controller, Map<String, _ObjectRecord> records) {
    controller._document.objects.removeWhere(
      (object) => records.containsKey(object.id),
    );
    final present =
        records.values.where((record) => record.object != null).toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    for (final record in present) {
      final index = record.index.clamp(0, controller._document.objects.length);
      controller._document.objects.insert(
        index,
        _copyPlacedObject(record.object!),
      );
    }
  }
}

class _LayerRecord {
  const _LayerRecord({required this.index, required this.layer});
  const _LayerRecord.absent() : index = -1, layer = null;

  final int index;
  final EditorLayer? layer;
}

class _LayerDeltaCommand extends _EditorCommand {
  const _LayerDeltaCommand({
    required this.before,
    required this.after,
    required this.activeLayerBefore,
    required this.activeLayerAfter,
  });

  final Map<String, _LayerRecord> before;
  final Map<String, _LayerRecord> after;
  final String activeLayerBefore;
  final String activeLayerAfter;

  @override
  void undo(EditorController controller) =>
      _apply(controller, before, activeLayerBefore);

  @override
  void redo(EditorController controller) =>
      _apply(controller, after, activeLayerAfter);

  void _apply(
    EditorController controller,
    Map<String, _LayerRecord> records,
    String activeLayerId,
  ) {
    controller._document.editorLayers.removeWhere(
      (layer) => records.containsKey(layer.id),
    );
    final present =
        records.values.where((record) => record.layer != null).toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    for (final record in present) {
      final index = record.index.clamp(
        0,
        controller._document.editorLayers.length,
      );
      controller._document.editorLayers.insert(
        index,
        EditorLayer.fromJson(record.layer!.toJson()),
      );
    }
    controller._document.activeLayerId = activeLayerId;
  }
}

class _TerrainStrokeCommand extends _EditorCommand {
  const _TerrainStrokeCommand({required this.index, required this.stroke});

  final int index;
  final TerrainStroke stroke;

  @override
  bool get affectsTerrain => true;

  @override
  Set<String> get affectedObjectIds => const {};

  @override
  void undo(EditorController controller) {
    if (index >= 0 && index < controller._document.terrainStrokes.length) {
      controller._document.terrainStrokes.removeAt(index);
    }
  }

  @override
  void redo(EditorController controller) {
    controller._document.terrainStrokes.insert(
      index.clamp(0, controller._document.terrainStrokes.length),
      _copyTerrainStroke(stroke),
    );
  }
}

class _GeometryDeltaCommand extends _EditorCommand {
  const _GeometryDeltaCommand({
    required this.assetId,
    required this.before,
    required this.after,
  });

  final String assetId;
  final EnvironmentAssetGeometry? before;
  final EnvironmentAssetGeometry? after;

  @override
  void undo(EditorController controller) => _apply(controller, before);

  @override
  void redo(EditorController controller) => _apply(controller, after);

  void _apply(EditorController controller, EnvironmentAssetGeometry? geometry) {
    if (geometry == null) {
      controller.catalog.removeGeometryOverride(assetId);
    } else {
      controller.catalog.setGeometryOverride(assetId, geometry);
    }
  }
}

class _ReplaceDocumentCommand extends _EditorCommand {
  const _ReplaceDocumentCommand({required this.before, required this.after});

  final EnvironmentDocument before;
  final EnvironmentDocument after;

  @override
  bool get affectsTerrain => true;

  @override
  void undo(EditorController controller) {
    controller._document = _copyDocument(before);
  }

  @override
  void redo(EditorController controller) {
    controller._document = _copyDocument(after);
  }
}

class _CompositeEditorCommand extends _EditorCommand {
  const _CompositeEditorCommand(this.commands);

  final List<_EditorCommand> commands;

  @override
  bool get affectsTerrain => commands.any((command) => command.affectsTerrain);

  @override
  Set<String>? get affectedObjectIds {
    final result = <String>{};
    for (final command in commands) {
      final ids = command.affectedObjectIds;
      if (ids == null) return null;
      result.addAll(ids);
    }
    return result;
  }

  @override
  void undo(EditorController controller) {
    for (final command in commands.reversed) {
      command.undo(controller);
    }
  }

  @override
  void redo(EditorController controller) {
    for (final command in commands) {
      command.redo(controller);
    }
  }
}

PlacedEnvironmentObject _copyPlacedObject(PlacedEnvironmentObject object) =>
    PlacedEnvironmentObject.fromJson(object.toJson());

TerrainStroke _copyTerrainStroke(TerrainStroke stroke) =>
    TerrainStroke.fromJson(stroke.toJson());

EnvironmentDocument _copyDocument(EnvironmentDocument document) =>
    EnvironmentDocument.fromJson(document.toJson());
