import 'dart:math' as math;
import 'dart:typed_data';

import 'environment_document.dart';

typedef WorldBlockedTest = bool Function(WorldPoint point);

class NavigationGrid {
  NavigationGrid({
    required this.width,
    required this.height,
    required WorldBlockedTest isBlocked,
    this.cellSize = 0.4,
    Uint8List? blockedCells,
  }) : columns = (width / cellSize).ceil(),
       rows = (height / cellSize).ceil(),
       _sourceIsBlocked = isBlocked,
       _blockedCells = blockedCells {
    if (blockedCells != null && blockedCells.length != columns * rows) {
      throw ArgumentError.value(
        blockedCells.length,
        'blockedCells',
        'Expected ${columns * rows} navigation cells.',
      );
    }
  }

  final double width;
  final double height;
  final double cellSize;
  final int columns;
  final int rows;
  final WorldBlockedTest _sourceIsBlocked;
  final Uint8List? _blockedCells;
  int lastExpandedNodeCount = 0;
  List<WorldPoint> lastPath = const [];

  bool isBlocked(WorldPoint point) => _sourceIsBlocked(point);

  bool isCellBlocked(WorldPoint point) {
    if (point.x < 0 || point.y < 0 || point.x > width || point.y > height) {
      return true;
    }
    final cached = _blockedCells;
    if (cached == null) return isBlocked(point);
    return cached[_indexFor(_cellFor(point))] != 0;
  }

  void recordExternalPath(List<WorldPoint> path, {required int expandedNodes}) {
    lastPath = List.unmodifiable(path);
    lastExpandedNodeCount = expandedNodes;
  }

  List<WorldPoint> findPath(WorldPoint start, WorldPoint destination) {
    lastExpandedNodeCount = 0;
    lastPath = const [];
    final startCell = _cellFor(start);
    final requestedEnd = _cellFor(destination);
    final endCell = _nearestOpen(requestedEnd);
    if (endCell == null || isBlocked(start)) return lastPath;

    final open = <_GridCell>[startCell];
    final openSet = <_GridCell>{startCell};
    final closed = <_GridCell>{};
    final cameFrom = <_GridCell, _GridCell>{};
    final gScore = <_GridCell, double>{startCell: 0};
    final fScore = <_GridCell, double>{
      startCell: _heuristic(startCell, endCell),
    };

    while (open.isNotEmpty) {
      var bestIndex = 0;
      for (var index = 1; index < open.length; index++) {
        if ((fScore[open[index]] ?? double.infinity) <
            (fScore[open[bestIndex]] ?? double.infinity)) {
          bestIndex = index;
        }
      }
      final current = open.removeAt(bestIndex);
      openSet.remove(current);
      lastExpandedNodeCount++;
      if (current == endCell) {
        lastPath = _reconstruct(cameFrom, current, start, destination);
        return lastPath;
      }
      closed.add(current);

      for (final neighbor in _neighbors(current)) {
        if (closed.contains(neighbor) || _blockedCell(neighbor)) continue;
        final diagonal = neighbor.x != current.x && neighbor.y != current.y;
        if (diagonal &&
            (_blockedCell(_GridCell(neighbor.x, current.y)) ||
                _blockedCell(_GridCell(current.x, neighbor.y)))) {
          continue;
        }
        final tentative =
            (gScore[current] ?? double.infinity) + (diagonal ? math.sqrt2 : 1);
        if (tentative >= (gScore[neighbor] ?? double.infinity)) continue;
        cameFrom[neighbor] = current;
        gScore[neighbor] = tentative;
        fScore[neighbor] = tentative + _heuristic(neighbor, endCell);
        if (openSet.add(neighbor)) open.add(neighbor);
      }
    }
    return lastPath;
  }

  List<WorldPoint> _reconstruct(
    Map<_GridCell, _GridCell> cameFrom,
    _GridCell end,
    WorldPoint start,
    WorldPoint requestedDestination,
  ) {
    final cells = <_GridCell>[end];
    while (true) {
      final previous = cameFrom[cells.last];
      if (previous == null) break;
      cells.add(previous);
    }
    final forward = cells.reversed.toList();
    final points = <WorldPoint>[start];
    for (final cell in forward.skip(1)) {
      points.add(_center(cell));
    }
    if (!isBlocked(requestedDestination)) points.add(requestedDestination);

    return _smoothVisibleSegments(points);
  }

  /// Whether an actor can travel directly between two points without touching
  /// a blocked cell or authored collider.
  bool isSegmentWalkable(WorldPoint start, WorldPoint end) {
    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final distance = math.sqrt(dx * dx + dy * dy);
    final steps = math.max(1, (distance / (cellSize / 3)).ceil());
    for (var step = 0; step <= steps; step++) {
      final t = step / steps;
      final point = WorldPoint(start.x + dx * t, start.y + dy * t);
      if (point.x < 0 || point.y < 0 || point.x > width || point.y > height) {
        return false;
      }
      if (isBlocked(point)) return false;
      if (_blockedCells != null && isCellBlocked(point)) return false;
    }
    return true;
  }

  List<WorldPoint> _smoothVisibleSegments(List<WorldPoint> points) {
    if (points.length < 2) return const [];
    final result = <WorldPoint>[];
    var anchor = 0;
    while (anchor < points.length - 1) {
      var next = points.length - 1;
      while (next > anchor + 1 &&
          !isSegmentWalkable(points[anchor], points[next])) {
        next--;
      }
      result.add(points[next]);
      anchor = next;
    }
    return result;
  }

  _GridCell? _nearestOpen(_GridCell requested) {
    if (!_blockedCell(requested)) return requested;
    for (var radius = 1; radius <= 8; radius++) {
      for (var y = requested.y - radius; y <= requested.y + radius; y++) {
        for (var x = requested.x - radius; x <= requested.x + radius; x++) {
          if ((x - requested.x).abs() != radius &&
              (y - requested.y).abs() != radius) {
            continue;
          }
          final candidate = _GridCell(x, y);
          if (!_blockedCell(candidate)) return candidate;
        }
      }
    }
    return null;
  }

  Iterable<_GridCell> _neighbors(_GridCell cell) sync* {
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final neighbor = _GridCell(cell.x + dx, cell.y + dy);
        if (_inside(neighbor)) yield neighbor;
      }
    }
  }

  bool _blockedCell(_GridCell cell) {
    if (!_inside(cell)) return true;
    final cached = _blockedCells;
    return cached == null
        ? _sourceIsBlocked(_center(cell))
        : cached[_indexFor(cell)] != 0;
  }

  bool _inside(_GridCell cell) =>
      cell.x >= 0 && cell.y >= 0 && cell.x < columns && cell.y < rows;

  _GridCell _cellFor(WorldPoint point) => _GridCell(
    (point.x / cellSize).floor().clamp(0, columns - 1),
    (point.y / cellSize).floor().clamp(0, rows - 1),
  );

  WorldPoint _center(_GridCell cell) => WorldPoint(
    math.min(width, (cell.x + 0.5) * cellSize),
    math.min(height, (cell.y + 0.5) * cellSize),
  );

  int _indexFor(_GridCell cell) => cell.y * columns + cell.x;

  double _heuristic(_GridCell a, _GridCell b) {
    final dx = (a.x - b.x).abs();
    final dy = (a.y - b.y).abs();
    return math.max(dx, dy) + (math.sqrt2 - 1) * math.min(dx, dy);
  }
}

class _GridCell {
  const _GridCell(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is _GridCell && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}
