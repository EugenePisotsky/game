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
  const grass = EnvironmentMaterial(
    id: 'grass',
    name: 'Grass',
    texturePath: 'grass.png',
    decalPath: 'grass_decal.png',
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
    materials: [earth, grass],
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

  test('world edits do not rebuild the asset palette', () {
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
    var paletteUpdates = 0;
    controller.paletteListenable.addListener(() => paletteUpdates++);

    controller
      ..beginGesture()
      ..moveSelectionDuringGesture(
        const WorldPoint(2, 2),
        const WorldPoint(3, 3),
      )
      ..endGesture();
    expect(paletteUpdates, 0);

    controller.selectMode(EnvironmentEditorMode.select);
    expect(paletteUpdates, 1);
    controller.dispose();
  });

  test('object undo retains untouched world entities', () {
    final objects = [
      for (var index = 0; index < 2000; index++)
        PlacedEnvironmentObject(
          id: 'tree_$index',
          assetId: tree.id,
          x: (index % 20).toDouble(),
          y: (index ~/ 20).toDouble(),
        ),
    ];
    final controller = EditorController(
      EnvironmentDocument(
        id: 'large',
        name: 'Large',
        width: 200,
        height: 200,
        baseMaterialId: earth.id,
        objects: objects,
      ),
      catalog: catalog,
    )..selectObjectIds(['tree_0']);
    final untouched = controller.objectById('tree_1999');

    controller
      ..beginGesture()
      ..moveSelectionDuringGesture(
        const WorldPoint(0, 0),
        const WorldPoint(1, 1),
      )
      ..endGesture()
      ..undo();

    expect(controller.objectById('tree_0')?.x, 0);
    expect(controller.objectById('tree_1999'), same(untouched));
    expect(controller.document.objects, hasLength(2000));
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

  test('cross-surface occlusion scope is authored and undoable', () {
    final controller = EditorController(
      EnvironmentDocument(
        id: 'test',
        name: 'Test',
        width: 20,
        height: 20,
        baseMaterialId: earth.id,
        objects: [
          PlacedEnvironmentObject(id: 'ship_1', assetId: tree.id, x: 2, y: 2),
        ],
      ),
      catalog: catalog,
    )..selectObjectIds(['ship_1']);

    controller.setSelectedCrossSurfaceOcclusion(true);
    expect(controller.selectedObject?.crossSurfaceOcclusion, isTrue);
    expect(controller.selectedObject?.occlusionHeight, 4);

    controller.adjustSelectedOcclusionHeight(0.5);
    expect(controller.selectedObject?.occlusionHeight, 4.5);
    controller.undo();
    expect(controller.selectedObject?.occlusionHeight, 4);
    controller.undo();
    expect(controller.selectedObject?.crossSurfaceOcclusion, isFalse);
    expect(controller.selectedObject?.occlusionHeight, 0);
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

  test('keyboard nudging moves the complete selection and is undoable', () {
    final controller = EditorController(
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
    )..selectObjectIds(['a', 'b']);

    expect(controller.nudgeSelection(0.25, -0.25), isTrue);
    expect(
      (controller.document.objects[0].x, controller.document.objects[0].y),
      (2.25, 2.75),
    );
    expect(
      (controller.document.objects[1].x, controller.document.objects[1].y),
      (5.25, 6.75),
    );
    controller.undo();
    expect(
      (controller.document.objects[0].x, controller.document.objects[0].y),
      (2, 3),
    );
  });

  test(
    'copied objects paste with new identities and preserve their layout',
    () {
      final controller = EditorController(
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
      )..selectObjectIds(['a', 'b']);

      final source = controller.copySelectionToJson();
      expect(source, isNotNull);
      expect(controller.pasteSelectionFromJson(source!), isTrue);
      expect(controller.document.objects, hasLength(4));
      final pasted = controller.selectedObjects;
      expect(pasted.map((object) => object.id), isNot(contains('a')));
      expect(pasted.map((object) => object.id), isNot(contains('b')));
      expect(pasted[1].x - pasted[0].x, 3);
      expect(pasted[1].y - pasted[0].y, 4);
      expect(pasted[0].x, 2.5);
      controller.undo();
      expect(controller.document.objects, hasLength(2));
    },
  );

  test('ground reset records an overlay-clearing polygon and is undoable', () {
    final controller = EditorController(
      EnvironmentDocument(
        id: 'test',
        name: 'Test',
        width: 20,
        height: 20,
        baseMaterialId: earth.id,
        terrainStrokes: [
          TerrainStroke(
            materialId: grass.id,
            radius: 3,
            opacity: 1,
            points: const [WorldPoint(10, 10)],
          ),
        ],
      ),
      catalog: catalog,
    );
    expect(
      environmentMaterialAtPoint(controller.document, const WorldPoint(10, 10)),
      grass.id,
    );

    expect(
      controller.resetGroundInArea(const [
        WorldPoint(8, 8),
        WorldPoint(12, 8),
        WorldPoint(12, 12),
        WorldPoint(8, 12),
      ]),
      isTrue,
    );
    expect(
      environmentMaterialAtPoint(controller.document, const WorldPoint(10, 10)),
      earth.id,
    );
    final reset = controller.document.terrainStrokes.last;
    expect(reset.resetsToBase, isTrue);
    expect(reset.radius, 0);
    expect(terrainStrokeStamps(reset), isEmpty);
    controller.undo();
    expect(
      environmentMaterialAtPoint(controller.document, const WorldPoint(10, 10)),
      grass.id,
    );
  });

  test(
    'ground fill, detail reset, clear fill, and default are independent',
    () {
      const polygon = [
        WorldPoint(4, 4),
        WorldPoint(12, 4),
        WorldPoint(12, 12),
        WorldPoint(4, 12),
      ];
      final controller = EditorController(world(), catalog: catalog)
        ..selectMode(EnvironmentEditorMode.fillGround)
        ..selectPaintMaterial(grass);

      expect(controller.fillGroundInArea(polygon), isTrue);
      expect(controller.document.terrainRegions, hasLength(1));
      expect(
        environmentMaterialAtPoint(controller.document, const WorldPoint(8, 8)),
        grass.id,
      );

      controller.document.terrainStrokes.add(
        TerrainStroke(
          materialId: earth.id,
          radius: 2,
          opacity: 1,
          points: const [WorldPoint(8, 8)],
        ),
      );
      expect(controller.resetGroundInArea(polygon), isTrue);
      expect(
        environmentMaterialAtPoint(controller.document, const WorldPoint(8, 8)),
        grass.id,
      );

      expect(controller.clearGroundFillInArea(polygon), isTrue);
      expect(
        environmentMaterialAtPoint(controller.document, const WorldPoint(8, 8)),
        earth.id,
      );
      controller.undo();
      expect(
        environmentMaterialAtPoint(controller.document, const WorldPoint(8, 8)),
        grass.id,
      );

      expect(controller.setDefaultGroundMaterial(grass), isTrue);
      expect(controller.document.baseMaterialId, grass.id);
      controller.undo();
      expect(controller.document.baseMaterialId, earth.id);
    },
  );

  test('ground fills can be selected, rescaled, deleted, and undone', () {
    const polygon = [
      WorldPoint(4, 4),
      WorldPoint(12, 4),
      WorldPoint(12, 12),
      WorldPoint(4, 12),
    ];
    final controller = EditorController(world(), catalog: catalog)
      ..selectMode(EnvironmentEditorMode.fillGround)
      ..selectPaintMaterial(grass);

    expect(controller.fillGroundInArea(polygon), isTrue);
    expect(controller.selectedTerrainRegion?.materialId, grass.id);
    expect(controller.activeFillTextureScale, 1);

    controller
      ..beginTerrainTextureScaleEdit()
      ..setActiveFillTextureScale(0.5)
      ..endTerrainTextureScaleEdit();
    expect(controller.selectedTerrainRegion?.textureScale, 0.5);
    controller.undo();
    expect(controller.selectedTerrainRegion?.textureScale, 1);
    controller.redo();
    expect(controller.selectedTerrainRegion?.textureScale, 0.5);

    controller
      ..clearSelection()
      ..selectMode(EnvironmentEditorMode.editGround)
      ..beginGesture()
      ..applyAt(const WorldPoint(8, 8))
      ..endGesture();
    expect(controller.selectedTerrainRegion, isNotNull);

    controller.deleteSelected();
    expect(controller.document.terrainRegions, isEmpty);
    controller.undo();
    expect(controller.document.terrainRegions, hasLength(1));
  });

  test('ground fills are visual paint bound to the active surface', () {
    const polygon = [
      WorldPoint(4, 4),
      WorldPoint(12, 4),
      WorldPoint(12, 12),
      WorldPoint(4, 12),
    ];
    final controller = EditorController(world(), catalog: catalog)
      ..selectMode(EnvironmentEditorMode.fillGround)
      ..selectPaintMaterial(grass);

    expect(controller.fillGroundInArea(polygon), isTrue);
    expect(
      controller.selectedTerrainRegion?.surfaceId,
      environmentBaseSurfaceId,
    );
    expect(controller.document.surfaces, hasLength(1));
  });

  test('surface polygons create editable physical planes', () {
    final controller = EditorController(world(), catalog: catalog)
      ..selectMode(EnvironmentEditorMode.surfacePolygon)
      ..selectPaintMaterial(grass)
      ..setNewSurfaceElevation(1.5);

    for (final point in const [
      WorldPoint(3, 3),
      WorldPoint(10, 3),
      WorldPoint(12, 8),
      WorldPoint(7, 12),
      WorldPoint(3, 8),
    ]) {
      controller
        ..beginGesture()
        ..applyAt(point)
        ..endGesture();
    }
    expect(controller.finishSurfacePolygon(), isTrue);
    expect(controller.selectedSurface?.points, hasLength(5));
    expect(controller.selectedSurface?.height.elevation, 1.5);
    expect(controller.document.activeSurfaceId, controller.selectedSurface?.id);

    controller.setSelectedSurfaceGeometryOnly(true);
    expect(controller.selectedSurface?.drawsBaseMaterial, isFalse);
    controller.undo();
    expect(controller.selectedSurface?.drawsBaseMaterial, isTrue);
    controller.redo();
    expect(controller.selectedSurface?.drawsBaseMaterial, isFalse);

    controller.selectMode(EnvironmentEditorMode.editGround);
    expect(controller.beginSelectedTerrainPointGesture(2), isTrue);
    controller
      ..moveSelectedTerrainPointDuringGesture(2, const WorldPoint(13, 9))
      ..endGesture();
    expect(controller.selectedSurface?.points[2].x, 13);
    expect(controller.selectedSurface?.points[2].y, 9);
    controller.undo();
    expect(controller.selectedSurface?.points[2].x, 12);
    expect(controller.selectedSurface?.points[2].y, 8);
  });

  test('liquid bathymetry ramp controls and handles are undoable', () {
    final document = world()
      ..liquidVolumes.add(
        EnvironmentLiquidVolume(
          id: 'pond',
          name: 'Pond',
          bedSurfaceId: environmentBaseSurfaceId,
          materialId: grass.id,
          surfaceElevation: 0,
          depth: 2,
          points: const [
            WorldPoint(2, 2),
            WorldPoint(12, 2),
            WorldPoint(12, 12),
            WorldPoint(2, 12),
          ],
        ),
      );
    final controller = EditorController(document, catalog: catalog)
      ..selectMode(EnvironmentEditorMode.editGround)
      ..beginGesture()
      ..applyAt(const WorldPoint(5, 5))
      ..endGesture();

    expect(controller.selectedLiquidVolume?.id, 'pond');
    controller.setSelectedVariableWaterDepth(true);
    expect(controller.selectedLiquidVolume?.hasDepthRamp, isTrue);
    expect(controller.selectedLiquidVolume?.endDepth, closeTo(0.3, 1e-9));

    controller.adjustSelectedWaterEndDepth(-0.1);
    expect(controller.selectedLiquidVolume?.endDepth, closeTo(0.2, 1e-9));
    final startBefore = controller.selectedLiquidVolume!.depthRampStart!;
    controller
      ..beginGesture()
      ..beginSelectedLiquidDepthHandleGesture(0)
      ..moveSelectedLiquidDepthHandleDuringGesture(0, const WorldPoint(3, 6))
      ..endGesture();
    expect(controller.selectedLiquidVolume?.depthRampStart?.x, 3);
    expect(controller.selectedLiquidVolume?.depthRampStart?.y, 6);
    controller.undo();
    expect(controller.selectedLiquidVolume?.depthRampStart?.x, startBefore.x);
    expect(controller.selectedLiquidVolume?.depthRampStart?.y, startBefore.y);
  });

  test('objects and connectors are explicitly bound to physical surfaces', () {
    final raised = EnvironmentSurface(
      id: 'raised',
      name: 'Raised deck',
      materialId: grass.id,
      points: const [
        WorldPoint(4, 4),
        WorldPoint(12, 4),
        WorldPoint(12, 12),
        WorldPoint(4, 12),
      ],
      height: const EnvironmentSurfaceHeight.flat(1.5),
      kind: EnvironmentSurfaceKind.platform,
      order: 1,
    );
    final document = world()
      ..surfaces.add(raised)
      ..activeSurfaceId = raised.id;
    final controller = EditorController(document, catalog: catalog)
      ..selectObjectAsset(tree)
      ..beginGesture()
      ..applyAt(const WorldPoint(8, 8))
      ..endGesture();

    expect(controller.selectedObject?.supportSurfaceId, raised.id);
    controller.setSelectedSupportSurface(environmentBaseSurfaceId);
    expect(
      controller.selectedObject?.supportSurfaceId,
      environmentBaseSurfaceId,
    );
    controller.undo();
    expect(controller.selectedObject?.supportSurfaceId, raised.id);

    controller
      ..selectMode(EnvironmentEditorMode.connector)
      ..setConnectorTargetSurface(environmentBaseSurfaceId)
      ..beginGesture()
      ..applyAt(const WorldPoint(5, 5))
      ..endGesture()
      ..beginGesture()
      ..applyAt(const WorldPoint(3, 3))
      ..endGesture();

    final connector = controller.document.surfaceConnectors.single;
    expect(connector.fromSurfaceId, raised.id);
    expect(connector.toSurfaceId, environmentBaseSurfaceId);
    expect(connector.from, const WorldPoint(5, 5));
    expect(connector.to, const WorldPoint(3, 3));
    controller.undo();
    expect(controller.document.surfaceConnectors, isEmpty);
    controller.redo();
    expect(controller.document.surfaceConnectors, hasLength(1));
  });

  test('overlapping surface depth can be reordered and undone', () {
    const first = [
      WorldPoint(2, 2),
      WorldPoint(8, 2),
      WorldPoint(8, 8),
      WorldPoint(2, 8),
    ];
    const second = [
      WorldPoint(5, 5),
      WorldPoint(11, 5),
      WorldPoint(11, 11),
      WorldPoint(5, 11),
    ];
    final controller = EditorController(world(), catalog: catalog)
      ..selectMode(EnvironmentEditorMode.fillGround)
      ..selectPaintMaterial(grass)
      ..fillGroundInArea(first)
      ..fillGroundInArea(second);

    final selectedId = controller.selectedTerrainRegionId;
    controller.moveSelectedTerrainRegionOrder(-1);
    expect(controller.document.terrainRegions.first.id, selectedId);
    controller.undo();
    expect(controller.document.terrainRegions.last.id, selectedId);
  });

  test('selected objects retain authored liquid interaction and draft', () {
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

    controller
      ..setSelectedLiquidInteraction(EnvironmentLiquidInteraction.float)
      ..adjustSelectedLiquidDraft(0.18);
    expect(
      controller.selectedObject?.liquidInteraction,
      EnvironmentLiquidInteraction.float,
    );
    expect(controller.selectedObject?.liquidDraft, closeTo(0.3, 1e-9));
    controller.undo();
    expect(controller.selectedObject?.liquidDraft, 0.12);
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

    final edited = catalog.geometryForAsset(tree, direction: 'south');
    expect(edited.blocking.single, isA<EnvironmentEllipse>());
    expect(catalog.geometryOverrides, contains(tree.id));

    controller.undo();
    expect(catalog.geometryOverrides, isNot(contains(tree.id)));
    controller.redo();
    expect(
      catalog.geometryForAsset(tree, direction: 'south').blocking,
      hasLength(1),
    );

    controller
      ..selectGeometryRole(GeometryRole.selection)
      ..addGeometryShape(GeometryShapeType.polygon);
    expect(
      catalog.geometryForAsset(tree, direction: 'south').selection,
      hasLength(1),
    );
    controller.undo();
    expect(
      catalog.geometryForAsset(tree, direction: 'south').selection,
      isEmpty,
    );
  });

  test('multi-view asset geometry is edited independently per direction', () {
    const fence = EnvironmentObjectAsset(
      id: 'directional_fence',
      name: 'Directional Fence',
      category: 'Fences',
      viewMode: EnvironmentAssetViewMode.fourWay,
      renderScale: 1,
      views: {
        'south': EnvironmentObjectView(imagePath: 'fence_s.png'),
        'west': EnvironmentObjectView(imagePath: 'fence_w.png'),
        'east': EnvironmentObjectView(imagePath: 'fence_e.png'),
        'north': EnvironmentObjectView(imagePath: 'fence_n.png'),
      },
    );
    final localCatalog = EnvironmentCatalog(
      materials: [earth],
      objects: [fence],
    );
    final controller = EditorController(
      EnvironmentDocument(
        id: 'geometry-directions',
        name: 'Geometry directions',
        width: 20,
        height: 20,
        baseMaterialId: earth.id,
        objects: [
          PlacedEnvironmentObject(id: 'fence_1', assetId: fence.id, x: 5, y: 5),
        ],
      ),
      catalog: localCatalog,
    )..selectObjectIds(['fence_1']);

    controller.addGeometryShape(GeometryShapeType.capsule);
    expect(controller.selectedGeometryHasViewOverride, isTrue);
    expect(
      localCatalog.geometryForAsset(fence, direction: 'south').blocking,
      hasLength(1),
    );
    expect(
      localCatalog.geometryForAsset(fence, direction: 'west').blocking,
      isEmpty,
    );

    controller
      ..setSelectedDirection(EnvironmentDirection.west)
      ..addGeometryShape(GeometryShapeType.rectangle);
    expect(
      localCatalog.geometryForAsset(fence, direction: 'south').blocking.single,
      isA<EnvironmentCapsule>(),
    );
    expect(
      localCatalog.geometryForAsset(fence, direction: 'west').blocking.single,
      isA<EnvironmentRectangle>(),
    );

    controller.resetSelectedGeometryViewOverride();
    expect(
      localCatalog.geometryForAsset(fence, direction: 'west').blocking,
      isEmpty,
    );
    expect(
      localCatalog.geometryForAsset(fence, direction: 'south').blocking,
      hasLength(1),
    );
  });

  test('multiple footprints can seed independent blockers with undo', () {
    const building = EnvironmentObjectAsset(
      id: 'building',
      name: 'Building',
      category: 'Buildings',
      renderScale: 1,
      views: {'south': EnvironmentObjectView(imagePath: 'building.png')},
      geometry: EnvironmentAssetGeometry(
        footprints: [
          EnvironmentRectangle(
            center: EnvironmentGeometryPoint(0, 0),
            size: EnvironmentGeometryPoint(4, 2),
          ),
        ],
      ),
    );
    final localCatalog = EnvironmentCatalog(
      materials: [earth],
      objects: [building],
    );
    final controller = EditorController(
      EnvironmentDocument(
        id: 'geometry',
        name: 'Geometry',
        width: 20,
        height: 20,
        baseMaterialId: earth.id,
        objects: [
          PlacedEnvironmentObject(
            id: 'building_1',
            assetId: building.id,
            x: 5,
            y: 5,
          ),
        ],
      ),
      catalog: localCatalog,
    )..selectObjectIds(['building_1']);

    controller
      ..selectGeometryRole(GeometryRole.footprint)
      ..addGeometryShape(GeometryShapeType.circle)
      ..replaceBlockingWithFootprint();

    final edited = localCatalog.geometryForObjectId(building.id)!;
    expect(edited.footprints, hasLength(2));
    expect(edited.footprints.first, isA<EnvironmentRectangle>());
    expect(edited.footprints.last, isA<EnvironmentCircle>());
    expect(edited.blocking, hasLength(2));
    expect(edited.blocking, orderedEquals(edited.footprints));

    controller.undo();
    expect(localCatalog.geometryForObjectId(building.id)?.blocking, isEmpty);
    expect(
      localCatalog.geometryForObjectId(building.id)?.footprints.first,
      isA<EnvironmentRectangle>(),
    );
    expect(
      localCatalog.geometryForObjectId(building.id)?.footprints,
      hasLength(2),
    );
    controller.redo();
    expect(
      localCatalog.geometryForObjectId(building.id)?.blocking,
      hasLength(2),
    );
  });

  test('polygon vertex drag is one undoable geometry gesture', () {
    const building = EnvironmentObjectAsset(
      id: 'polygon_building',
      name: 'Polygon building',
      category: 'Buildings',
      renderScale: 1,
      views: {'south': EnvironmentObjectView(imagePath: 'building.png')},
      geometry: EnvironmentAssetGeometry(
        footprints: [
          EnvironmentPolygon(
            points: [
              EnvironmentGeometryPoint(-1, -1),
              EnvironmentGeometryPoint(1, -1),
              EnvironmentGeometryPoint(0, 1),
            ],
          ),
        ],
      ),
    );
    final localCatalog = EnvironmentCatalog(
      materials: [earth],
      objects: [building],
    );
    final controller =
        EditorController(
            EnvironmentDocument(
              id: 'geometry',
              name: 'Geometry',
              width: 20,
              height: 20,
              baseMaterialId: earth.id,
              objects: [
                PlacedEnvironmentObject(
                  id: 'building_1',
                  assetId: building.id,
                  x: 5,
                  y: 6,
                ),
              ],
            ),
            catalog: localCatalog,
          )
          ..selectObjectIds(['building_1'])
          ..selectMode(EnvironmentEditorMode.collision)
          ..selectGeometryRole(GeometryRole.footprint)
          ..beginGesture();

    expect(controller.beginSelectedPolygonVertexGesture(), isTrue);
    controller
      ..moveSelectedPolygonVertexDuringGesture(0, const WorldPoint(4.25, 5.5))
      ..endGesture();

    final edited = localCatalog
        .geometryForObjectId(building.id)!
        .footprints
        .single;
    expect(edited, isA<EnvironmentPolygon>());
    expect(
      (edited as EnvironmentPolygon).points.first.x,
      closeTo(-0.75, 0.0001),
    );
    expect(edited.points.first.y, closeTo(-0.5, 0.0001));

    controller.undo();
    final restored =
        localCatalog.geometryForObjectId(building.id)!.footprints.single
            as EnvironmentPolygon;
    expect(restored.points.first.x, -1);
    expect(restored.points.first.y, -1);
  });

  test('direct handles move and resize primitive geometry', () {
    const asset = EnvironmentObjectAsset(
      id: 'primitive_geometry',
      name: 'Primitive geometry',
      category: 'Test',
      renderScale: 1,
      views: {'south': EnvironmentObjectView(imagePath: 'test.png')},
      geometry: EnvironmentAssetGeometry(
        blocking: [
          EnvironmentCircle(
            center: EnvironmentGeometryPoint(0, 0),
            radius: 0.2,
          ),
          EnvironmentEllipse(
            center: EnvironmentGeometryPoint(0, 0),
            radius: EnvironmentGeometryPoint(0.3, 0.2),
          ),
          EnvironmentRectangle(
            center: EnvironmentGeometryPoint(0, 0),
            size: EnvironmentGeometryPoint(1, 0.5),
          ),
          EnvironmentCapsule(
            start: EnvironmentGeometryPoint(-0.5, 0),
            end: EnvironmentGeometryPoint(0.5, 0),
            radius: 0.1,
          ),
        ],
      ),
    );
    final localCatalog = EnvironmentCatalog(
      materials: [earth],
      objects: [asset],
    );
    final controller =
        EditorController(
            EnvironmentDocument(
              id: 'primitive-handles',
              name: 'Primitive handles',
              width: 20,
              height: 20,
              baseMaterialId: earth.id,
              objects: [
                PlacedEnvironmentObject(
                  id: 'primitive_1',
                  assetId: asset.id,
                  x: 5,
                  y: 5,
                ),
              ],
            ),
            catalog: localCatalog,
          )
          ..selectObjectIds(['primitive_1'])
          ..selectMode(EnvironmentEditorMode.collision);

    void drag(EnvironmentGeometryHandle handle, WorldPoint point) {
      controller.beginGesture();
      expect(controller.beginSelectedGeometryHandleGesture(handle), isTrue);
      controller
        ..moveSelectedGeometryHandleDuringGesture(handle, point)
        ..endGesture();
    }

    drag(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.center),
      const WorldPoint(5.25, 5.1),
    );
    drag(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.radius),
      const WorldPoint(5.75, 5.1),
    );
    var geometry = localCatalog.geometryForObjectId(asset.id)!;
    final circle = geometry.blocking[0] as EnvironmentCircle;
    expect(circle.center.x, closeTo(0.25, 0.0001));
    expect(circle.radius, closeTo(0.5, 0.0001));

    controller.selectGeometryShapeIndex(1);
    drag(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.radiusX),
      const WorldPoint(5.8, 5),
    );
    geometry = localCatalog.geometryForObjectId(asset.id)!;
    expect(
      (geometry.blocking[1] as EnvironmentEllipse).radius.x,
      closeTo(0.8, 0.0001),
    );

    controller.selectGeometryShapeIndex(2);
    drag(
      const EnvironmentGeometryHandle(
        EnvironmentGeometryHandleType.rectangleCorner,
      ),
      const WorldPoint(5.75, 5.5),
    );
    drag(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.rotation),
      const WorldPoint(6, 5),
    );
    geometry = localCatalog.geometryForObjectId(asset.id)!;
    final rectangle = geometry.blocking[2] as EnvironmentRectangle;
    expect(rectangle.size.x, closeTo(1.5, 0.0001));
    expect(rectangle.size.y, closeTo(1, 0.0001));
    expect(rectangle.rotationDegrees, closeTo(90, 0.0001));

    controller.selectGeometryShapeIndex(3);
    drag(
      const EnvironmentGeometryHandle(EnvironmentGeometryHandleType.capsuleEnd),
      const WorldPoint(6, 5),
    );
    drag(
      const EnvironmentGeometryHandle(
        EnvironmentGeometryHandleType.capsuleRadius,
      ),
      const WorldPoint(5, 5.3),
    );
    geometry = localCatalog.geometryForObjectId(asset.id)!;
    final capsule = geometry.blocking[3] as EnvironmentCapsule;
    expect(capsule.end.x, closeTo(1, 0.0001));
    expect(capsule.radius, closeTo(0.3, 0.0001));
  });
}
