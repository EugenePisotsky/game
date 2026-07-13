import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'release world resolves every referenced asset from its own bundle',
    () async {
      final manifest = await loadReleaseEnvironmentWorldManifest(rootBundle);
      final repository = AssetBundleEnvironmentChunkRepository.release(
        rootBundle,
      );
      final catalog =
          EnvironmentCatalog.fromJsonString(
            await rootBundle.loadString(environmentReleaseCatalogAsset),
          )..applyGeometryOverridesFromJsonString(
            await rootBundle.loadString(
              environmentReleaseGeometryOverridesAsset,
            ),
          );
      final materialIds = <String>{manifest.baseMaterialId};
      final objectIds = <String>{};
      for (final coordinate in manifest.chunks) {
        final chunk = await repository.load(coordinate);
        materialIds.addAll(
          chunk.terrainStrokes.map((stroke) => stroke.materialId),
        );
        objectIds.addAll(chunk.objects.map((object) => object.assetId));
      }

      expect(
        materialIds.every((id) => catalog.materialById(id) != null),
        isTrue,
      );
      expect(objectIds.every((id) => catalog.objectById(id) != null), isTrue);

      final imagePaths = <String>{
        for (final material in catalog.materials) ...[
          material.texturePath,
          material.decalPath,
        ],
        for (final object in catalog.objects)
          for (final view in object.views.values) view.imagePath,
      };
      expect(imagePaths, isNotEmpty);
      expect(imagePaths.every((path) => path.startsWith('images/')), isTrue);
      for (final path in imagePaths) {
        final image = await loadReleaseEnvironmentImage(rootBundle, path);
        expect(image.width, greaterThan(0), reason: path);
        expect(image.height, greaterThan(0), reason: path);
        image.dispose();
      }
    },
  );

  test('Flutter bundle excludes editor-only environment families', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final packageAssets = manifest
        .listAssets()
        .where(
          (path) =>
              path.startsWith('packages/neura_assets/assets/') ||
              path.startsWith('assets/'),
        )
        .map((path) => path.replaceFirst('packages/neura_assets/', ''))
        .toList();
    expect(packageAssets, isNotEmpty);
    expect(
      packageAssets.every(
        (path) =>
            path.startsWith('assets/release/') ||
            path.startsWith('assets/images/characters/') ||
            path.startsWith('assets/debug_scenes/') ||
            path == 'assets/catalogs/character_catalog.json',
      ),
      isTrue,
      reason: 'The editor source library must not leak into runtime bundles.',
    );
  });

  test('named debug scenes resolve against the exported world', () async {
    final manifest = await loadReleaseEnvironmentWorldManifest(rootBundle);
    final repository = AssetBundleEnvironmentChunkRepository.release(
      rootBundle,
    );
    final objectIds = <String>{};
    for (final coordinate in manifest.chunks) {
      final chunk = await repository.load(coordinate);
      objectIds.addAll(chunk.objects.map((object) => object.id));
    }
    for (final name in environmentDebugSceneNames) {
      final scene = await loadEnvironmentDebugScene(rootBundle, name);
      expect(scene.id, name);
      expect(scene.viewportWidth, greaterThan(0));
      expect(scene.viewportHeight, greaterThan(0));
      expect(
        scene.relevantObjectIds.every(objectIds.contains),
        isTrue,
        reason: name,
      );
      final streamer = EnvironmentChunkStreamingManager(
        manifest: manifest,
        repository: repository,
        loadRadius: 1,
        unloadRadius: 2,
      );
      await streamer.updateAround(scene.player);
      expect(
        streamer.loadedChunks.keys.toSet(),
        scene.expectedLoadedChunks.toSet(),
        reason: name,
      );
    }
  });
}
