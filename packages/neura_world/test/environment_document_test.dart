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
          verticalOffset: 1.25,
          sortBias: -0.2,
          direction: EnvironmentDirection.northEast,
        ),
      ],
      editorLayers: [
        EditorLayer(id: EnvironmentDocument.rootLayerId, name: 'World'),
        EditorLayer(
          id: 'layer_trees',
          name: 'Trees',
          parentId: EnvironmentDocument.rootLayerId,
        ),
      ],
    );
    source.objects.single.editorLayerId = 'layer_trees';

    final restored = EnvironmentDocument.fromJsonString(source.toJsonString());

    expect(restored.width, 12);
    expect(restored.terrainStrokes.single.points.last.y, 5.5);
    expect(restored.objects.single.assetId, 'tree.blossom');
    expect(restored.objects.single.direction, EnvironmentDirection.northEast);
    expect(restored.objects.single.verticalOffset, 1.25);
    expect(restored.objects.single.sortBias, -0.2);
    expect(restored.schemaVersion, EnvironmentDocument.currentSchemaVersion);
    expect(restored.objects.single.editorLayerId, 'layer_trees');
    expect(restored.editorLayerById('layer_trees')?.parentId, 'layer_world');
  });

  test('schema v1 migrates z to physical vertical offset', () {
    final restored = EnvironmentDocument.fromJsonString('''
      {
        "schemaVersion": 1,
        "id": "legacy",
        "name": "Legacy",
        "width": 8,
        "height": 8,
        "baseMaterialId": "ground",
        "terrainStrokes": [],
        "objects": [
          {
            "id": "tree_7",
            "assetId": "tree",
            "x": 3.5,
            "y": 4.25,
            "z": 1.5,
            "direction": "south"
          }
        ]
      }
    ''');

    expect(restored.schemaVersion, 3);
    expect(restored.objects.single.id, 'tree_7');
    expect(restored.objects.single.x, 3.5);
    expect(restored.objects.single.y, 4.25);
    expect(restored.objects.single.verticalOffset, 1.5);
    expect(restored.objects.single.sortBias, 0);
    expect(
      restored.objects.single.editorLayerId,
      EnvironmentDocument.rootLayerId,
    );
    expect(restored.editorLayers.single.name, 'World');
    expect(restored.toJsonString(), contains('"verticalOffset"'));
    expect(restored.toJsonString(), isNot(contains('"z"')));
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
