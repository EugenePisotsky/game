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

  final streamedDocument = EnvironmentDocument(
    id: 'editor_raster_fixture',
    name: 'Editor Raster Fixture',
    width: 32,
    height: 32,
    baseMaterialId: 'ow3.ground.meadow',
    terrainStrokes: [
      TerrainStroke(
        materialId: 'ow3.ground.earth',
        radius: 2,
        opacity: 0.4,
        points: const [WorldPoint(5, 5), WorldPoint(8, 8)],
      ),
    ],
  );
  final loadedChunks = <EnvironmentChunkCoordinate>{
    const EnvironmentChunkCoordinate(0, 0),
  };

  testWithGame<EditorGame>(
    'flattens loaded chunk terrain into a bounded raster and evicts it',
    () => EditorGame(
      EditorController(
        EnvironmentDocument.fromJson(streamedDocument.toJson()),
        catalog: catalog,
      ),
      loadedChunks: () => loadedChunks,
    ),
    (game) async {
      void renderFrame() {
        final recorder = ui.PictureRecorder();
        game.render(ui.Canvas(recorder));
        recorder.endRecording().dispose();
      }

      for (
        var attempt = 0;
        attempt < 20 && game.terrainRasterCount == 0;
        attempt++
      ) {
        renderFrame();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(game.terrainRasterCount, 1);
      expect(game.terrainRasterBytes, 4 * (1 << 20));

      loadedChunks.clear();
      renderFrame();
      expect(game.terrainPictureCount, 0);
      game.controller.dispose();
    },
  );
}
