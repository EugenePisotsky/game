import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_editor/editor_controller.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  const earth = EnvironmentMaterial(
    id: 'earth',
    name: 'Earth',
    texturePath: 'earth.png',
    decalPath: 'earth_decal.png',
  );
  const tree = EnvironmentObjectAsset(
    id: 'tree',
    name: 'Tree',
    category: 'Trees',
    renderScale: 1,
    views: {
      'south': EnvironmentObjectView(imagePath: 'tree.png'),
      'southWest': EnvironmentObjectView(imagePath: 'tree_sw.png'),
    },
  );
  const catalog = EnvironmentCatalog(materials: [earth], objects: [tree]);

  EnvironmentDocument world() => EnvironmentDocument(
    id: 'test',
    name: 'Test',
    width: 20,
    height: 20,
    baseMaterialId: earth.id,
  );

  test('paint gesture creates one serializable continuous stroke', () {
    final controller = EditorController(world(), catalog: catalog)
      ..selectPaintMaterial(earth)
      ..beginGesture()
      ..applyAt(const WorldPoint(2, 3))
      ..applyAt(const WorldPoint(3, 4))
      ..endGesture();

    expect(controller.document.terrainStrokes, hasLength(1));
    expect(controller.document.terrainStrokes.single.materialId, earth.id);
    expect(controller.document.terrainStrokes.single.points, hasLength(2));

    final restored = EnvironmentDocument.fromJsonString(
      controller.document.toJsonString(),
    );
    expect(restored.terrainStrokes.single.points.last.x, 3);

    controller.undo();
    expect(controller.document.terrainStrokes, isEmpty);
    controller.redo();
    expect(controller.document.terrainStrokes, hasLength(1));
  });

  test('objects can be placed, selected, moved, rotated, and deleted', () {
    final controller = EditorController(world(), catalog: catalog)
      ..selectObjectAsset(tree)
      ..beginGesture()
      ..applyAt(const WorldPoint(4, 5))
      ..endGesture();

    expect(controller.document.objects, hasLength(1));
    expect(controller.selectedObject?.assetId, tree.id);

    controller
      ..selectMode(EnvironmentEditorMode.select)
      ..beginGesture()
      ..applyAt(const WorldPoint(4, 5))
      ..moveSelectedDuringGesture(const WorldPoint(7.5, 8.25))
      ..endGesture()
      ..rotateSelected();

    expect(controller.selectedObject?.x, 7.5);
    expect(
      controller.selectedObject?.direction,
      EnvironmentDirection.southWest,
    );

    controller.deleteSelected();
    expect(controller.document.objects, isEmpty);
    controller.undo();
    expect(controller.document.objects, hasLength(1));
  });

  test('placing object once does not spray objects while dragging', () {
    final controller = EditorController(world(), catalog: catalog)
      ..selectObjectAsset(tree)
      ..beginGesture()
      ..applyAt(const WorldPoint(1, 1))
      ..applyAt(const WorldPoint(2, 2))
      ..applyAt(const WorldPoint(3, 3))
      ..endGesture();

    expect(controller.document.objects, hasLength(1));
  });
}
