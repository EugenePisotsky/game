import 'package:neura_world/neura_world.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(initNeuraWorldRust);

  test('Native Assets bridge builds a cached grid and finds a path', () async {
    final world = await RustNavigationWorld.create(
      const NativeNavigationWorldInput(
        width: 10,
        height: 10,
        cellSize: 0.4,
        actorRadius: 0.18,
        baseBlocked: false,
        terrainStrokes: [],
        objectColliders: [
          NativeNavigationPolygon(
            points: [
              NativeNavigationPoint(x: 4, y: 3),
              NativeNavigationPoint(x: 6, y: 3),
              NativeNavigationPoint(x: 6, y: 7),
              NativeNavigationPoint(x: 4, y: 7),
            ],
          ),
        ],
      ),
    );
    addTearDown(world.close);

    expect(world.snapshot.blockedCells, hasLength(25 * 25));
    expect(world.snapshot.blockedCells, contains(1));

    final result = await world.findPath(
      start: const NativeNavigationPoint(x: 2, y: 5),
      destination: const NativeNavigationPoint(x: 8, y: 5),
    );
    expect(result.points, isNotEmpty);
    expect(result.points.last.x, closeTo(8, 0.0001));
    expect(result.points.last.y, closeTo(5, 0.0001));
    expect(result.expandedNodes, greaterThan(0));
  });
}
