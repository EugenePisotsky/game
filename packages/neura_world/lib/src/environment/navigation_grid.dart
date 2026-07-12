import 'dart:math' as math;

import 'environment_document.dart';

typedef WorldBlockedTest = bool Function(WorldPoint point);

class NavigationGrid {
  NavigationGrid({
    required this.width,
    required this.height,
    required this.isBlocked,
    this.cellSize = 0.4,
  }) : columns = (width / cellSize).ceil(),
       rows = (height / cellSize).ceil();

  final double width;
  final double height;
  final double cellSize;
  final int columns;
  final int rows;
  final WorldBlockedTest isBlocked;

  List<WorldPoint> findPath(WorldPoint start, WorldPoint destination) {
    final startCell = _cellFor(start);
    final requestedEnd = _cellFor(destination);
    final endCell = _nearestOpen(requestedEnd);
    if (endCell == null || isBlocked(start)) return const [];

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
      if (current == endCell) {
        return _reconstruct(cameFrom, current, start, destination);
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
    return const [];
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

    final compressed = <WorldPoint>[points.first];
    for (var index = 1; index < points.length - 1; index++) {
      final previous = compressed.last;
      final current = points[index];
      final next = points[index + 1];
      final ax = current.x - previous.x;
      final ay = current.y - previous.y;
      final bx = next.x - current.x;
      final by = next.y - current.y;
      if ((ax * by - ay * bx).abs() > 0.0001) compressed.add(current);
    }
    compressed.add(points.last);
    return compressed.skip(1).toList();
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

  bool _blockedCell(_GridCell cell) =>
      !_inside(cell) || isBlocked(_center(cell));

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
