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
  final catalog = EnvironmentCatalog(materials: [earth], objects: [tree]);

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

  test('vertical offset and exceptional sort bias are undoable', () {
    final object = PlacedEnvironmentObject(
      id: 'tree_1',
      assetId: tree.id,
      x: 2,
      y: 2,
    );
    final controller =
        EditorController(
            EnvironmentDocument(
              id: 'test',
              name: 'Test',
              width: 20,
              height: 20,
              baseMaterialId: earth.id,
              objects: [object],
            ),
            catalog: catalog,
          )
          ..selectMode(EnvironmentEditorMode.select)
          ..beginGesture()
          ..applyAt(const WorldPoint(2, 2))
          ..endGesture()
          ..adjustSelectedVerticalOffset(0.25)
          ..adjustSelectedSortBias(-0.1);

    expect(controller.selectedObject?.verticalOffset, 0.25);
    expect(controller.selectedObject?.sortBias, -0.1);
    controller.undo();
    expect(controller.selectedObject?.sortBias, 0);
    controller.undo();
    expect(controller.selectedObject?.verticalOffset, 0);
  });

  test(
    'layers organize placement and hidden or locked content is not selectable',
    () {
      final controller = EditorController(world(), catalog: catalog)
        ..addLayer()
        ..renameLayer('layer_2', 'Trees')
        ..selectObjectAsset(tree)
        ..beginGesture()
        ..applyAt(const WorldPoint(4, 4))
        ..endGesture();

      expect(controller.document.activeLayerId, 'layer_2');
      expect(controller.selectedObject?.editorLayerId, 'layer_2');

      controller
        ..selectMode(EnvironmentEditorMode.select)
        ..toggleLayerLocked('layer_2')
        ..selectCandidates(['object_100']);
      expect(controller.selectedObject, isNull);

      controller
        ..toggleLayerLocked('layer_2')
        ..toggleLayerVisibility('layer_2')
        ..selectCandidates(['object_100']);
      expect(controller.selectedObject, isNull);
    },
  );

  test('multi-selection movement preserves relative positions', () {
    final controller =
        EditorController(
            EnvironmentDocument(
              id: 'test',
              name: 'Test',
              width: 20,
              height: 20,
              baseMaterialId: earth.id,
              objects: [
                PlacedEnvironmentObject(id: 'a', assetId: tree.id, x: 2, y: 3),
                PlacedEnvironmentObject(id: 'b', assetId: tree.id, x: 5, y: 7),
              ],
            ),
            catalog: catalog,
          )
          ..selectObjectIds(['a', 'b'])
          ..beginGesture()
          ..moveSelectionDuringGesture(
            const WorldPoint(2, 3),
            const WorldPoint(4, 6),
          )
          ..endGesture();

    expect(controller.document.objects[0].x, 4);
    expect(controller.document.objects[0].y, 6);
    expect(controller.document.objects[1].x, 7);
    expect(controller.document.objects[1].y, 10);
    controller.undo();
    expect(controller.document.objects[0].x, 2);
    expect(controller.document.objects[1].x, 5);
  });

  test(
    'layers can be regrouped without cycles and every change is undoable',
    () {
      final controller = EditorController(world(), catalog: catalog)
        ..addLayer()
        ..renameLayer('layer_2', 'Vegetation')
        ..setActiveLayer(EnvironmentDocument.rootLayerId)
        ..addLayer()
        ..renameLayer('layer_3', 'Structures');

      expect(controller.reparentLayer('layer_2', 'layer_3'), isTrue);
      expect(
        controller.document.editorLayerById('layer_2')?.parentId,
        'layer_3',
      );
      expect(controller.reparentLayer('layer_3', 'layer_2'), isFalse);
      controller.undo();
      expect(
        controller.document.editorLayerById('layer_2')?.parentId,
        EnvironmentDocument.rootLayerId,
      );

      controller
        ..toggleLayerVisibility('layer_3')
        ..toggleLayerLocked('layer_3')
        ..toggleLayerExported('layer_3');
      expect(controller.document.editorLayerById('layer_3')?.visible, isFalse);
      expect(controller.document.editorLayerById('layer_3')?.locked, isTrue);
      expect(controller.document.editorLayerById('layer_3')?.exported, isFalse);
      controller.undo();
      expect(controller.document.editorLayerById('layer_3')?.exported, isTrue);
      controller.undo();
      expect(controller.document.editorLayerById('layer_3')?.locked, isFalse);
      controller.undo();
      expect(controller.document.editorLayerById('layer_3')?.visible, isTrue);
    },
  );

  test('asset geometry edits participate in global undo and redo', () {
    final controller =
        EditorController(
            EnvironmentDocument(
              id: 'test',
              name: 'Test',
              width: 20,
              height: 20,
              baseMaterialId: earth.id,
              objects: [
                PlacedEnvironmentObject(
                  id: 'tree_1',
                  assetId: tree.id,
                  x: 2,
                  y: 2,
                ),
              ],
            ),
            catalog: catalog,
          )
          ..selectObjectIds(['tree_1'])
          ..selectMode(EnvironmentEditorMode.collision)
          ..addGeometryShape(GeometryShapeType.ellipse);

    final edited = catalog.geometryForObjectId(tree.id)!;
    expect(edited.blocking.single, isA<EnvironmentEllipse>());
    expect(catalog.geometryOverrides, contains(tree.id));

    controller.undo();
    expect(catalog.geometryOverrides, isNot(contains(tree.id)));
    controller.redo();
    expect(catalog.geometryForObjectId(tree.id)?.blocking, hasLength(1));

    controller
      ..selectGeometryRole(GeometryRole.selection)
      ..addGeometryShape(GeometryShapeType.polygon);
    expect(catalog.geometryForObjectId(tree.id)?.selection, hasLength(1));
    controller.undo();
    expect(catalog.geometryForObjectId(tree.id)?.selection, isEmpty);
  });
}
