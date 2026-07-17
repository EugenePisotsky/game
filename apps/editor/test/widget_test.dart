import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_editor/editor_controller.dart';
import 'package:neura_editor/main.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  testWidgets('shows the environment designer workspace', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = environmentStarterDocumentFile().readAsStringSync();
    final catalogSource = environmentCatalogFile().readAsStringSync();
    final fullCatalog = EnvironmentCatalog.fromJsonString(catalogSource);
    final catalog = EnvironmentCatalog(
      materials: [
        fullCatalog.materialById('ow3.ground.earth')!,
        fullCatalog.materialById('ow3.ground.meadow')!,
      ],
      objects: [
        fullCatalog.objectById('ow3.tree.blossom')!,
        fullCatalog.objectById('ow3.fence.wood')!,
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          starterSource: source,
          catalog: catalog,
          renderGame: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('NEURA ENVIRONMENT DESIGNER'), findsOneWidget);
    expect(find.text('GROUND'), findsNothing);
    await tester.tap(find.byTooltip('Add asset palette to widget tree'));
    await tester.pumpAndSettle();
    expect(find.text('GROUND'), findsOneWidget);
    expect(find.text('OBJECTS'), findsOneWidget);
    expect(find.text('Environment Study'), findsOneWidget);
    expect(find.text('Worn earth'), findsOneWidget);
    final search = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == 'Search assets',
    );
    await tester.tap(search);
    await tester.enterText(search, 'tree');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(tester.widget<TextField>(search).controller?.text, 'tre');
    await tester.enterText(search, '');
    await tester.pump();
    await tester.tap(find.text('OBJECTS'));
    await tester.pumpAndSettle();
    expect(find.text('Blossoming tree'), findsOneWidget);
    expect(find.text('All (2)'), findsOneWidget);
    await tester.tap(find.text('All (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Structures (1)').last);
    await tester.pumpAndSettle();
    expect(find.text('Wooden fence'), findsOneWidget);
    expect(find.text('Blossoming tree'), findsNothing);
    await tester.tap(find.text('Path'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Piece '), findsOneWidget);
    expect(find.textContaining('Gap '), findsOneWidget);
    expect(find.textContaining('Opening '), findsOneWidget);
    expect(find.textContaining('Rotate orientation'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('canvas delete, undo, and redo shortcuts edit the world', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalog = EnvironmentCatalog(
      materials: const [
        EnvironmentMaterial(
          id: 'earth',
          name: 'Earth',
          texturePath: 'earth.png',
          decalPath: 'earth_decal.png',
        ),
      ],
      objects: const [
        EnvironmentObjectAsset(
          id: 'tree',
          name: 'Tree',
          category: 'Trees',
          renderScale: 1,
          views: {'south': EnvironmentObjectView(imagePath: 'tree.png')},
        ),
      ],
    );
    final document = EnvironmentDocument(
      id: 'shortcuts',
      name: 'Shortcuts',
      width: 10,
      height: 10,
      baseMaterialId: 'earth',
      objects: [
        PlacedEnvironmentObject(id: 'tree_1', assetId: 'tree', x: 2, y: 2),
      ],
    );
    final controller = EditorController(document, catalog: catalog)
      ..selectObjectIds(['tree_1']);

    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          starterSource: document.toJsonString(),
          catalog: catalog,
          controllerOverride: controller,
          renderGame: false,
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(controller.document.objects, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(controller.document.objects, hasLength(1));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(controller.document.objects, isEmpty);
  });

  testWidgets('arrow keys nudge selection and command-P pastes a copy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalog = EnvironmentCatalog(
      materials: const [
        EnvironmentMaterial(
          id: 'earth',
          name: 'Earth',
          texturePath: 'earth.png',
          decalPath: 'earth_decal.png',
        ),
      ],
      objects: const [
        EnvironmentObjectAsset(
          id: 'tree',
          name: 'Tree',
          category: 'Trees',
          renderScale: 1,
          views: {'south': EnvironmentObjectView(imagePath: 'tree.png')},
        ),
      ],
    );
    final document = EnvironmentDocument(
      id: 'shortcuts',
      name: 'Shortcuts',
      width: 10,
      height: 10,
      baseMaterialId: 'earth',
      objects: [
        PlacedEnvironmentObject(id: 'tree_1', assetId: 'tree', x: 2, y: 2),
      ],
    );
    final controller = EditorController(document, catalog: catalog)
      ..selectObjectIds(['tree_1']);
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          starterSource: document.toJsonString(),
          catalog: catalog,
          controllerOverride: controller,
          renderGame: false,
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(controller.document.objects.single.x, 2.25);
    expect(controller.document.objects.single.y, 1.75);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.document.objects, hasLength(2));
    expect(controller.selectedObjectIds, hasLength(1));
  });

  testWidgets('edits selected asset collision geometry', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalogSource = environmentCatalogFile().readAsStringSync();
    final catalog = EnvironmentCatalog.fromJsonString(catalogSource);
    final document = EnvironmentDocument(
      id: 'geometry_test',
      name: 'Geometry Test',
      width: 10,
      height: 10,
      baseMaterialId: 'ow3.ground.earth',
      objects: [
        PlacedEnvironmentObject(
          id: 'tree_1',
          assetId: 'ow3.tree.006',
          x: 5,
          y: 5,
        ),
      ],
    );
    final controller = EditorController(document, catalog: catalog)
      ..selectObjectIds(['tree_1'])
      ..selectMode(EnvironmentEditorMode.collision);

    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          starterSource: document.toJsonString(),
          catalog: catalog,
          controllerOverride: controller,
          renderGame: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ASSET GEOMETRY'), findsOneWidget);
    expect(find.text('Radius X'), findsOneWidget);
    final before =
        (controller.selectedGeometryShape! as EnvironmentEllipse).radius.x;
    final row = find.ancestor(
      of: find.text('Radius X'),
      matching: find.byType(Row),
    );
    await tester.tap(
      find.descendant(of: row.first, matching: find.byIcon(Icons.add)),
    );
    await tester.pump();

    final after =
        (controller.selectedGeometryShape! as EnvironmentEllipse).radius.x;
    expect(after, greaterThan(before));
    expect(catalog.geometryOverrides, contains('ow3.tree.006'));
  });
}
