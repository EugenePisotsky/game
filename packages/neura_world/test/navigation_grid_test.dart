import 'dart:typed_data';

import 'package:neura_world/neura_world.dart';
import 'package:test/test.dart';

void main() {
  test('cached navigation cells avoid authored collision callbacks', () {
    var sourceQueries = 0;
    final grid = NavigationGrid(
      width: 2,
      height: 2,
      cellSize: 0.4,
      isBlocked: (_) {
        sourceQueries++;
        return false;
      },
      blockedCells: Uint8List(25)..[12] = 1,
    );

    expect(grid.isCellBlocked(const WorldPoint(1, 1)), isTrue);
    expect(grid.isCellBlocked(const WorldPoint(0.2, 0.2)), isFalse);
    expect(sourceQueries, 0);
  });

  test('navigation grid routes around an expanded obstacle', () {
    final grid = NavigationGrid(
      width: 10,
      height: 10,
      cellSize: 0.5,
      isBlocked: (point) {
        final dx = point.x - 5;
        final dy = point.y - 5;
        return dx * dx + dy * dy <= 1.5 * 1.5;
      },
    );

    final path = grid.findPath(const WorldPoint(2, 5), const WorldPoint(8, 5));

    expect(path, isNotEmpty);
    expect(path.last.x, 8);
    expect(path.last.y, 5);
    expect(path.any((point) => (point.y - 5).abs() > 1.5), isTrue);
    expect(path.every((point) => !grid.isBlocked(point)), isTrue);
    var segmentStart = const WorldPoint(2, 5);
    for (final point in path) {
      expect(grid.isSegmentWalkable(segmentStart, point), isTrue);
      segmentStart = point;
    }
    expect(grid.lastPath, path);
    expect(grid.lastExpandedNodeCount, greaterThan(0));
  });

  test('navigation grid returns no path across a sealed wall', () {
    final grid = NavigationGrid(
      width: 6,
      height: 6,
      cellSize: 0.5,
      isBlocked: (point) => point.x >= 2.75 && point.x <= 3.25,
    );

    expect(
      grid.findPath(const WorldPoint(1, 3), const WorldPoint(5, 3)),
      isEmpty,
    );
    expect(grid.lastPath, isEmpty);
    expect(grid.lastExpandedNodeCount, greaterThan(0));
  });

  test('open arbitrary movement stays one straight segment', () {
    final grid = NavigationGrid(
      width: 10,
      height: 10,
      cellSize: 0.4,
      isBlocked: (_) => false,
    );
    const start = WorldPoint(1.13, 2.27);
    const destination = WorldPoint(3.04, 2.91);

    final path = grid.findPath(start, destination);

    expect(path, [destination]);
    expect(grid.isSegmentWalkable(start, destination), isTrue);
  });

  test(
    'segment validation checks exact geometry inside an open cached cell',
    () {
      var exactQueries = 0;
      final grid = NavigationGrid(
        width: 2,
        height: 2,
        cellSize: 0.4,
        isBlocked: (point) {
          exactQueries++;
          return point.x >= 0.35 && point.x <= 0.45;
        },
        blockedCells: Uint8List(25),
      );

      expect(
        grid.isSegmentWalkable(
          const WorldPoint(0.1, 0.2),
          const WorldPoint(0.6, 0.2),
        ),
        isFalse,
      );
      expect(exactQueries, greaterThan(0));
    },
  );
}
