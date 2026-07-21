import 'dart:typed_data';
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

  testWithGame<EditorGame>(
    'pointer projection follows a raised visible surface',
    () => EditorGame(
      EditorController(
        EnvironmentDocument(
          id: 'raised_surface_fixture',
          name: 'Raised surface fixture',
          width: 10,
          height: 10,
          baseMaterialId: 'ow3.ground.meadow',
          surfaces: [
            EnvironmentSurface(
              id: environmentBaseSurfaceId,
              name: 'Ground',
              materialId: 'ow3.ground.meadow',
              points: const [
                WorldPoint(0, 0),
                WorldPoint(10, 0),
                WorldPoint(10, 10),
                WorldPoint(0, 10),
              ],
            ),
            EnvironmentSurface(
              id: 'platform',
              name: 'Platform',
              materialId: 'ow3.ground.earth',
              height: const EnvironmentSurfaceHeight.flat(1),
              order: 1,
              points: const [
                WorldPoint(2, 2),
                WorldPoint(8, 2),
                WorldPoint(8, 8),
                WorldPoint(2, 8),
              ],
            ),
          ],
        ),
        catalog: catalog,
      ),
    ),
    (game) async {
      final raisedCenter = game.worldAtScreen(Vector2(400, 300 - 64 * 0.42));
      expect(raisedCenter?.x, closeTo(5, 0.0001));
      expect(raisedCenter?.y, closeTo(5, 0.0001));
      game.controller.dispose();
    },
  );

  testWithGame<EditorGame>(
    'soft polygon surface does not reveal its rectangular texture quad',
    () => EditorGame(
      EditorController(
        EnvironmentDocument(
          id: 'soft_polygon_fixture',
          name: 'Soft polygon fixture',
          width: 10,
          height: 10,
          baseMaterialId: 'ow3.ground.meadow',
          terrainRegions: [
            TerrainRegion(
              id: 'water',
              materialId: 'ow3.water.001',
              opacity: 0.8,
              edgeBlend: 0.35,
              points: const [
                WorldPoint(2, 2),
                WorldPoint(8, 2),
                WorldPoint(2, 8),
              ],
            ),
          ],
        ),
        catalog: catalog,
      ),
    ),
    (game) async {
      game.showDiagnostics = false;
      final withSurface = await _renderGameBytes(game);
      game.controller.replaceDocument(
        EnvironmentDocument(
          id: 'soft_polygon_fixture',
          name: 'Soft polygon fixture',
          width: 10,
          height: 10,
          baseMaterialId: 'ow3.ground.meadow',
        ),
      );
      final withoutSurface = await _renderGameBytes(game);

      final outside = _screenForWorld(game, const WorldPoint(7, 7));
      final inside = _screenForWorld(game, const WorldPoint(3, 3));
      expect(_pixelAt(withSurface, outside), _pixelAt(withoutSurface, outside));
      expect(
        _pixelAt(withSurface, inside),
        isNot(_pixelAt(withoutSurface, inside)),
      );
      game.controller.dispose();
    },
  );

  final largeDocument = EnvironmentDocument(
    id: 'editor_culling_fixture',
    name: 'Editor Culling Fixture',
    width: 1000,
    height: 1000,
    baseMaterialId: 'ow3.ground.meadow',
    objects: [
      PlacedEnvironmentObject(
        id: 'near_tree',
        assetId: 'ow3.tree.006',
        x: 5,
        y: 5,
      ),
      PlacedEnvironmentObject(
        id: 'far_tree',
        assetId: 'ow3.tree.006',
        x: 900,
        y: 900,
      ),
    ],
  );

  testWithGame<EditorGame>(
    'culls off-screen objects and hit-tests only the local spatial bucket',
    () => EditorGame(
      EditorController(
        EnvironmentDocument.fromJson(largeDocument.toJson()),
        catalog: catalog,
      ),
      initialWorldCenter: const WorldPoint(5, 5),
    ),
    (game) async {
      final recorder = ui.PictureRecorder();
      game.render(ui.Canvas(recorder));
      recorder.endRecording().dispose();

      expect(game.renderCandidateCount, 2);
      expect(game.visibleSpriteCount, 1);
      expect(game.culledSpriteCount, 1);
      expect(game.hitTestObjectIds(Vector2(400, 280)), contains('near_tree'));
      expect(game.lastHitTestCandidateCount, 1);

      final fullRebuilds = game.renderIndexFullRebuildCount;
      game.controller
        ..selectObjectIds(['near_tree'])
        ..beginGesture()
        ..moveSelectionDuringGesture(
          const WorldPoint(5, 5),
          const WorldPoint(6, 6),
        );
      final movedRecorder = ui.PictureRecorder();
      game.render(ui.Canvas(movedRecorder));
      movedRecorder.endRecording().dispose();
      expect(game.renderIndexFullRebuildCount, fullRebuilds);
      expect(game.renderIndexIncrementalUpdateCount, 1);
      game.controller.endGesture();
      game.controller.dispose();
    },
  );

  testWithGame<EditorGame>(
    'sleeps when static and wakes when a frame is invalidated',
    () => EditorGame(
      EditorController(
        EnvironmentDocument.fromJson(document.toJson()),
        catalog: catalog,
      ),
    ),
    (game) async {
      for (var index = 0; index < 6; index++) {
        game.update(1 / 60);
      }
      expect(game.isAutoIdle, isTrue);
      expect(game.paused, isTrue);

      game.requestFrame();
      expect(game.isAutoIdle, isFalse);
      expect(game.paused, isFalse);
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
      expect(game.terrainRasterBytes, 16 * (1 << 20));
      expect(game.highResolutionTerrainRasterCount, 1);

      game.zoomBy(0.5);
      for (
        var attempt = 0;
        attempt < 40 && game.terrainRasterBytes != 4 * (1 << 20);
        attempt++
      ) {
        renderFrame();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(game.terrainRasterBytes, 4 * (1 << 20));
      expect(game.highResolutionTerrainRasterCount, 0);

      game.zoomBy(4);
      expect(game.usesDirectTerrainRendering, isTrue);
      renderFrame();

      loadedChunks.clear();
      renderFrame();
      expect(game.terrainPictureCount, 0);
      game.controller.dispose();
    },
  );
}

Future<Uint8List> _renderGameBytes(EditorGame game) async {
  final recorder = ui.PictureRecorder();
  game.render(ui.Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(800, 600);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List();
}

Vector2 _screenForWorld(EditorGame game, WorldPoint point) {
  const projection = IsometricProjection();
  final center = projection.worldToScreen(Vector2(5, 5));
  final projected = projection.worldToScreen(Vector2(point.x, point.y));
  return (projected - center) * game.zoom + Vector2(400, 300);
}

List<int> _pixelAt(Uint8List bytes, Vector2 point) {
  final offset = (point.y.round() * 800 + point.x.round()) * 4;
  return bytes.sublist(offset, offset + 4);
}
