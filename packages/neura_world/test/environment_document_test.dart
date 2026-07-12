import 'package:neura_world/neura_world.dart';
import 'package:test/test.dart';

void main() {
  test('environment document round-trips strokes and generic objects', () {
    final source = EnvironmentDocument(
      id: 'world',
      name: 'World',
      width: 12,
      height: 9,
      baseMaterialId: 'ground.meadow',
      terrainStrokes: [
        TerrainStroke(
          materialId: 'ground.earth',
          radius: 2,
          opacity: 0.8,
          points: const [WorldPoint(1.5, 2), WorldPoint(4, 5.5)],
        ),
      ],
      objects: [
        PlacedEnvironmentObject(
          id: 'tree_1',
          assetId: 'tree.blossom',
          x: 3.25,
          y: 7.5,
          direction: EnvironmentDirection.northEast,
        ),
      ],
    );

    final restored = EnvironmentDocument.fromJsonString(source.toJsonString());

    expect(restored.width, 12);
    expect(restored.terrainStrokes.single.points.last.y, 5.5);
    expect(restored.objects.single.assetId, 'tree.blossom');
    expect(restored.objects.single.direction, EnvironmentDirection.northEast);
  });

  test('directions rotate clockwise through all eight views', () {
    var direction = EnvironmentDirection.south;
    final seen = <EnvironmentDirection>{};
    for (var index = 0; index < 8; index++) {
      seen.add(direction);
      direction = direction.next;
    }
    expect(seen, EnvironmentDirection.values.toSet());
    expect(direction, EnvironmentDirection.south);
  });
}
