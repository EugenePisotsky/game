import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neura_editor/main.dart';
import 'package:neura_assets/neura_assets.dart';

void main() {
  testWidgets('shows the editor workspace', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = await rootBundle.loadString(
      'packages/neura_assets/assets/worlds/starter_world.json',
    );
    final catalogSource = await rootBundle.loadString(
      'packages/neura_assets/assets/catalogs/ground_catalog.json',
    );
    final generatedCatalog = GroundCatalog.fromJsonString(catalogSource);
    expect(generatedCatalog.items, hasLength(112));

    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          starterSource: source,
          groundCatalog: const GroundCatalog(collections: [], items: []),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('NEURA WORLD EDITOR'), findsOneWidget);
    expect(find.text('PALETTE'), findsOneWidget);
    expect(find.text('Starter Meadow'), findsOneWidget);
  });
}
