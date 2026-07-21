import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

enum EnvironmentEditorMode {
  paint,
  fillGround,
  surfacePolygon,
  place,
  path,
  select,
  collision,
  erase,
  resetGround,
  clearGroundFill,
  editGround,
  connector,
  spawn,
}

enum GeometryRole { footprint, blocking, walkable, selection }

enum GeometryShapeType { circle, ellipse, rectangle, capsule, polygon }

enum EnvironmentGeometryHandleType {
  center,
  radius,
  radiusX,
  radiusY,
  rectangleCorner,
  rotation,
  capsuleStart,
  capsuleEnd,
  capsuleRadius,
  polygonVertex,
}

class EnvironmentGeometryHandle {
  const EnvironmentGeometryHandle(this.type, {this.index = 0});

  final EnvironmentGeometryHandleType type;
  final int index;
}

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
  bool get isTerrainAreaMode =>
      _mode == EnvironmentEditorMode.fillGround ||
      _mode == EnvironmentEditorMode.resetGround ||
      _mode == EnvironmentEditorMode.clearGroundFill;
  bool get isTerrainRegionSelectionMode =>
      _mode == EnvironmentEditorMode.editGround;

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
  int _nextTerrainRegionId = 1;
  double _newFillTextureScale = 1;
  double _newFillOpacity = 1;
  double _newFillEdgeBlend = 0;
  double _newSurfaceElevation = 0;
  double get newSurfaceElevation => _newSurfaceElevation;
  double _newWaterDepth = TerrainStroke.defaultWaterDepth;
  double get newWaterDepth => _newWaterDepth;
  String? _selectedTerrainRegionId;
  String? _selectedSurfaceId;
  String? _selectedLiquidVolumeId;
  TerrainRegion? _terrainRegionScaleBefore;
  EnvironmentDocument? _environmentAreaBefore;
  TerrainRegion? _terrainRegionPointBefore;
  bool _terrainRegionPointChanged = false;
  EnvironmentDocument? _environmentAreaPointBefore;
  bool _environmentAreaPointChanged = false;
  final List<WorldPoint> _surfacePolygonDraft = [];
  String? _connectorTargetSurfaceId;
  WorldPoint? _connectorStart;
  EnvironmentSurfaceConnectorKind _connectorKind =
      EnvironmentSurfaceConnectorKind.stairs;
  double _connectorWidth = 1;
  bool _connectorBidirectional = true;

  String? get selectedTerrainRegionId => _selectedTerrainRegionId;

  TerrainRegion? get selectedTerrainRegion {
    final id = _selectedTerrainRegionId;
    if (id == null) return null;
    return _document.terrainRegions.cast<TerrainRegion?>().firstWhere(
      (region) => region?.id == id,
      orElse: () => null,
    );
  }

  EnvironmentSurface get activeSurface =>
      _document.surfaceById(_document.activeSurfaceId)!;

  EnvironmentSurface? get selectedSurface {
    final id = _selectedSurfaceId;
    return id == null ? null : _document.surfaceById(id);
  }

  EnvironmentLiquidVolume? get selectedLiquidVolume {
    final id = _selectedLiquidVolumeId;
    if (id == null) return null;
    for (final liquid in _document.liquidVolumes) {
      if (liquid.id == id) return liquid;
    }
    return null;
  }

  bool get hasSelectedEnvironmentArea =>
      selectedTerrainRegion != null ||
      selectedSurface != null ||
      selectedLiquidVolume != null;

  List<WorldPoint>? get selectedEnvironmentAreaPoints =>
      selectedLiquidVolume?.points ??
      selectedTerrainRegion?.points ??
      selectedSurface?.points;

  double selectedEnvironmentAreaElevationAt(WorldPoint point) {
    final liquid = selectedLiquidVolume;
    if (liquid != null) return liquid.surfaceElevation;
    final surface = selectedSurface;
    if (surface != null) return surface.elevationAt(point);
    final region = selectedTerrainRegion;
    return region == null
        ? 0
        : _document.surfaceById(region.surfaceId)?.elevationAt(point) ?? 0;
  }

  double get activeFillTextureScale =>
      selectedLiquidVolume?.textureScale ??
      selectedTerrainRegion?.textureScale ??
      _newFillTextureScale;
  double get activeFillOpacity =>
      selectedLiquidVolume?.opacity ??
      selectedTerrainRegion?.opacity ??
      _newFillOpacity;
  double get activeFillEdgeBlend =>
      selectedLiquidVolume?.edgeBlend ??
      selectedTerrainRegion?.edgeBlend ??
      _newFillEdgeBlend;
  List<WorldPoint> get surfacePolygonDraft =>
      List.unmodifiable(_surfacePolygonDraft);
  bool get hasSurfacePolygonDraft => _surfacePolygonDraft.isNotEmpty;
  WorldPoint? get connectorStart => _connectorStart;
  EnvironmentSurfaceConnectorKind get connectorKind => _connectorKind;
  double get connectorWidth => _connectorWidth;
  bool get connectorBidirectional => _connectorBidirectional;
  EnvironmentSurface? get connectorTargetSurface {
    final selected = _connectorTargetSurfaceId;
    if (selected != null && selected != _document.activeSurfaceId) {
      final surface = _document.surfaceById(selected);
      if (surface != null) return surface;
    }
    for (final surface in _document.surfaces) {
      if (surface.id != _document.activeSurfaceId) return surface;
    }
    return null;
  }

  bool get selectedMaterialIsWater =>
      catalog.materialById(_selectedMaterialId)?.tags.contains('water') ??
      false;

  bool get selectedTerrainRegionIsWater {
    return selectedLiquidVolume != null;
  }

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
    return asset == null
        ? null
        : catalog.geometryForAsset(asset, direction: object.direction.name);
  }

  bool get selectedGeometryHasViewOverride {
    final object = selectedObject;
    if (object == null) return false;
    return catalog.geometryOverrides[object.assetId]?.hasDirection(
          object.direction.name,
        ) ??
        false;
  }

  EnvironmentGeometryShape? get selectedGeometryShape {
    final geometry = selectedAssetGeometry;
    if (geometry == null) return null;
    switch (_geometryRole) {
      case GeometryRole.footprint:
        return _geometryShapeIndex < geometry.footprints.length
            ? geometry.footprints[_geometryShapeIndex]
            : null;
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
  String? _geometryGestureAssetId;
  EnvironmentAssetGeometry? _geometryGestureBefore;
  bool _geometryGestureChanged = false;
  TerrainStroke? _activeStroke;
  int _terrainRevision = 0;
  TerrainStroke? _lastTerrainChangedStroke;
  bool _gestureChanged = false;
  bool _placedThisGesture = false;
  final String _objectIdNamespace = _nextObjectIdNamespace();
  int _nextObjectId = 0;
  String? _lastPasteSource;
  int _pasteSerial = 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get terrainRevision => _terrainRevision;
  TerrainStroke? get lastTerrainChangedStroke => _lastTerrainChangedStroke;
  TerrainStroke? get activeTerrainStroke => _activeStroke;

  void selectPaintMaterial(EnvironmentMaterial material) {
    if (_mode != EnvironmentEditorMode.fillGround &&
        _mode != EnvironmentEditorMode.surfacePolygon) {
      _mode = EnvironmentEditorMode.paint;
    }
    _selectedMaterialId = material.id;
    _selectedTerrainRegionId = null;
    _selectedSurfaceId = null;
    _selectedLiquidVolumeId = null;
    _brushRadius = material.defaultRadius;
    _newFillTextureScale = 1;
    _newFillOpacity = material.tags.contains('water') ? 0.88 : 1;
    _newFillEdgeBlend = material.tags.contains('water') ? 0.35 : 0;
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
    if (_mode == EnvironmentEditorMode.surfacePolygon &&
        mode != EnvironmentEditorMode.surfacePolygon) {
      _surfacePolygonDraft.clear();
    }
    if (_mode == EnvironmentEditorMode.connector &&
        mode != EnvironmentEditorMode.connector) {
      _connectorStart = null;
    }
    _mode = mode;
    if (mode == EnvironmentEditorMode.path) {
      final asset = catalog.objectById(_selectedObjectAssetId);
      if (asset != null) _pathPieceLength = _suggestedPathPieceLength(asset);
    }
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setConnectorTargetSurface(String surfaceId) {
    if (surfaceId == _document.activeSurfaceId ||
        _document.surfaceById(surfaceId) == null ||
        _connectorTargetSurfaceId == surfaceId) {
      return;
    }
    _connectorTargetSurfaceId = surfaceId;
    _connectorStart = null;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setConnectorKind(EnvironmentSurfaceConnectorKind kind) {
    if (_connectorKind == kind) return;
    _connectorKind = kind;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setConnectorWidth(double value) {
    final width = value.clamp(0.25, 8).toDouble();
    if (_connectorWidth == width) return;
    _connectorWidth = width;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setConnectorBidirectional(bool value) {
    if (_connectorBidirectional == value) return;
    _connectorBidirectional = value;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void cancelConnectorDraft() {
    if (_connectorStart == null) return;
    _connectorStart = null;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void deleteSurfaceConnector(String id) {
    final index = _document.surfaceConnectors.indexWhere(
      (connector) => connector.id == id,
    );
    if (index < 0) return;
    final before = _copyDocument(_document);
    _document.surfaceConnectors.removeAt(index);
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
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
          supportSurfaceId: _document.activeSurfaceId,
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
          final shapes = [...geometry.footprints];
          if (_geometryShapeIndex >= shapes.length) return geometry;
          shapes[_geometryShapeIndex] = shape;
          return geometry.copyWith(footprints: shapes, reviewed: false);
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
          final shapes = [...geometry.footprints, shape];
          _geometryShapeIndex = shapes.length - 1;
          return geometry.copyWith(footprints: shapes, reviewed: false);
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
          final shapes = [...geometry.footprints]
            ..removeAt(_geometryShapeIndex);
          _geometryShapeIndex = math.max(0, _geometryShapeIndex - 1);
          return geometry.copyWith(footprints: shapes, reviewed: false);
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

  void addFootprintToBlocking() {
    _mutateSelectedGeometry((geometry) {
      if (geometry.footprints.isEmpty) return geometry;
      _geometryRole = GeometryRole.blocking;
      final shapes = [...geometry.blocking, ...geometry.footprints];
      _geometryShapeIndex = shapes.length - 1;
      return geometry.copyWith(blocking: shapes, reviewed: false);
    });
  }

  void replaceBlockingWithFootprint() {
    _mutateSelectedGeometry((geometry) {
      if (geometry.footprints.isEmpty) return geometry;
      _geometryRole = GeometryRole.blocking;
      _geometryShapeIndex = 0;
      return geometry.copyWith(
        blocking: [...geometry.footprints],
        reviewed: false,
      );
    });
  }

  void copySelectedBlockingToFootprint() {
    if (_geometryRole != GeometryRole.blocking) return;
    final shape = selectedGeometryShape;
    if (shape == null) return;
    _mutateSelectedGeometry((geometry) {
      _geometryRole = GeometryRole.footprint;
      final shapes = [...geometry.footprints, shape];
      _geometryShapeIndex = shapes.length - 1;
      return geometry.copyWith(footprints: shapes, reviewed: false);
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

  void resetSelectedGeometryViewOverride() {
    final object = selectedObject;
    if (object == null || !selectedGeometryHasViewOverride) return;
    _recordGeometryMutation(
      object.assetId,
      () => catalog.removeGeometryOverrideForDirection(
        object.assetId,
        object.direction.name,
      ),
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
    _selectedTerrainRegionId = null;
    _selectedSurfaceId = null;
    _selectedLiquidVolumeId = null;
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
    if (ids.isNotEmpty) {
      _selectedTerrainRegionId = null;
      _selectedSurfaceId = null;
      _selectedLiquidVolumeId = null;
    }
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
    if (_selectedObjectIds.isEmpty && !hasSelectedEnvironmentArea) return;
    _selectedObjectIds.clear();
    _primarySelectedObjectId = null;
    _selectedTerrainRegionId = null;
    _selectedSurfaceId = null;
    _selectedLiquidVolumeId = null;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void beginGesture() {
    _gestureObjectBefore.clear();
    _gestureObjectIds.clear();
    _gestureChanged = false;
    _placedThisGesture = false;
    _activeStroke = null;
    _activePathDragHandle = null;
    _pathGestureStarted = false;
    _geometryGestureAssetId = null;
    _geometryGestureBefore = null;
    _geometryGestureChanged = false;
  }

  bool beginSelectedPolygonVertexGesture() {
    if (_mode != EnvironmentEditorMode.collision ||
        selectedGeometryShape is! EnvironmentPolygon) {
      return false;
    }
    final object = selectedObject;
    if (object == null) return false;
    _geometryGestureAssetId = object.assetId;
    _geometryGestureBefore = catalog.geometryOverrides[object.assetId];
    return true;
  }

  bool beginSelectedGeometryHandleGesture(EnvironmentGeometryHandle handle) {
    if (_mode != EnvironmentEditorMode.collision ||
        !_geometryHandleSupportsShape(handle, selectedGeometryShape)) {
      return false;
    }
    final object = selectedObject;
    if (object == null) return false;
    _geometryGestureAssetId = object.assetId;
    _geometryGestureBefore = catalog.geometryOverrides[object.assetId];
    return true;
  }

  void moveSelectedPolygonVertexDuringGesture(
    int vertexIndex,
    WorldPoint worldPoint,
  ) => moveSelectedGeometryHandleDuringGesture(
    EnvironmentGeometryHandle(
      EnvironmentGeometryHandleType.polygonVertex,
      index: vertexIndex,
    ),
    worldPoint,
  );

  void moveSelectedGeometryHandleDuringGesture(
    EnvironmentGeometryHandle handle,
    WorldPoint worldPoint,
  ) {
    final object = selectedObject;
    final assetId = _geometryGestureAssetId;
    final shape = selectedGeometryShape;
    if (object == null ||
        assetId == null ||
        object.assetId != assetId ||
        !_geometryHandleSupportsShape(handle, shape)) {
      return;
    }
    final local = inverseTransformEnvironmentGeometryPoint(worldPoint, object);
    final updatedShape = _moveGeometryHandle(shape!, handle, local);
    final asset = catalog.objectById(assetId);
    if (asset == null) return;
    final geometry = catalog.geometryForAsset(
      asset,
      direction: object.direction.name,
    );
    final updated = _replaceSelectedGeometryShapeWithoutHistory(
      geometry,
      updatedShape,
    );
    _setGeometryForObjectView(asset, object, updated);
    _geometryGestureChanged = true;
    _hoverNotifier.changed();
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
      case EnvironmentEditorMode.surfacePolygon:
        if (!_placedThisGesture) {
          _surfacePolygonDraft.add(point);
          _placedThisGesture = true;
          notifyListeners();
          _paletteNotifier.notifyListeners();
        }
      case EnvironmentEditorMode.fillGround:
      case EnvironmentEditorMode.resetGround:
      case EnvironmentEditorMode.clearGroundFill:
        break;
      case EnvironmentEditorMode.editGround:
        selectTerrainRegionAt(point);
      case EnvironmentEditorMode.connector:
        if (!_placedThisGesture) {
          _placeConnectorPoint(point);
          _placedThisGesture = true;
        }
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
    if (_geometryGestureChanged && _geometryGestureAssetId != null) {
      _pushCommand(
        _GeometryDeltaCommand(
          assetId: _geometryGestureAssetId!,
          before: _geometryGestureBefore,
          after: catalog.geometryOverrides[_geometryGestureAssetId!],
        ),
      );
    }
    if (_terrainRegionPointChanged && _terrainRegionPointBefore != null) {
      final after = selectedTerrainRegion;
      if (after != null && after.id == _terrainRegionPointBefore!.id) {
        _pushCommand(
          _TerrainRegionReplaceCommand(
            before: _terrainRegionPointBefore!,
            after: _copyTerrainRegion(after),
          ),
        );
      }
    }
    if (_environmentAreaPointChanged && _environmentAreaPointBefore != null) {
      _pushCommand(
        _ReplaceDocumentCommand(
          before: _environmentAreaPointBefore!,
          after: _copyDocument(_document),
        ),
      );
    }
    _gestureObjectBefore.clear();
    _gestureObjectIds.clear();
    _activeStroke = null;
    _activePathDragHandle = null;
    _pathGestureStarted = false;
    _geometryGestureAssetId = null;
    _geometryGestureBefore = null;
    _geometryGestureChanged = false;
    _terrainRegionPointBefore = null;
    _terrainRegionPointChanged = false;
    _environmentAreaPointBefore = null;
    _environmentAreaPointChanged = false;
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

  bool nudgeSelection(double dx, double dy) {
    final selected = selectedObjects;
    if (selected.isEmpty ||
        selected.any(
          (object) => !_document.contains(object.x + dx, object.y + dy),
        )) {
      return false;
    }
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        object
          ..x += dx
          ..y += dy;
      }
    });
    return true;
  }

  String? copySelectionToJson() {
    final selected = _selectedObjectIds;
    if (selected.isEmpty) return null;
    final source = jsonEncode({
      'format': 'neura/environment-objects',
      'version': 1,
      'objects': [
        for (final object in _document.objects)
          if (selected.contains(object.id)) object.toJson(),
      ],
    });
    _lastPasteSource = source;
    _pasteSerial = 0;
    return source;
  }

  bool pasteSelectionFromJson(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return false;
    }
    if (decoded is! Map<String, Object?> ||
        decoded['format'] != 'neura/environment-objects' ||
        decoded['version'] != 1 ||
        decoded['objects'] is! List<Object?>) {
      return false;
    }
    final templates = <PlacedEnvironmentObject>[];
    try {
      for (final value in decoded['objects']! as List<Object?>) {
        final object = PlacedEnvironmentObject.fromJson(
          value! as Map<String, Object?>,
        );
        if (catalog.objectById(object.assetId) != null) templates.add(object);
      }
    } on Object {
      return false;
    }
    if (templates.isEmpty) return false;

    if (_lastPasteSource == source) {
      _pasteSerial++;
    } else {
      _lastPasteSource = source;
      _pasteSerial = 1;
    }
    var dx = 0.5 * _pasteSerial;
    var dy = 0.5 * _pasteSerial;
    final minX = templates.map((object) => object.x).reduce(math.min);
    final minY = templates.map((object) => object.y).reduce(math.min);
    final maxX = templates.map((object) => object.x).reduce(math.max);
    final maxY = templates.map((object) => object.y).reduce(math.max);
    dx = dx.clamp(-minX, _document.width - maxX).toDouble();
    dy = dy.clamp(-minY, _document.height - maxY).toDouble();

    final pasted = <PlacedEnvironmentObject>[];
    for (final template in templates) {
      final originalLayer = _layersById[template.editorLayerId];
      final layerId =
          originalLayer != null &&
              isLayerVisible(originalLayer.id) &&
              !isLayerLocked(originalLayer.id)
          ? originalLayer.id
          : _document.activeLayerId;
      pasted.add(
        PlacedEnvironmentObject(
          id: _newPlacedObjectId(),
          assetId: template.assetId,
          x: template.x + dx,
          y: template.y + dy,
          verticalOffset: template.verticalOffset,
          sortBias: template.sortBias,
          editorLayerId: layerId,
          direction: template.direction,
          behaviorProfileId: template.behaviorProfileId,
          liquidInteraction: template.liquidInteraction,
          liquidDraft: template.liquidDraft,
          supportSurfaceId:
              _document.surfaceById(template.supportSurfaceId) != null
              ? template.supportSurfaceId
              : _document.activeSurfaceId,
          crossSurfaceOcclusion: template.crossSurfaceOcclusion,
          occlusionHeight: template.occlusionHeight,
        ),
      );
    }
    final ids = pasted.map((object) => object.id).toSet();
    _recordObjectMutation(ids, () {
      _document.objects.addAll(pasted);
      _selectedObjectIds
        ..clear()
        ..addAll(ids);
      _primarySelectedObjectId = pasted.last.id;
      _mode = EnvironmentEditorMode.select;
    });
    _paletteNotifier.notifyListeners();
    return true;
  }

  bool resetGroundInArea(List<WorldPoint> polygon) {
    if (polygon.length < 3) return false;
    final stroke = TerrainStroke(
      materialId: activeSurface.materialId,
      radius: 0,
      opacity: 1,
      resetsToBase: true,
      seed: _nextTerrainStrokeSeed(),
      surfaceId: _document.activeSurfaceId,
      points: [for (final point in polygon) point],
    );
    final index = _document.terrainStrokes.length;
    _document.terrainStrokes.add(stroke);
    _pushCommand(
      _TerrainStrokeCommand(index: index, stroke: _copyTerrainStroke(stroke)),
    );
    _markTerrainChanged(stroke);
    notifyListeners();
    return true;
  }

  bool fillGroundInArea(List<WorldPoint> polygon) => selectedMaterialIsWater
      ? _addLiquidVolume(polygon)
      : _addTerrainRegion(polygon, resetsToDefault: false);

  bool finishSurfacePolygon() {
    if (_surfacePolygonDraft.length < 3) return false;
    final points = [for (final point in _surfacePolygonDraft) point];
    _surfacePolygonDraft.clear();
    return selectedMaterialIsWater
        ? _addLiquidVolume(points)
        : _addPhysicalSurface(points);
  }

  void cancelSurfacePolygon() {
    if (_surfacePolygonDraft.isEmpty) return;
    _surfacePolygonDraft.clear();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  bool clearGroundFillInArea(List<WorldPoint> polygon) =>
      _addTerrainRegion(polygon, resetsToDefault: true);

  bool _addTerrainRegion(
    List<WorldPoint> polygon, {
    required bool resetsToDefault,
  }) {
    if (polygon.length < 3) return false;
    final region = TerrainRegion(
      id: 'region_${_objectIdNamespace}_${_nextTerrainRegionId++}',
      materialId: _selectedMaterialId,
      resetsToDefault: resetsToDefault,
      points: [for (final point in polygon) point],
      textureScale: resetsToDefault ? 1 : _newFillTextureScale,
      opacity: resetsToDefault ? 1 : _newFillOpacity,
      edgeBlend: resetsToDefault ? 0 : _newFillEdgeBlend,
      surfaceId: _document.activeSurfaceId,
      seed: _nextTerrainStrokeSeed(),
      order: _document.terrainRegions.length,
    );
    final index = _document.terrainRegions.length;
    _document.terrainRegions.add(region);
    _selectedTerrainRegionId = region.id;
    _selectedSurfaceId = null;
    _selectedLiquidVolumeId = null;
    _selectedObjectIds.clear();
    _primarySelectedObjectId = null;
    _pushCommand(
      _TerrainRegionCommand(index: index, region: _copyTerrainRegion(region)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
    return true;
  }

  bool _addPhysicalSurface(List<WorldPoint> polygon) {
    if (polygon.length < 3) return false;
    final before = _copyDocument(_document);
    final id = 'surface_${_objectIdNamespace}_${_nextTerrainRegionId++}';
    final surface = EnvironmentSurface(
      id: id,
      name: 'Surface ${_document.surfaces.length}',
      materialId: _selectedMaterialId,
      points: [for (final point in polygon) point],
      kind: EnvironmentSurfaceKind.platform,
      height: EnvironmentSurfaceHeight.flat(_newSurfaceElevation),
      order: _document.surfaces.length,
    );
    _document.surfaces.add(surface);
    _document.activeSurfaceId = surface.id;
    _selectedSurfaceId = surface.id;
    _selectedTerrainRegionId = null;
    _selectedLiquidVolumeId = null;
    _selectedObjectIds.clear();
    _primarySelectedObjectId = null;
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
    return true;
  }

  bool _addLiquidVolume(List<WorldPoint> polygon) {
    if (polygon.length < 3) return false;
    final before = _copyDocument(_document);
    final liquid = EnvironmentLiquidVolume(
      id: 'liquid_${_objectIdNamespace}_${_nextTerrainRegionId++}',
      name: 'Liquid ${_document.liquidVolumes.length + 1}',
      bedSurfaceId: _document.activeSurfaceId,
      materialId: _selectedMaterialId,
      points: [for (final point in polygon) point],
      surfaceElevation: _newSurfaceElevation,
      depth: _newWaterDepth,
      textureScale: _newFillTextureScale,
      opacity: _newFillOpacity,
      edgeBlend: _newFillEdgeBlend,
      order: _document.liquidVolumes.length,
    );
    _document.liquidVolumes.add(liquid);
    _selectedLiquidVolumeId = liquid.id;
    _selectedTerrainRegionId = null;
    _selectedSurfaceId = null;
    _selectedObjectIds.clear();
    _primarySelectedObjectId = null;
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
    return true;
  }

  bool selectTerrainRegionAt(WorldPoint point) {
    EnvironmentLiquidVolume? selectedLiquid;
    for (final liquid in _document.liquidVolumes.reversed) {
      if (_pointInPolygon(point, liquid.points)) {
        selectedLiquid = liquid;
        break;
      }
    }
    TerrainRegion? selected;
    for (final region in _document.terrainRegions.reversed.where(
      (region) => region.surfaceId == _document.activeSurfaceId,
    )) {
      if (_pointInPolygon(point, region.points)) {
        selected = region;
        break;
      }
    }
    EnvironmentSurface? selectedSurface;
    for (final surface in _document.surfaces.reversed) {
      if (surface.id == environmentBaseSurfaceId) continue;
      if (_pointInPolygon(point, surface.points)) {
        selectedSurface = surface;
        break;
      }
    }
    if (selectedLiquid != null) {
      selected = null;
      selectedSurface = null;
    } else if (selected != null) {
      selectedSurface = null;
    }
    final nextId = selected?.id;
    final nextSurfaceId = selectedSurface?.id;
    final nextLiquidId = selectedLiquid?.id;
    if (_selectedTerrainRegionId == nextId &&
        _selectedSurfaceId == nextSurfaceId &&
        _selectedLiquidVolumeId == nextLiquidId &&
        _selectedObjectIds.isEmpty) {
      return selected != null ||
          selectedSurface != null ||
          selectedLiquid != null;
    }
    _selectedTerrainRegionId = nextId;
    _selectedSurfaceId = nextSurfaceId;
    _selectedLiquidVolumeId = nextLiquidId;
    _selectedObjectIds.clear();
    _primarySelectedObjectId = null;
    notifyListeners();
    _paletteNotifier.notifyListeners();
    return selected != null ||
        selectedSurface != null ||
        selectedLiquid != null;
  }

  void beginTerrainTextureScaleEdit() {
    _environmentAreaBefore = _copyDocument(_document);
    final region = selectedTerrainRegion;
    _terrainRegionScaleBefore = region == null
        ? null
        : _copyTerrainRegion(region);
  }

  void setActiveFillTextureScale(double value) {
    final scale = value.clamp(0.25, 4).toDouble();
    final liquid = selectedLiquidVolume;
    if (liquid != null) {
      if (liquid.textureScale == scale) return;
      final index = _document.liquidVolumes.indexOf(liquid);
      _document.liquidVolumes[index] = liquid.copyWith(textureScale: scale);
      _markTerrainChanged();
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    final region = selectedTerrainRegion;
    if (region == null || region.resetsToDefault) {
      if (_newFillTextureScale == scale) return;
      _newFillTextureScale = scale;
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    if (region.textureScale == scale) return;
    _newFillTextureScale = scale;
    final index = _document.terrainRegions.indexOf(region);
    _document.terrainRegions[index] = region.copyWith(textureScale: scale);
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void endTerrainTextureScaleEdit() {
    final documentBefore = _environmentAreaBefore;
    _environmentAreaBefore = null;
    final before = _terrainRegionScaleBefore;
    _terrainRegionScaleBefore = null;
    final after = selectedTerrainRegion;
    if (before == null ||
        after == null ||
        before.id != after.id ||
        before.toJson().toString() == after.toJson().toString()) {
      if (documentBefore != null &&
          documentBefore.toJsonString(pretty: false) !=
              _document.toJsonString(pretty: false)) {
        _pushCommand(
          _ReplaceDocumentCommand(
            before: documentBefore,
            after: _copyDocument(_document),
          ),
        );
      }
      return;
    }
    _pushCommand(
      _TerrainRegionReplaceCommand(
        before: before,
        after: _copyTerrainRegion(after),
      ),
    );
  }

  void resetActiveFillTextureScale() {
    beginTerrainTextureScaleEdit();
    setActiveFillTextureScale(1);
    endTerrainTextureScaleEdit();
  }

  void setActiveFillOpacity(double value) {
    final opacity = value.clamp(0.05, 1).toDouble();
    final liquid = selectedLiquidVolume;
    if (liquid != null) {
      if (liquid.opacity == opacity) return;
      final index = _document.liquidVolumes.indexOf(liquid);
      _document.liquidVolumes[index] = liquid.copyWith(opacity: opacity);
      _markTerrainChanged();
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    final region = selectedTerrainRegion;
    if (region == null || region.resetsToDefault) {
      if (_newFillOpacity == opacity) return;
      _newFillOpacity = opacity;
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    if (region.opacity == opacity) return;
    final index = _document.terrainRegions.indexOf(region);
    _document.terrainRegions[index] = region.copyWith(opacity: opacity);
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setActiveFillEdgeBlend(double value) {
    final edgeBlend = value.clamp(0, 3).toDouble();
    final liquid = selectedLiquidVolume;
    if (liquid != null) {
      if (liquid.edgeBlend == edgeBlend) return;
      final index = _document.liquidVolumes.indexOf(liquid);
      _document.liquidVolumes[index] = liquid.copyWith(edgeBlend: edgeBlend);
      _markTerrainChanged();
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    final region = selectedTerrainRegion;
    if (region == null || region.resetsToDefault) {
      if (_newFillEdgeBlend == edgeBlend) return;
      _newFillEdgeBlend = edgeBlend;
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    if (region.edgeBlend == edgeBlend) return;
    final index = _document.terrainRegions.indexOf(region);
    _document.terrainRegions[index] = region.copyWith(edgeBlend: edgeBlend);
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void adjustSelectedFillOpacity(double delta) {
    final liquid = selectedLiquidVolume;
    if (liquid != null) {
      final before = _copyDocument(_document);
      final index = _document.liquidVolumes.indexOf(liquid);
      _document.liquidVolumes[index] = liquid.copyWith(
        opacity: (liquid.opacity + delta).clamp(0.05, 1).toDouble(),
      );
      _pushCommand(
        _ReplaceDocumentCommand(
          before: before,
          after: _copyDocument(_document),
        ),
      );
      _markTerrainChanged();
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    final region = selectedTerrainRegion;
    if (region == null || region.resetsToDefault) return;
    _replaceTerrainRegionWithHistory(
      region,
      region.copyWith(
        opacity: (region.opacity + delta).clamp(0.05, 1).toDouble(),
      ),
    );
  }

  void adjustSelectedFillEdgeBlend(double delta) {
    final liquid = selectedLiquidVolume;
    if (liquid != null) {
      final before = _copyDocument(_document);
      final index = _document.liquidVolumes.indexOf(liquid);
      _document.liquidVolumes[index] = liquid.copyWith(
        edgeBlend: (liquid.edgeBlend + delta).clamp(0, 3).toDouble(),
      );
      _pushCommand(
        _ReplaceDocumentCommand(
          before: before,
          after: _copyDocument(_document),
        ),
      );
      _markTerrainChanged();
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    final region = selectedTerrainRegion;
    if (region == null || region.resetsToDefault) return;
    _replaceTerrainRegionWithHistory(
      region,
      region.copyWith(
        edgeBlend: (region.edgeBlend + delta).clamp(0, 3).toDouble(),
      ),
    );
  }

  bool beginSelectedTerrainPointGesture(int pointIndex) {
    final points = selectedEnvironmentAreaPoints;
    if (_mode != EnvironmentEditorMode.editGround ||
        points == null ||
        pointIndex < 0 ||
        pointIndex >= points.length) {
      return false;
    }
    if (selectedTerrainRegion case final region?) {
      _terrainRegionPointBefore = _copyTerrainRegion(region);
      _terrainRegionPointChanged = false;
    } else {
      _environmentAreaPointBefore = _copyDocument(_document);
      _environmentAreaPointChanged = false;
    }
    return true;
  }

  void moveSelectedTerrainPointDuringGesture(int pointIndex, WorldPoint point) {
    final region = selectedTerrainRegion;
    final surface = selectedSurface;
    final liquid = selectedLiquidVolume;
    final pointsSource = selectedEnvironmentAreaPoints;
    if ((_terrainRegionPointBefore == null &&
            _environmentAreaPointBefore == null) ||
        pointsSource == null ||
        pointIndex < 0 ||
        pointIndex >= pointsSource.length ||
        !_document.contains(point.x, point.y)) {
      return;
    }
    final points = [for (final value in pointsSource) value];
    points[pointIndex] = point;
    if (region != null) {
      final index = _document.terrainRegions.indexOf(region);
      _document.terrainRegions[index] = region.copyWith(points: points);
      _terrainRegionPointChanged = true;
    } else if (surface != null) {
      final index = _document.surfaces.indexOf(surface);
      _document.surfaces[index] = surface.copyWith(points: points);
      _environmentAreaPointChanged = true;
    } else if (liquid != null) {
      final index = _document.liquidVolumes.indexOf(liquid);
      _document.liquidVolumes[index] = liquid.copyWith(points: points);
      _environmentAreaPointChanged = true;
    }
    _markTerrainChanged();
    notifyListeners();
  }

  void setNewSurfaceElevation(double value) {
    final elevation = value.clamp(-8, 8).toDouble();
    if (_newSurfaceElevation == elevation) return;
    _newSurfaceElevation = elevation;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setNewWaterDepth(double value) {
    final depth = value.clamp(0.05, 8).toDouble();
    if (_newWaterDepth == depth) return;
    _newWaterDepth = depth;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void adjustSelectedTerrainElevation(double delta) {
    final surface = selectedSurface;
    final liquid = selectedLiquidVolume;
    if (surface == null && liquid == null) return;
    final before = _copyDocument(_document);
    if (surface != null) {
      final current = surface.height.elevation;
      final index = _document.surfaces.indexOf(surface);
      _document.surfaces[index] = surface.copyWith(
        height: EnvironmentSurfaceHeight.flat(
          (current + delta).clamp(-8, 8).toDouble(),
        ),
      );
    } else {
      final index = _document.liquidVolumes.indexOf(liquid!);
      _document.liquidVolumes[index] = liquid.copyWith(
        surfaceElevation: (liquid.surfaceElevation + delta)
            .clamp(-8, 8)
            .toDouble(),
      );
    }
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void adjustSelectedWaterDepth(double delta) {
    final liquid = selectedLiquidVolume;
    if (liquid == null) return;
    final before = _copyDocument(_document);
    final index = _document.liquidVolumes.indexOf(liquid);
    _document.liquidVolumes[index] = liquid.copyWith(
      depth: (liquid.depth + delta).clamp(0.05, 8).toDouble(),
    );
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setSelectedVariableWaterDepth(bool enabled) {
    final liquid = selectedLiquidVolume;
    if (liquid == null || liquid.hasDepthRamp == enabled) return;
    final before = _copyDocument(_document);
    final index = _document.liquidVolumes.indexOf(liquid);
    if (enabled) {
      final endpoints = _defaultLiquidDepthRamp(liquid.points);
      _document.liquidVolumes[index] = liquid.copyWith(
        endDepth: math.max(0.05, liquid.depth * 0.15),
        depthRampStart: endpoints.$1,
        depthRampEnd: endpoints.$2,
      );
    } else {
      _document.liquidVolumes[index] = liquid.copyWith(clearDepthRamp: true);
    }
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void adjustSelectedWaterEndDepth(double delta) {
    final liquid = selectedLiquidVolume;
    if (liquid == null || !liquid.hasDepthRamp) return;
    final before = _copyDocument(_document);
    final index = _document.liquidVolumes.indexOf(liquid);
    _document.liquidVolumes[index] = liquid.copyWith(
      endDepth: (liquid.endDepth! + delta).clamp(0.05, 8).toDouble(),
    );
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void swapSelectedWaterDepthRamp() {
    final liquid = selectedLiquidVolume;
    if (liquid == null || !liquid.hasDepthRamp) return;
    final before = _copyDocument(_document);
    final index = _document.liquidVolumes.indexOf(liquid);
    _document.liquidVolumes[index] = liquid.copyWith(
      depth: liquid.endDepth,
      endDepth: liquid.depth,
      depthRampStart: liquid.depthRampEnd,
      depthRampEnd: liquid.depthRampStart,
    );
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  bool beginSelectedLiquidDepthHandleGesture(int handleIndex) {
    final liquid = selectedLiquidVolume;
    if (_mode != EnvironmentEditorMode.editGround ||
        liquid == null ||
        !liquid.hasDepthRamp ||
        (handleIndex != 0 && handleIndex != 1)) {
      return false;
    }
    _environmentAreaPointBefore = _copyDocument(_document);
    _environmentAreaPointChanged = false;
    return true;
  }

  void moveSelectedLiquidDepthHandleDuringGesture(
    int handleIndex,
    WorldPoint point,
  ) {
    final liquid = selectedLiquidVolume;
    if (_environmentAreaPointBefore == null ||
        liquid == null ||
        !liquid.hasDepthRamp ||
        !_document.contains(point.x, point.y)) {
      return;
    }
    final index = _document.liquidVolumes.indexOf(liquid);
    _document.liquidVolumes[index] = liquid.copyWith(
      depthRampStart: handleIndex == 0 ? point : liquid.depthRampStart,
      depthRampEnd: handleIndex == 1 ? point : liquid.depthRampEnd,
    );
    _environmentAreaPointChanged = true;
    _markTerrainChanged();
    notifyListeners();
  }

  void adjustSelectedElevationBlend(double delta) {
    // Surface transitions are explicit connectors in schema v6. A visual edge
    // blend must never silently create a traversable slope.
  }

  void moveSelectedTerrainRegionOrder(int delta) {
    final region = selectedTerrainRegion;
    if (region == null || delta == 0) return;
    final current = _document.terrainRegions.indexOf(region);
    final target = (current + delta).clamp(
      0,
      _document.terrainRegions.length - 1,
    );
    if (current == target) return;
    final before = [for (final value in _document.terrainRegions) value.id];
    _document.terrainRegions
      ..removeAt(current)
      ..insert(target, region);
    _normalizeTerrainRegionOrder();
    final after = [for (final value in _document.terrainRegions) value.id];
    _pushCommand(_TerrainRegionOrderCommand(before: before, after: after));
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void _normalizeTerrainRegionOrder() {
    for (var index = 0; index < _document.terrainRegions.length; index++) {
      final region = _document.terrainRegions[index];
      if (region.order != index) {
        _document.terrainRegions[index] = region.copyWith(order: index);
      }
    }
  }

  void _replaceTerrainRegionWithHistory(
    TerrainRegion before,
    TerrainRegion after,
  ) {
    final index = _document.terrainRegions.indexOf(before);
    if (index < 0 || before.toJson().toString() == after.toJson().toString()) {
      return;
    }
    _document.terrainRegions[index] = after;
    _pushCommand(
      _TerrainRegionReplaceCommand(
        before: _copyTerrainRegion(before),
        after: _copyTerrainRegion(after),
      ),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  bool setDefaultGroundMaterial(EnvironmentMaterial material) {
    final surface = activeSurface;
    if (surface.materialId == material.id) return false;
    final before = _copyDocument(_document);
    surface.materialId = material.id;
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
    return true;
  }

  void setSelectedSurfaceGeometryOnly(bool geometryOnly) {
    final surface = selectedSurface;
    if (surface == null || surface.id == environmentBaseSurfaceId) return;
    final drawsBaseMaterial = !geometryOnly;
    if (surface.drawsBaseMaterial == drawsBaseMaterial) return;
    final before = _copyDocument(_document);
    surface.drawsBaseMaterial = drawsBaseMaterial;
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void setActiveSurface(String surfaceId) {
    if (_document.surfaceById(surfaceId) == null ||
        _document.activeSurfaceId == surfaceId) {
      return;
    }
    _document.activeSurfaceId = surfaceId;
    if (_connectorTargetSurfaceId == surfaceId) {
      _connectorTargetSurfaceId = null;
    }
    _connectorStart = null;
    _selectedTerrainRegionId = null;
    _selectedSurfaceId = null;
    _selectedLiquidVolumeId = null;
    notifyListeners();
    _paletteNotifier.notifyListeners();
  }

  void _placeConnectorPoint(WorldPoint point) {
    final target = connectorTargetSurface;
    if (target == null) return;
    final start = _connectorStart;
    if (start == null) {
      _connectorStart = point;
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    final before = _copyDocument(_document);
    _document.surfaceConnectors.add(
      EnvironmentSurfaceConnector(
        id: 'connector_${_objectIdNamespace}_${_nextTerrainRegionId++}',
        fromSurfaceId: _document.activeSurfaceId,
        toSurfaceId: target.id,
        from: start,
        to: point,
        kind: _connectorKind,
        width: _connectorWidth,
        bidirectional: _connectorBidirectional,
      ),
    );
    _connectorStart = null;
    _pushCommand(
      _ReplaceDocumentCommand(before: before, after: _copyDocument(_document)),
    );
    _markTerrainChanged();
    notifyListeners();
    _paletteNotifier.notifyListeners();
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
    _geometryShapeIndex = 0;
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
    _geometryShapeIndex = 0;
  }

  void setSelectedAnimalBehaviorProfile(String profileId) {
    if (catalog.animalBehaviorProfileById(profileId) == null) return;
    final animals = selectedObjects
        .where(
          (object) =>
              catalog.objectById(object.assetId)?.animalAnimation != null,
        )
        .toList();
    if (animals.isEmpty ||
        animals.every((object) {
          final animation = catalog
              .objectById(object.assetId)!
              .animalAnimation!;
          return (object.behaviorProfileId ?? animation.behaviorProfileId) ==
              profileId;
        })) {
      return;
    }
    _recordObjectMutation(animals.map((object) => object.id), () {
      for (final animal in animals) {
        final defaultId = catalog
            .objectById(animal.assetId)!
            .animalAnimation!
            .behaviorProfileId;
        animal.behaviorProfileId = profileId == defaultId ? null : profileId;
      }
    });
  }

  AnimalBehaviorProfile? animalBehaviorProfileFor(
    PlacedEnvironmentObject object,
  ) {
    final animation = catalog.objectById(object.assetId)?.animalAnimation;
    if (animation == null) return null;
    return catalog.animalBehaviorProfileById(
      object.behaviorProfileId ?? animation.behaviorProfileId,
    );
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

  void setSelectedSupportSurface(String surfaceId) {
    if (_document.surfaceById(surfaceId) == null) return;
    final selected = selectedObjects;
    if (selected.isEmpty ||
        selected.every((object) => object.supportSurfaceId == surfaceId)) {
      return;
    }
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        object.supportSurfaceId = surfaceId;
      }
    });
  }

  void setSelectedCrossSurfaceOcclusion(bool enabled) {
    final selected = selectedObjects;
    if (selected.isEmpty ||
        selected.every((object) => object.crossSurfaceOcclusion == enabled)) {
      return;
    }
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        object.crossSurfaceOcclusion = enabled;
        if (enabled && object.occlusionHeight <= 0) {
          object.occlusionHeight = 4;
        }
      }
    });
  }

  void adjustSelectedOcclusionHeight(double delta) {
    final selected = selectedObjects;
    if (selected.isEmpty) return;
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        object.occlusionHeight = (object.occlusionHeight + delta)
            .clamp(0, 32)
            .toDouble();
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

  void setSelectedLiquidInteraction(EnvironmentLiquidInteraction interaction) {
    final selected = selectedObjects;
    if (selected.isEmpty ||
        selected.every((object) => object.liquidInteraction == interaction)) {
      return;
    }
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        object.liquidInteraction = interaction;
      }
    });
  }

  void adjustSelectedLiquidDraft(double delta) {
    final selected = selectedObjects;
    if (selected.isEmpty) return;
    _recordObjectMutation(selected.map((object) => object.id), () {
      for (final object in selected) {
        object.liquidDraft = (object.liquidDraft + delta)
            .clamp(0, 4)
            .toDouble();
      }
    });
  }

  void deleteSelected() {
    final terrainRegion = selectedTerrainRegion;
    final surface = selectedSurface;
    final liquid = selectedLiquidVolume;
    if (_selectedObjectIds.isEmpty && (surface != null || liquid != null)) {
      final before = _copyDocument(_document);
      if (liquid != null) {
        _document.liquidVolumes.remove(liquid);
        _selectedLiquidVolumeId = null;
      } else if (surface != null && surface.id != environmentBaseSurfaceId) {
        if (_document.objects.any(
              (object) => object.supportSurfaceId == surface.id,
            ) ||
            _document.liquidVolumes.any(
              (candidate) => candidate.bedSurfaceId == surface.id,
            ) ||
            _document.surfaceConnectors.any(
              (connector) =>
                  connector.fromSurfaceId == surface.id ||
                  connector.toSurfaceId == surface.id,
            )) {
          return;
        }
        _document.terrainRegions.removeWhere(
          (region) => region.surfaceId == surface.id,
        );
        _document.terrainStrokes.removeWhere(
          (stroke) => stroke.surfaceId == surface.id,
        );
        _document.surfaces.remove(surface);
        _document.activeSurfaceId = environmentBaseSurfaceId;
        _selectedSurfaceId = null;
      }
      _pushCommand(
        _ReplaceDocumentCommand(
          before: before,
          after: _copyDocument(_document),
        ),
      );
      _markTerrainChanged();
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
    if (_selectedObjectIds.isEmpty && terrainRegion != null) {
      final index = _document.terrainRegions.indexOf(terrainRegion);
      _document.terrainRegions.removeAt(index);
      _selectedTerrainRegionId = null;
      _pushCommand(
        _TerrainRegionDeleteCommand(
          index: index,
          region: _copyTerrainRegion(terrainRegion),
        ),
      );
      _markTerrainChanged();
      notifyListeners();
      _paletteNotifier.notifyListeners();
      return;
    }
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
    if (command.affectsTerrain) {
      _markTerrainChanged();
      _paletteNotifier.notifyListeners();
    } else {
      _markSceneChanged(objectIds: command.affectedObjectIds);
    }
    _normalizeSelection();
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    final command = _redo.removeLast();
    command.redo(this);
    _undo.add(command);
    if (command.affectsTerrain) {
      _markTerrainChanged();
      _paletteNotifier.notifyListeners();
    } else {
      _markSceneChanged(objectIds: command.affectedObjectIds);
    }
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
    _selectedTerrainRegionId = null;
    _selectedSurfaceId = null;
    _selectedLiquidVolumeId = null;
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
    // Liquids are persistent polygon volumes. Painting water as unrelated
    // decals would reintroduce the old ambiguous height model.
    if (selectedMaterialIsWater) return;
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
        surfaceId: _document.activeSurfaceId,
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
    _markSceneChanged();
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
      supportSurfaceId: _document.activeSurfaceId,
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
    const projection = IsometricProjection();
    final screenX = (dx - dy) * projection.halfWidth;
    final screenY = (dx + dy) * projection.halfHeight;
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
    final lengths = asset.geometry.footprints.map(
      (footprint) => switch (footprint) {
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
      },
    );
    final length = lengths.isEmpty
        ? 3.2 * asset.renderScale
        : lengths.reduce(math.max);
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
    final updated = mutation(
      catalog.geometryForAsset(asset, direction: object.direction.name),
    );
    _recordGeometryMutation(
      asset.id,
      () => _setGeometryForObjectView(asset, object, updated),
    );
  }

  void _setGeometryForObjectView(
    EnvironmentObjectAsset asset,
    PlacedEnvironmentObject object,
    EnvironmentAssetGeometry geometry,
  ) {
    if (asset.views.length == 1) {
      catalog.setGeometryOverride(asset.id, geometry.withoutDirections());
      return;
    }
    catalog.setGeometryOverrideForDirection(
      asset.id,
      object.direction.name,
      geometry,
    );
  }

  EnvironmentAssetGeometry _replaceSelectedGeometryShapeWithoutHistory(
    EnvironmentAssetGeometry geometry,
    EnvironmentGeometryShape shape,
  ) {
    switch (_geometryRole) {
      case GeometryRole.footprint:
        final shapes = [...geometry.footprints];
        if (_geometryShapeIndex >= shapes.length) return geometry;
        shapes[_geometryShapeIndex] = shape;
        return geometry.copyWith(footprints: shapes, reviewed: false);
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
  }

  void _normalizeSelection() {
    _selectedObjectIds.removeWhere((id) => !_isObjectSelectable(id));
    if (!_selectedObjectIds.contains(_primarySelectedObjectId)) {
      _primarySelectedObjectId = _lastOrNull(_selectedObjectIds);
    }
    if (_selectedTerrainRegionId != null &&
        !_document.terrainRegions.any(
          (region) => region.id == _selectedTerrainRegionId,
        )) {
      _selectedTerrainRegionId = null;
    }
    if (_selectedSurfaceId != null &&
        _document.surfaceById(_selectedSurfaceId!) == null) {
      _selectedSurfaceId = null;
    }
    if (_selectedLiquidVolumeId != null &&
        !_document.liquidVolumes.any(
          (liquid) => liquid.id == _selectedLiquidVolumeId,
        )) {
      _selectedLiquidVolumeId = null;
    }
    if (_document.surfaceById(_document.activeSurfaceId) == null) {
      _document.activeSurfaceId = environmentBaseSurfaceId;
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

bool _geometryHandleSupportsShape(
  EnvironmentGeometryHandle handle,
  EnvironmentGeometryShape? shape,
) => switch ((shape, handle.type)) {
  (EnvironmentCircle(), EnvironmentGeometryHandleType.center) => true,
  (EnvironmentCircle(), EnvironmentGeometryHandleType.radius) => true,
  (EnvironmentEllipse(), EnvironmentGeometryHandleType.center) => true,
  (EnvironmentEllipse(), EnvironmentGeometryHandleType.radiusX) => true,
  (EnvironmentEllipse(), EnvironmentGeometryHandleType.radiusY) => true,
  (EnvironmentRectangle(), EnvironmentGeometryHandleType.center) => true,
  (EnvironmentRectangle(), EnvironmentGeometryHandleType.rectangleCorner) =>
    handle.index >= 0 && handle.index < 4,
  (EnvironmentRectangle(), EnvironmentGeometryHandleType.rotation) => true,
  (EnvironmentCapsule(), EnvironmentGeometryHandleType.center) => true,
  (EnvironmentCapsule(), EnvironmentGeometryHandleType.capsuleStart) => true,
  (EnvironmentCapsule(), EnvironmentGeometryHandleType.capsuleEnd) => true,
  (EnvironmentCapsule(), EnvironmentGeometryHandleType.capsuleRadius) => true,
  (
    EnvironmentPolygon(points: final points),
    EnvironmentGeometryHandleType.polygonVertex,
  ) =>
    handle.index >= 0 && handle.index < points.length,
  _ => false,
};

EnvironmentGeometryShape _moveGeometryHandle(
  EnvironmentGeometryShape shape,
  EnvironmentGeometryHandle handle,
  EnvironmentGeometryPoint point,
) {
  switch (shape) {
    case EnvironmentCircle():
      return switch (handle.type) {
        EnvironmentGeometryHandleType.center => EnvironmentCircle(
          center: point,
          radius: shape.radius,
        ),
        EnvironmentGeometryHandleType.radius => EnvironmentCircle(
          center: shape.center,
          radius: math.max(0.02, _geometryDistance(shape.center, point)),
        ),
        _ => shape,
      };
    case EnvironmentEllipse():
      return switch (handle.type) {
        EnvironmentGeometryHandleType.center => EnvironmentEllipse(
          center: point,
          radius: shape.radius,
        ),
        EnvironmentGeometryHandleType.radiusX => EnvironmentEllipse(
          center: shape.center,
          radius: EnvironmentGeometryPoint(
            math.max(0.02, (point.x - shape.center.x).abs()),
            shape.radius.y,
          ),
        ),
        EnvironmentGeometryHandleType.radiusY => EnvironmentEllipse(
          center: shape.center,
          radius: EnvironmentGeometryPoint(
            shape.radius.x,
            math.max(0.02, (point.y - shape.center.y).abs()),
          ),
        ),
        _ => shape,
      };
    case EnvironmentRectangle():
      if (handle.type == EnvironmentGeometryHandleType.center) {
        return EnvironmentRectangle(
          center: point,
          size: shape.size,
          rotationDegrees: shape.rotationDegrees,
        );
      }
      if (handle.type == EnvironmentGeometryHandleType.rotation) {
        final angle = math.atan2(
          point.y - shape.center.y,
          point.x - shape.center.x,
        );
        return EnvironmentRectangle(
          center: shape.center,
          size: shape.size,
          rotationDegrees: angle * 180 / math.pi + 90,
        );
      }
      if (handle.type == EnvironmentGeometryHandleType.rectangleCorner) {
        final angle = shape.rotationDegrees * math.pi / 180;
        final dx = point.x - shape.center.x;
        final dy = point.y - shape.center.y;
        final localX = dx * math.cos(angle) + dy * math.sin(angle);
        final localY = -dx * math.sin(angle) + dy * math.cos(angle);
        return EnvironmentRectangle(
          center: shape.center,
          size: EnvironmentGeometryPoint(
            math.max(0.02, localX.abs() * 2),
            math.max(0.02, localY.abs() * 2),
          ),
          rotationDegrees: shape.rotationDegrees,
        );
      }
      return shape;
    case EnvironmentCapsule():
      return switch (handle.type) {
        EnvironmentGeometryHandleType.center => () {
          final center = EnvironmentGeometryPoint(
            (shape.start.x + shape.end.x) / 2,
            (shape.start.y + shape.end.y) / 2,
          );
          final dx = point.x - center.x;
          final dy = point.y - center.y;
          return EnvironmentCapsule(
            start: EnvironmentGeometryPoint(
              shape.start.x + dx,
              shape.start.y + dy,
            ),
            end: EnvironmentGeometryPoint(shape.end.x + dx, shape.end.y + dy),
            radius: shape.radius,
          );
        }(),
        EnvironmentGeometryHandleType.capsuleStart => EnvironmentCapsule(
          start: point,
          end: shape.end,
          radius: shape.radius,
        ),
        EnvironmentGeometryHandleType.capsuleEnd => EnvironmentCapsule(
          start: shape.start,
          end: point,
          radius: shape.radius,
        ),
        EnvironmentGeometryHandleType.capsuleRadius => EnvironmentCapsule(
          start: shape.start,
          end: shape.end,
          radius: math.max(
            0.02,
            _distanceFromGeometrySegment(point, shape.start, shape.end),
          ),
        ),
        _ => shape,
      };
    case EnvironmentPolygon():
      if (handle.type != EnvironmentGeometryHandleType.polygonVertex ||
          handle.index < 0 ||
          handle.index >= shape.points.length) {
        return shape;
      }
      final points = [...shape.points];
      points[handle.index] = point;
      return EnvironmentPolygon(points: points);
  }
}

double _geometryDistance(
  EnvironmentGeometryPoint a,
  EnvironmentGeometryPoint b,
) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

double _distanceFromGeometrySegment(
  EnvironmentGeometryPoint point,
  EnvironmentGeometryPoint start,
  EnvironmentGeometryPoint end,
) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final lengthSquared = dx * dx + dy * dy;
  final t = lengthSquared == 0
      ? 0.0
      : (((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
            .clamp(0.0, 1.0);
  return _geometryDistance(
    point,
    EnvironmentGeometryPoint(start.x + dx * t, start.y + dy * t),
  );
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

class _TerrainRegionCommand extends _EditorCommand {
  const _TerrainRegionCommand({required this.index, required this.region});

  final int index;
  final TerrainRegion region;

  @override
  bool get affectsTerrain => true;

  @override
  Set<String> get affectedObjectIds => const {};

  @override
  void undo(EditorController controller) {
    if (index >= 0 && index < controller._document.terrainRegions.length) {
      controller._document.terrainRegions.removeAt(index);
    }
  }

  @override
  void redo(EditorController controller) {
    controller._document.terrainRegions.insert(
      index.clamp(0, controller._document.terrainRegions.length),
      _copyTerrainRegion(region),
    );
  }
}

class _TerrainRegionDeleteCommand extends _EditorCommand {
  const _TerrainRegionDeleteCommand({
    required this.index,
    required this.region,
  });

  final int index;
  final TerrainRegion region;

  @override
  bool get affectsTerrain => true;

  @override
  Set<String> get affectedObjectIds => const {};

  @override
  void undo(EditorController controller) {
    controller._document.terrainRegions.insert(
      index.clamp(0, controller._document.terrainRegions.length),
      _copyTerrainRegion(region),
    );
  }

  @override
  void redo(EditorController controller) {
    controller._document.terrainRegions.removeWhere(
      (candidate) => candidate.id == region.id,
    );
  }
}

class _TerrainRegionOrderCommand extends _EditorCommand {
  const _TerrainRegionOrderCommand({required this.before, required this.after});

  final List<String> before;
  final List<String> after;

  @override
  bool get affectsTerrain => true;

  @override
  Set<String> get affectedObjectIds => const {};

  @override
  void undo(EditorController controller) => _apply(controller, before);

  @override
  void redo(EditorController controller) => _apply(controller, after);

  void _apply(EditorController controller, List<String> ids) {
    final byId = {
      for (final region in controller._document.terrainRegions)
        region.id: region,
    };
    controller._document.terrainRegions
      ..clear()
      ..addAll(ids.map((id) => byId.remove(id)).whereType<TerrainRegion>())
      ..addAll(byId.values);
    controller._normalizeTerrainRegionOrder();
  }
}

class _TerrainRegionReplaceCommand extends _EditorCommand {
  const _TerrainRegionReplaceCommand({
    required this.before,
    required this.after,
  });

  final TerrainRegion before;
  final TerrainRegion after;

  @override
  bool get affectsTerrain => true;

  @override
  Set<String> get affectedObjectIds => const {};

  @override
  void undo(EditorController controller) => _replace(controller, before);

  @override
  void redo(EditorController controller) => _replace(controller, after);

  void _replace(EditorController controller, TerrainRegion region) {
    final index = controller._document.terrainRegions.indexWhere(
      (candidate) => candidate.id == region.id,
    );
    if (index >= 0) {
      controller._document.terrainRegions[index] = _copyTerrainRegion(region);
    }
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

TerrainRegion _copyTerrainRegion(TerrainRegion region) =>
    TerrainRegion.fromJson(region.toJson());

(WorldPoint, WorldPoint) _defaultLiquidDepthRamp(List<WorldPoint> points) {
  if (points.length < 2) {
    return const (WorldPoint(0, 0), WorldPoint(1, 0));
  }
  var start = points.first;
  var end = points[1];
  var maximumDistanceSquared = -1.0;
  for (var first = 0; first < points.length - 1; first++) {
    for (var second = first + 1; second < points.length; second++) {
      final dx = points[second].x - points[first].x;
      final dy = points[second].y - points[first].y;
      final distanceSquared = dx * dx + dy * dy;
      if (distanceSquared > maximumDistanceSquared) {
        maximumDistanceSquared = distanceSquared;
        start = points[first];
        end = points[second];
      }
    }
  }
  const inset = 0.1;
  return (
    WorldPoint(
      start.x + (end.x - start.x) * inset,
      start.y + (end.y - start.y) * inset,
    ),
    WorldPoint(
      start.x + (end.x - start.x) * (1 - inset),
      start.y + (end.y - start.y) * (1 - inset),
    ),
  );
}

bool _pointInPolygon(WorldPoint point, List<WorldPoint> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (
    var current = 0, previous = polygon.length - 1;
    current < polygon.length;
    previous = current++
  ) {
    final a = polygon[current];
    final b = polygon[previous];
    final crosses =
        (a.y > point.y) != (b.y > point.y) &&
        point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
    if (crosses) inside = !inside;
  }
  return inside;
}

EnvironmentDocument _copyDocument(EnvironmentDocument document) =>
    EnvironmentDocument.fromJson(document.toJson());
