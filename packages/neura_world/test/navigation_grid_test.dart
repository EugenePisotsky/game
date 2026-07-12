import 'package:neura_world/neura_world.dart';
import 'package:test/test.dart';

void main() {
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
  });
}
