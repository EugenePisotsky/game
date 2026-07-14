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
  const crate = EnvironmentObjectAsset(
    id: 'crate',
    name: 'Crate',
    category: 'Containers',
    categoryPath: ['Props', 'Containers'],
    viewMode: EnvironmentAssetViewMode.fourWay,
    renderScale: 1,
    views: {
      'south': EnvironmentObjectView(imagePath: 'crate_s.png'),
      'west': EnvironmentObjectView(imagePath: 'crate_w.png'),
      'east': EnvironmentObjectView(imagePath: 'crate_e.png'),
      'north': EnvironmentObjectView(imagePath: 'crate_n.png'),
    },
  );
  const potion = EnvironmentObjectAsset(
    id: 'potion',
    name: 'Potion',
    category: 'Bottles & Potions',
    categoryPath: ['Small Items', 'Bottles & Potions'],
    viewMode: EnvironmentAssetViewMode.fixed,
    renderScale: 1,
    views: {'south': EnvironmentObjectView(imagePath: 'potion.png')},
  );
  final catalog = EnvironmentCatalog(
    materials: [earth],
    objects: [tree, crate, potion],
  );

  EnvironmentDocument world() => EnvironmentDocument(
    id: 'test',
    name: 'Test',
    width: 20,
    height: 20,
    baseMaterialId: earth.id,
  );

  test('hover updates do not rebuild editor controls', () {
    final controller = EditorController(world(), catalog: catalog);
    var editorUpdates = 0;
    var hoverUpdates = 0;
    controller
      ..addListener(() => editorUpdates++)
      ..hoverListenable.addListener(() => hoverUpdates++)
      ..hover(const WorldPoint(2, 3))
      ..hoverObjects(const []);

    expect(editorUpdates, 0);
    expect(hoverUpdates, 1);

    controller.selectMode(EnvironmentEditorMode.select);
    expect(editorUpdates, 1);
    controller.dispose();
  });

  test('drag updates canvas continuously and editor controls on release', () {
    final controller = EditorController(
      EnvironmentDocument(
        id: 'test',
        name: 'Test',
        width: 20,
        height: 20,
        baseMaterialId: earth.id,
        objects: [
          PlacedEnvironmentObject(id: 'tree_1', assetId: tree.id, x: 2, y: 2),
        ],
      ),
      catalog: catalog,
    )..selectObjectIds(['tree_1']);
    var editorUpdates = 0;
    var canvasUpdates = 0;
    controller
      ..addListener(() => editorUpdates++)
      ..hoverListenable.addListener(() => canvasUpdates++)
      ..beginGesture()
      ..moveSelectionDuringGesture(
        const WorldPoint(2, 2),
        const WorldPoint(4, 5),
      );

    expect(
      (controller.selectedObject!.x, controller.selectedObject!.y),
      (4, 5),
    );
    expect(editorUpdates, 0);
    expect(canvasUpdates, 1);

    controller.endGesture();
    expect(editorUpdates, 1);
    controller.dispose();
  });

  test('paint gesture creates one serializable continuous stroke', () {
    final controller = EditorController(world(), catalog: catalog)
      ..selectPaintMaterial(earth)
      ..setBrushFlow(0.3)
      ..setBrushScatter(0.4)
      ..beginGesture()
      ..applyAt(const WorldPoint(2, 3))
      ..applyAt(const WorldPoint(3, 4))
      ..endGesture();

    expect(controller.document.terrainStrokes, hasLength(1));
    expect(controller.document.terrainStrokes.single.materialId, earth.id);
    expect(controller.document.terrainStrokes.single.points, hasLength(2));
    expect(controller.document.terrainStrokes.single.opacity, 0.3);
    expect(controller.document.terrainStrokes.single.spacing, 0.72);
    expect(controller.document.terrainStrokes.single.scatter, 0.4);
    expect(controller.document.terrainStrokes.single.seed, greaterThan(0));
    expect(controller.terrainRevision, 1);
    expect(
      controller.lastTerrainChangedStroke,
      same(controller.document.terrainStrokes.single),
    );
    expect(controller.activeTerrainStroke, isNull);

    final restored = EnvironmentDocument.fromJsonString(
      controller.document.toJsonString(),
    );
    expect(restored.terrainStrokes.single.points.last.x, 3);

    controller.undo();
    expect(controller.document.terrainStrokes, isEmpty);
    expect(controller.terrainRevision, 2);
    expect(controller.lastTerrainChangedStroke, isNull);
    controller.redo();
    expect(controller.document.terrainStrokes, hasLength(1));
    expect(controller.terrainRevision, 3);
  });

  test(
    'active paint stroke does not invalidate baked terrain until commit',
    () {
      final controller = EditorController(world(), catalog: catalog)
        ..selectPaintMaterial(earth)
        ..beginGesture()
        ..applyAt(const WorldPoint(2, 3));

      expect(controller.activeTerrainStroke, isNotNull);
      expect(controller.terrainRevision, 0);

      controller.endGesture();

      expect(controller.activeTerrainStroke, isNull);
      expect(controller.terrainRevision, 1);
    },
  );

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

  test('path placement fills a line as one undoable multi-selection', () {
    final controller = EditorController(world(), catalog: catalog)
      ..selectPathObjectAsset(crate)
      ..setPathPieceLength(1)
      ..setPathGap(0)
      ..beginGesture()
      ..applyAt(const WorldPoint(1, 1))
      ..applyAt(const WorldPoint(5, 1));

    expect(controller.pathPreviewPlacements, hasLength(5));
    expect(
      controller.pathPreviewPlacements.every(
        (placement) => crate.supportsDirection(placement.direction.name),
      ),
      isTrue,
    );

    controller.endGesture();

    expect(controller.document.objects, isEmpty);
    expect(controller.hasPathDraft, isTrue);
    controller.setPathGap(1);
    expect(controller.pathPreviewPlacements, hasLength(3));
    controller.setPathGap(0);
    controller.applyPathDraft();

    expect(controller.document.objects, hasLength(5));
    expect(controller.selectedObjectIds, hasLength(5));
    expect(
      controller.document.objects.map((object) => object.id).toSet(),
      hasLength(5),
    );
    controller.undo();
    expect(controller.document.objects, isEmpty);
    controller.redo();
    expect(controller.document.objects, hasLength(5));
  });

  test('path endpoints can be corrected before applying or cancelled', () {
    final controller = EditorController(world(), catalog: catalog)
      ..selectPathObjectAsset(crate)
      ..setPathPieceLength(1)
      ..beginGesture()
      ..applyAt(const WorldPoint(1, 1))
      ..applyAt(const WorldPoint(5, 1))
      ..endGesture()
      ..beginGesture()
      ..applyAt(const WorldPoint(5, 1))
      ..applyAt(const WorldPoint(7, 1))
      ..endGesture();

    expect(controller.pathStart, const WorldPoint(1, 1));
    expect(controller.pathEnd, const WorldPoint(7, 1));
    expect(controller.pathPreviewPlacements, hasLength(7));
    expect(controller.document.objects, isEmpty);

    controller.cancelPathDraft();
    expect(controller.hasPathDraft, isFalse);
    expect(controller.document.objects, isEmpty);
  });

  test('rotated placement direction is remembered until asset changes', () {
    final controller = EditorController(world(), catalog: catalog)
      ..selectObjectAsset(crate)
      ..beginGesture()
      ..applyAt(const WorldPoint(1, 1))
      ..endGesture()
      ..rotateSelected()
      ..beginGesture()
      ..applyAt(const WorldPoint(2, 2))
      ..endGesture();

    expect(controller.document.objects.map((object) => object.direction), [
      EnvironmentDirection.west,
      EnvironmentDirection.west,
    ]);

    controller
      ..selectObjectAsset(tree)
      ..beginGesture()
      ..applyAt(const WorldPoint(3, 3))
      ..endGesture();
    expect(
      controller.document.objects.last.direction,
      EnvironmentDirection.south,
    );
  });

  test('path opening leaves a centered passage', () {
    final controller = EditorController(world(), catalog: catalog)
      ..selectPathObjectAsset(crate)
      ..setPathPieceLength(1)
      ..setPathOpening(1.5)
      ..beginGesture()
      ..applyAt(const WorldPoint(1, 1))
      ..applyAt(const WorldPoint(5, 1));

    expect(controller.pathPreviewPlacements, hasLength(4));
    expect(
      controller.pathPreviewPlacements
          .map((placement) => placement.point.x)
          .contains(3),
      isFalse,
    );
  });

  test('rotation skips unavailable facings and leaves fixed art unchanged', () {
    final controller = EditorController(
      EnvironmentDocument(
        id: 'test',
        name: 'Test',
        width: 20,
        height: 20,
        baseMaterialId: earth.id,
        objects: [
          PlacedEnvironmentObject(id: 'crate_1', assetId: crate.id, x: 2, y: 2),
          PlacedEnvironmentObject(
            id: 'potion_1',
            assetId: potion.id,
            x: 3,
            y: 3,
          ),
        ],
      ),
      catalog: catalog,
    );

    controller
      ..selectObjectIds(['crate_1'])
      ..rotateSelected();
    expect(
      controller.document.objects.first.direction,
      EnvironmentDirection.west,
    );

    controller
      ..selectObjectIds(['potion_1'])
      ..rotateSelected();
    expect(
      controller.document.objects.last.direction,
      EnvironmentDirection.south,
    );
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
      final placedId = controller.selectedObject!.id;

      expect(controller.document.activeLayerId, 'layer_2');
      expect(controller.selectedObject?.editorLayerId, 'layer_2');
      expect(placedId, startsWith('object_'));

      controller
        ..selectMode(EnvironmentEditorMode.select)
        ..toggleLayerLocked('layer_2')
        ..selectCandidates([placedId]);
      expect(controller.selectedObject, isNull);

      controller
        ..toggleLayerLocked('layer_2')
        ..toggleLayerVisibility('layer_2')
        ..selectCandidates([placedId]);
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
