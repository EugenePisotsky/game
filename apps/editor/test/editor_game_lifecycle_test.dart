import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_editor/editor_controller.dart';
import 'package:neura_editor/editor_game.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final catalog = EnvironmentCatalog.fromJsonString(
    environmentCatalogFile().readAsStringSync(),
  );
  final document = EnvironmentDocument(
    id: 'editor_flame_fixture',
    name: 'Editor Flame Fixture',
    width: 10,
    height: 10,
    baseMaterialId: 'ow3.ground.meadow',
    objects: [
      PlacedEnvironmentObject(id: 'tree', assetId: 'ow3.tree.006', x: 5, y: 5),
    ],
  );

  testWithGame<EditorGame>(
    'loads a fixed viewport and preserves click-to-world projection',
    () => EditorGame(
      EditorController(
        EnvironmentDocument.fromJson(document.toJson()),
        catalog: catalog,
      ),
    ),
    (game) async {
      expect(game.isLoaded, isTrue);
      expect(game.size, closeToVector(Vector2(800, 600)));
      final center = game.worldAtScreen(Vector2(400, 300));
      expect(center?.x, closeTo(5, 0.0001));
      expect(center?.y, closeTo(5, 0.0001));
      expect(game.decodedImageCount, 5);
      expect(game.pendingImageCount, 0);
      expect(game.hitTestObjectIds(Vector2(400, 280)), contains('tree'));
      expect(
        game.objectIdsInMarquee(const ui.Rect.fromLTWH(300, 100, 200, 220)),
        contains('tree'),
      );
      game.controller.dispose();
    },
  );
}
