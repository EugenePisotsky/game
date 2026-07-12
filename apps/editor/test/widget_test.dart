import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_editor/main.dart';

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
}
