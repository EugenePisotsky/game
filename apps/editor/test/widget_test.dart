import 'dart:convert';

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
    final source = await rootBundle.loadString(
      'packages/neura_assets/assets/worlds/environment_starter.json',
    );
    final catalogData = await rootBundle.load(
      'packages/neura_assets/assets/catalogs/environment_catalog.json',
    );
    final catalogSource = utf8.decode(
      catalogData.buffer.asUint8List(
        catalogData.offsetInBytes,
        catalogData.lengthInBytes,
      ),
    );
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
    expect(find.text('GROUND'), findsOneWidget);
    expect(find.text('OBJECTS'), findsOneWidget);
    expect(find.text('Environment Study'), findsOneWidget);
    expect(find.text('Worn earth'), findsOneWidget);
    await tester.tap(find.text('OBJECTS'));
    await tester.pumpAndSettle();
    expect(find.text('Blossoming tree'), findsOneWidget);
  });

  testWidgets('edits selected asset collision geometry', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalogData = await rootBundle.load(
      'packages/neura_assets/assets/catalogs/environment_catalog.json',
    );
    final catalogSource = utf8.decode(
      catalogData.buffer.asUint8List(
        catalogData.offsetInBytes,
        catalogData.lengthInBytes,
      ),
    );
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
