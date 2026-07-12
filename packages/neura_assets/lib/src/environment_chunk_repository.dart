import 'package:flutter/services.dart';
import 'package:neura_world/neura_world.dart';

const environmentWorldManifestAsset =
    'packages/neura_assets/assets/worlds/environment_world.json';
const environmentWorldChunksAssetPrefix =
    'packages/neura_assets/assets/worlds/chunks';

Future<EnvironmentWorldManifest> loadEnvironmentWorldManifest(
  AssetBundle bundle,
) async => EnvironmentWorldManifest.fromJsonString(
  await bundle.loadString(environmentWorldManifestAsset),
);

class AssetBundleEnvironmentChunkRepository
    implements EnvironmentChunkRepository {
  const AssetBundleEnvironmentChunkRepository(
    this.bundle, {
    this.prefix = environmentWorldChunksAssetPrefix,
  });

  final AssetBundle bundle;
  final String prefix;

  @override
  Future<EnvironmentChunkDocument> load(
    EnvironmentChunkCoordinate coordinate,
  ) async => EnvironmentChunkDocument.fromJsonString(
    await bundle.loadString('$prefix/${coordinate.key}.json'),
  );
}
