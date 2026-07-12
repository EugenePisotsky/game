import 'package:flutter/foundation.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

import 'package:neura_assets/neura_assets.dart';

enum EditorLayer {
  tools,
  elevation,
  terrain,
  tileLayers,
  roads,
  objects,
  animals,
}

enum EditorTool {
  inspect(EditorLayer.tools, 'Inspect cell'),
  raiseElevation(EditorLayer.elevation, 'Raise elevation'),
  lowerElevation(EditorLayer.elevation, 'Lower elevation'),
  grass(EditorLayer.terrain, 'Grass'),
  road(EditorLayer.roads, 'Dirt road'),
  rockySoil(EditorLayer.terrain, 'Rocky soil'),
  darkEarth(EditorLayer.terrain, 'Dark earth'),
  cobblestone(EditorLayer.terrain, 'Cobblestone'),
  woodPlanks(EditorLayer.terrain, 'Wood planks'),
  stonePavers(EditorLayer.terrain, 'Stone pavers'),
  dryGrass(EditorLayer.terrain, 'Dry grass'),
  roundTree(EditorLayer.objects, 'Round tree'),
  wideTree(EditorLayer.objects, 'Wide tree'),
  ruralTreeA1(EditorLayer.objects, 'Rural tree A1'),
  ruralTreeA2(EditorLayer.objects, 'Rural tree A2'),
  ruralTreeA3(EditorLayer.objects, 'Rural tree A3'),
  ruralTreeA4(EditorLayer.objects, 'Rural tree A4'),
  ruralTreeA5(EditorLayer.objects, 'Rural tree A5'),
  ruralTreeA6(EditorLayer.objects, 'Rural tree A6'),
  ruralTreeA7(EditorLayer.objects, 'Rural tree A7'),
  ruralTreeA8(EditorLayer.objects, 'Rural tree A8'),
  ruralTreeA9(EditorLayer.objects, 'Rural tree A9'),
  ruralTreeA10(EditorLayer.objects, 'Rural tree A10'),
  ruralTreeA11(EditorLayer.objects, 'Rural tree A11'),
  ruralTreeA12(EditorLayer.objects, 'Rural stump A12'),
  ruralTreeB1(EditorLayer.objects, 'Autumn tree B1'),
  ruralTreeB2(EditorLayer.objects, 'Autumn tree B2'),
  ruralTreeB3(EditorLayer.objects, 'Autumn tree B3'),
  ruralTreeC1(EditorLayer.objects, 'Red tree C1'),
  ruralTreeC2(EditorLayer.objects, 'Red tree C2'),
  ruralTreeC3(EditorLayer.objects, 'Red tree C3'),
  bush(EditorLayer.objects, 'Bush'),
  lowFlora(EditorLayer.objects, 'Low flora'),
  leafyGroundcover(EditorLayer.objects, 'Leafy groundcover'),
  clayPots(EditorLayer.objects, 'Clay pots'),
  woodenCrate(EditorLayer.objects, 'Wooden crate'),
  stoneWell(EditorLayer.objects, 'Stone well'),
  woodenSign(EditorLayer.objects, 'Wooden sign'),
  fallenLog(EditorLayer.objects, 'Fallen log'),
  firewoodPile(EditorLayer.objects, 'Firewood pile'),
  stonePile(EditorLayer.objects, 'Stone pile'),
  hayBale(EditorLayer.objects, 'Hay bale'),
  closedChest(EditorLayer.objects, 'Closed chest'),
  sheep(EditorLayer.animals, 'Sheep'),
  erase(EditorLayer.objects, 'Erase top item');

  const EditorTool(this.layer, this.label);

  final EditorLayer layer;
  final String label;
}

class EditorController extends ChangeNotifier {
  EditorController(this._document, {required this.groundCatalog});

  final GroundCatalog groundCatalog;

  WorldDocument _document;
  WorldDocument get document => _document;

  EditorTool _selectedTool = EditorTool.grass;
  EditorTool get selectedTool => _selectedTool;
  GroundCatalogItem? _selectedGroundItem;
  GroundCatalogItem? get selectedGroundItem => _selectedGroundItem;
  TileRotation _selectedGroundRotation = TileRotation.north;
  TileRotation get selectedGroundRotation => _selectedGroundRotation;
  TileRotation _selectedDecorationRotation = TileRotation.north;
  int? _elevationBrushTarget;
  int? get elevationBrushTarget => _elevationBrushTarget;

  CellCoordinate? _hoveredCell;
  CellCoordinate? get hoveredCell => _hoveredCell;

  CellCoordinate? _selectedCell;
  CellCoordinate? get selectedCell => _selectedCell;
  int? _selectedTileLayerIndex;
  int? get selectedTileLayerIndex => _selectedTileLayerIndex;
  List<PlacedTileLayer> get selectedTileLayers {
    final cell = _selectedCell;
    return cell == null ? const [] : _document.tileLayersAt(cell.x, cell.y);
  }

  PlacedTileLayer? get selectedTileLayer {
    final index = _selectedTileLayerIndex;
    final layers = selectedTileLayers;
    return index == null || index < 0 || index >= layers.length
        ? null
        : layers[index];
  }

  final List<String> _undo = [];
  final List<String> _redo = [];
  final Set<CellCoordinate> _paintedThisStroke = {};
  String? _strokeBefore;
  bool _strokeChanged = false;
  CellCoordinate? _lastElevationStrokeCell;
  int _nextActorId = 1;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void selectTool(EditorTool tool) {
    if (_selectedTool == tool && _selectedGroundItem == null) {
      if (tool.layer == EditorLayer.elevation &&
          _elevationBrushTarget != null) {
        _resetElevationBrush();
        notifyListeners();
      }
      return;
    }
    _selectedTool = tool;
    _selectedGroundItem = null;
    _selectedGroundRotation = TileRotation.north;
    _selectedDecorationRotation = TileRotation.north;
    _resetElevationBrush();
    notifyListeners();
  }

  void selectGroundItem(GroundCatalogItem item) {
    if (_selectedGroundItem == item) return;
    _selectedGroundItem = item;
    _selectedGroundRotation = TileRotation.north;
    _resetElevationBrush();
    notifyListeners();
  }

  void hover(CellCoordinate? cell) {
    if (_hoveredCell == cell) return;
    _hoveredCell = cell;
    notifyListeners();
  }

  void beginStroke() {
    _paintedThisStroke.clear();
    _strokeBefore = _document.toJsonString(pretty: false);
    _strokeChanged = false;
    _lastElevationStrokeCell = null;
  }

  void paint(CellCoordinate cell) {
    if (!_document.containsCell(cell.x, cell.y)) return;
    if (_selectedTool == EditorTool.raiseElevation ||
        _selectedTool == EditorTool.lowerElevation) {
      _paintElevation(cell);
      return;
    }
    if (!_paintedThisStroke.add(cell)) return;

    _selectedCell = cell;
    _hoveredCell = cell;
    final groundItem = _selectedGroundItem;
    if (groundItem != null) {
      final layers = _document.mutableTileLayersAt(cell.x, cell.y)
        ..add(
          PlacedTileLayer(
            assetId: groundItem.id,
            rotation: _selectedGroundRotation,
          ),
        );
      _selectedTileLayerIndex = layers.length - 1;
      _strokeChanged = true;
      notifyListeners();
      return;
    }
    if (_selectedTool == EditorTool.inspect) {
      _selectedTileLayerIndex = null;
      notifyListeners();
      return;
    }
    _selectedTileLayerIndex = null;
    final decorationType = _decorationTypeForTool(_selectedTool);
    if (decorationType != null) {
      _document.decorations[cell] = PlacedDecoration(
        type: decorationType,
        rotation: _selectedDecorationRotation,
      );
      _strokeChanged = true;
      notifyListeners();
      return;
    }

    switch (_selectedTool) {
      case EditorTool.raiseElevation || EditorTool.lowerElevation:
        throw StateError('Elevation tools are handled before the switch');
      case EditorTool.grass:
        _document.setGround(cell.x, cell.y, GroundType.grass);
      case EditorTool.road:
        _document.setRoad(cell.x, cell.y, RoadType.dirt);
      case EditorTool.rockySoil:
        _document.setGround(cell.x, cell.y, GroundType.rockySoil);
      case EditorTool.darkEarth:
        _document.setGround(cell.x, cell.y, GroundType.darkEarth);
      case EditorTool.cobblestone:
        _document.setGround(cell.x, cell.y, GroundType.cobblestone);
      case EditorTool.woodPlanks:
        _document.setGround(cell.x, cell.y, GroundType.woodPlanks);
      case EditorTool.stonePavers:
        _document.setGround(cell.x, cell.y, GroundType.stonePavers);
      case EditorTool.dryGrass:
        _document.setGround(cell.x, cell.y, GroundType.dryGrass);
      case EditorTool.roundTree ||
          EditorTool.wideTree ||
          EditorTool.ruralTreeA1 ||
          EditorTool.ruralTreeA2 ||
          EditorTool.ruralTreeA3 ||
          EditorTool.ruralTreeA4 ||
          EditorTool.ruralTreeA5 ||
          EditorTool.ruralTreeA6 ||
          EditorTool.ruralTreeA7 ||
          EditorTool.ruralTreeA8 ||
          EditorTool.ruralTreeA9 ||
          EditorTool.ruralTreeA10 ||
          EditorTool.ruralTreeA11 ||
          EditorTool.ruralTreeA12 ||
          EditorTool.ruralTreeB1 ||
          EditorTool.ruralTreeB2 ||
          EditorTool.ruralTreeB3 ||
          EditorTool.ruralTreeC1 ||
          EditorTool.ruralTreeC2 ||
          EditorTool.ruralTreeC3 ||
          EditorTool.bush ||
          EditorTool.lowFlora ||
          EditorTool.leafyGroundcover ||
          EditorTool.clayPots ||
          EditorTool.woodenCrate ||
          EditorTool.stoneWell ||
          EditorTool.woodenSign ||
          EditorTool.fallenLog ||
          EditorTool.firewoodPile ||
          EditorTool.stonePile ||
          EditorTool.hayBale ||
          EditorTool.closedChest:
        throw StateError('Decoration tools are handled before the switch');
      case EditorTool.sheep:
        _document.actors.removeWhere(
          (actor) => actor.x.round() == cell.x && actor.y.round() == cell.y,
        );
        _document.actors.add(
          PlacedActor(
            id: 'sheep_${_nextActorId++}',
            type: ActorType.sheep,
            x: cell.x.toDouble(),
            y: cell.y.toDouble(),
          ),
        );
      case EditorTool.erase:
        final actor = _document.actorAt(cell.x, cell.y);
        if (actor != null) {
          _document.actors.remove(actor);
        } else if (_document.decorations.remove(cell) == null) {
          final layers = _document.tileLayersAt(cell.x, cell.y);
          if (layers.isNotEmpty) {
            _document.removeTileLayerAt(cell.x, cell.y, layers.length - 1);
          } else if (!_document.removeRoad(cell.x, cell.y)) {
            _document.setGround(cell.x, cell.y, GroundType.grass);
          }
        }
      default:
        throw StateError('Unhandled editor tool: $_selectedTool');
    }
    _strokeChanged = true;
    _hoveredCell = cell;
    notifyListeners();
  }

  void endStroke() {
    if (_strokeChanged && _strokeBefore != null) {
      _undo.add(_strokeBefore!);
      if (_undo.length > 100) _undo.removeAt(0);
      _redo.clear();
    }
    _strokeBefore = null;
    _paintedThisStroke.clear();
    _lastElevationStrokeCell = null;
    _strokeChanged = false;
    notifyListeners();
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(_document.toJsonString(pretty: false));
    _document = WorldDocument.fromJsonString(_undo.removeLast());
    _resetElevationBrush();
    _normalizeLayerSelection();
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(_document.toJsonString(pretty: false));
    _document = WorldDocument.fromJsonString(_redo.removeLast());
    _resetElevationBrush();
    _normalizeLayerSelection();
    notifyListeners();
  }

  void replaceDocument(WorldDocument document, {bool clearHistory = true}) {
    _document = document;
    _selectedCell = null;
    _selectedTileLayerIndex = null;
    _resetElevationBrush();
    if (clearHistory) {
      _undo.clear();
      _redo.clear();
    }
    notifyListeners();
  }

  void selectTileLayer(int index) {
    if (index < 0 || index >= selectedTileLayers.length) return;
    _selectedTileLayerIndex = index;
    notifyListeners();
  }

  void rotateSelectedTileLayer(TileRotation rotation) {
    final layer = selectedTileLayer;
    if (layer == null) return;
    final updatesBrush = _selectedGroundItem?.id == layer.assetId;
    final changesLayer = layer.rotation != rotation;
    final changesBrush = updatesBrush && _selectedGroundRotation != rotation;
    if (!changesLayer && !changesBrush) return;
    if (changesLayer) {
      _recordImmediateMutation(() {
        layer.rotation = rotation;
        if (updatesBrush) _selectedGroundRotation = rotation;
      });
    } else {
      _selectedGroundRotation = rotation;
      notifyListeners();
    }
  }

  void rotateSelectedDecoration(TileRotation rotation) {
    final cell = _selectedCell;
    if (cell == null) return;
    final decoration = _document.decorationAt(cell.x, cell.y);
    if (decoration == null || !decorationSupportsRotation(decoration.type)) {
      return;
    }
    final updatesBrush =
        _decorationTypeForTool(_selectedTool) == decoration.type;
    final changesDecoration = decoration.rotation != rotation;
    final changesBrush =
        updatesBrush && _selectedDecorationRotation != rotation;
    if (!changesDecoration && !changesBrush) return;
    if (changesDecoration) {
      _recordImmediateMutation(() {
        decoration.rotation = rotation;
        if (updatesBrush) _selectedDecorationRotation = rotation;
      });
    } else {
      _selectedDecorationRotation = rotation;
      notifyListeners();
    }
  }

  void moveSelectedTileLayer(int offset) {
    final cell = _selectedCell;
    final index = _selectedTileLayerIndex;
    if (cell == null || index == null) return;
    final layers = _document.mutableTileLayersAt(cell.x, cell.y);
    final destination = (index + offset).clamp(0, layers.length - 1);
    if (destination == index) return;
    _recordImmediateMutation(() {
      final layer = layers.removeAt(index);
      layers.insert(destination, layer);
      _selectedTileLayerIndex = destination;
    });
  }

  void removeSelectedTileLayer() {
    final cell = _selectedCell;
    final index = _selectedTileLayerIndex;
    if (cell == null || index == null) return;
    _recordImmediateMutation(() {
      _document.removeTileLayerAt(cell.x, cell.y, index);
      final remaining = selectedTileLayers;
      _selectedTileLayerIndex = remaining.isEmpty
          ? null
          : index.clamp(0, remaining.length - 1);
    });
  }

  void changeSelectedElevation(int offset) {
    final cell = _selectedCell;
    if (cell == null) return;
    final next = (_document.elevationAt(cell.x, cell.y) + offset).clamp(0, 99);
    if (next == _document.elevationAt(cell.x, cell.y)) return;
    _recordImmediateMutation(
      () => _document.setElevation(cell.x, cell.y, next),
    );
  }

  void _paintElevation(CellCoordinate cell) {
    _selectedCell = cell;
    _hoveredCell = cell;
    _selectedTileLayerIndex = null;
    final beginsBrushSession = _elevationBrushTarget == null;
    final initialExtension =
        beginsBrushSession && _selectedTool == EditorTool.raiseElevation
        ? _nearbyHigherArea(cell)
        : null;
    _elevationBrushTarget ??= switch (_selectedTool) {
      EditorTool.raiseElevation =>
        initialExtension?.elevation ?? _raiseTargetAt(cell),
      EditorTool.lowerElevation =>
        (_document.elevationAt(cell.x, cell.y) - 1).clamp(0, 99),
      _ => throw StateError('Not an elevation tool'),
    };
    final previous = _lastElevationStrokeCell;
    final strokeExtension =
        previous == null && _selectedTool == EditorTool.raiseElevation
        ? initialExtension ??
              _nearbyAreaAtElevation(cell, _elevationBrushTarget!)
        : null;
    final connectedCells = previous == null
        ? strokeExtension == null
              ? [cell]
              : strokeExtension.cells
        : _edgeConnectedLine(previous, cell);
    for (final connectedCell in connectedCells) {
      if (!_document.containsCell(connectedCell.x, connectedCell.y)) continue;
      _paintedThisStroke.add(connectedCell);
      final currentElevation = _document.elevationAt(
        connectedCell.x,
        connectedCell.y,
      );
      if (currentElevation == _elevationBrushTarget ||
          (_selectedTool == EditorTool.raiseElevation &&
              currentElevation > _elevationBrushTarget!)) {
        continue;
      }
      _document.setElevation(
        connectedCell.x,
        connectedCell.y,
        _elevationBrushTarget!,
      );
      _strokeChanged = true;
    }
    _lastElevationStrokeCell = cell;
    notifyListeners();
  }

  ({List<CellCoordinate> cells, int elevation})? _nearbyHigherArea(
    CellCoordinate cell,
  ) {
    final current = _document.elevationAt(cell.x, cell.y);
    final candidates = <({CellCoordinate cell, int elevation})>[];
    ({CellCoordinate cell, int elevation, int distance, int manhattan})? best;
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        if (dx == 0 && dy == 0) continue;
        final x = cell.x + dx;
        final y = cell.y + dy;
        if (!_document.containsCell(x, y)) continue;
        final elevation = _document.elevationAt(x, y);
        if (elevation <= current) continue;
        candidates.add((cell: CellCoordinate(x, y), elevation: elevation));
        final distance = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        final manhattan = dx.abs() + dy.abs();
        final candidate = (
          cell: CellCoordinate(x, y),
          elevation: elevation,
          distance: distance,
          manhattan: manhattan,
        );
        if (best == null ||
            candidate.distance < best.distance ||
            (candidate.distance == best.distance &&
                candidate.manhattan < best.manhattan) ||
            (candidate.distance == best.distance &&
                candidate.manhattan == best.manhattan &&
                candidate.elevation > best.elevation)) {
          best = candidate;
        }
      }
    }
    if (best == null) return null;
    final targetElevation = best.elevation;
    var minX = cell.x;
    var maxX = cell.x;
    var minY = cell.y;
    var maxY = cell.y;
    for (final candidate in candidates) {
      if (candidate.elevation != targetElevation) continue;
      if (candidate.cell.x < minX) minX = candidate.cell.x;
      if (candidate.cell.x > maxX) maxX = candidate.cell.x;
      if (candidate.cell.y < minY) minY = candidate.cell.y;
      if (candidate.cell.y > maxY) maxY = candidate.cell.y;
    }
    return (
      elevation: targetElevation,
      cells: [
        for (var y = minY; y <= maxY; y++)
          for (var x = minX; x <= maxX; x++) CellCoordinate(x, y),
      ],
    );
  }

  ({List<CellCoordinate> cells, int elevation})? _nearbyAreaAtElevation(
    CellCoordinate cell,
    int targetElevation,
  ) {
    final matching = <CellCoordinate>[];
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        if (dx == 0 && dy == 0) continue;
        final x = cell.x + dx;
        final y = cell.y + dy;
        if (_document.containsCell(x, y) &&
            _document.elevationAt(x, y) == targetElevation) {
          matching.add(CellCoordinate(x, y));
        }
      }
    }
    if (matching.isEmpty) return null;
    var minX = cell.x;
    var maxX = cell.x;
    var minY = cell.y;
    var maxY = cell.y;
    for (final matchingCell in matching) {
      if (matchingCell.x < minX) minX = matchingCell.x;
      if (matchingCell.x > maxX) maxX = matchingCell.x;
      if (matchingCell.y < minY) minY = matchingCell.y;
      if (matchingCell.y > maxY) maxY = matchingCell.y;
    }
    return (
      elevation: targetElevation,
      cells: [
        for (var y = minY; y <= maxY; y++)
          for (var x = minX; x <= maxX; x++) CellCoordinate(x, y),
      ],
    );
  }

  int _raiseTargetAt(CellCoordinate cell) {
    final current = _document.elevationAt(cell.x, cell.y);
    final neighbors = <int>[];
    var hasCompleteRing = true;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final x = cell.x + dx;
        final y = cell.y + dy;
        if (!_document.containsCell(x, y)) {
          hasCompleteRing = false;
          continue;
        }
        final elevation = _document.elevationAt(x, y);
        neighbors.add(elevation);
        if (elevation < current) hasCompleteRing = false;
      }
    }
    final higherNeighbors = neighbors.where((value) => value > current);
    if (higherNeighbors.isNotEmpty) {
      return higherNeighbors.reduce((a, b) => a > b ? a : b);
    }
    if (current == 0) return 1;
    return hasCompleteRing ? (current + 1).clamp(0, 99) : current;
  }

  static List<CellCoordinate> _edgeConnectedLine(
    CellCoordinate start,
    CellCoordinate end,
  ) {
    final cells = <CellCoordinate>[start];
    var x = start.x;
    var y = start.y;
    while (x != end.x || y != end.y) {
      final remainingX = (end.x - x).abs();
      final remainingY = (end.y - y).abs();
      if (x != end.x && (remainingX >= remainingY || y == end.y)) {
        x += end.x > x ? 1 : -1;
      } else {
        y += end.y > y ? 1 : -1;
      }
      cells.add(CellCoordinate(x, y));
    }
    return cells;
  }

  void _resetElevationBrush() {
    _elevationBrushTarget = null;
    _lastElevationStrokeCell = null;
  }

  void _recordImmediateMutation(VoidCallback mutation) {
    _undo.add(_document.toJsonString(pretty: false));
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
    mutation();
    notifyListeners();
  }

  void _normalizeLayerSelection() {
    final cell = _selectedCell;
    if (cell == null || !_document.containsCell(cell.x, cell.y)) {
      _selectedCell = null;
      _selectedTileLayerIndex = null;
      return;
    }
    final layers = selectedTileLayers;
    final index = _selectedTileLayerIndex;
    if (layers.isEmpty) {
      _selectedTileLayerIndex = null;
    } else if (index != null && index >= layers.length) {
      _selectedTileLayerIndex = layers.length - 1;
    }
  }
}

DecorationType? _decorationTypeForTool(EditorTool tool) => switch (tool) {
  EditorTool.roundTree => DecorationType.roundTree,
  EditorTool.wideTree => DecorationType.wideTree,
  EditorTool.ruralTreeA1 => DecorationType.ruralTreeA1,
  EditorTool.ruralTreeA2 => DecorationType.ruralTreeA2,
  EditorTool.ruralTreeA3 => DecorationType.ruralTreeA3,
  EditorTool.ruralTreeA4 => DecorationType.ruralTreeA4,
  EditorTool.ruralTreeA5 => DecorationType.ruralTreeA5,
  EditorTool.ruralTreeA6 => DecorationType.ruralTreeA6,
  EditorTool.ruralTreeA7 => DecorationType.ruralTreeA7,
  EditorTool.ruralTreeA8 => DecorationType.ruralTreeA8,
  EditorTool.ruralTreeA9 => DecorationType.ruralTreeA9,
  EditorTool.ruralTreeA10 => DecorationType.ruralTreeA10,
  EditorTool.ruralTreeA11 => DecorationType.ruralTreeA11,
  EditorTool.ruralTreeA12 => DecorationType.ruralTreeA12,
  EditorTool.ruralTreeB1 => DecorationType.ruralTreeB1,
  EditorTool.ruralTreeB2 => DecorationType.ruralTreeB2,
  EditorTool.ruralTreeB3 => DecorationType.ruralTreeB3,
  EditorTool.ruralTreeC1 => DecorationType.ruralTreeC1,
  EditorTool.ruralTreeC2 => DecorationType.ruralTreeC2,
  EditorTool.ruralTreeC3 => DecorationType.ruralTreeC3,
  EditorTool.bush => DecorationType.bush,
  EditorTool.lowFlora => DecorationType.lowFlora,
  EditorTool.leafyGroundcover => DecorationType.leafyGroundcover,
  EditorTool.clayPots => DecorationType.clayPots,
  EditorTool.woodenCrate => DecorationType.woodenCrate,
  EditorTool.stoneWell => DecorationType.stoneWell,
  EditorTool.woodenSign => DecorationType.woodenSign,
  EditorTool.fallenLog => DecorationType.fallenLog,
  EditorTool.firewoodPile => DecorationType.firewoodPile,
  EditorTool.stonePile => DecorationType.stonePile,
  EditorTool.hayBale => DecorationType.hayBale,
  EditorTool.closedChest => DecorationType.closedChest,
  _ => null,
};
