import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:neura_world/neura_world.dart';

const environmentWorldManifestAsset =
    'packages/neura_assets/assets/worlds/environment_world.json';
const environmentWorldChunksAssetPrefix =
    'packages/neura_assets/assets/worlds/chunks';
const environmentReleaseAssetPrefix = 'packages/neura_assets/assets/release';
const environmentReleaseCatalogAsset =
    '$environmentReleaseAssetPrefix/catalog.json';
const environmentReleaseGeometryOverridesAsset =
    '$environmentReleaseAssetPrefix/geometry_overrides.json';
const environmentReleaseWorldManifestAsset =
    '$environmentReleaseAssetPrefix/world.json';
const environmentReleaseChunksAssetPrefix =
    '$environmentReleaseAssetPrefix/chunks';

Future<EnvironmentWorldManifest> loadEnvironmentWorldManifest(
  AssetBundle bundle,
) async => EnvironmentWorldManifest.fromJsonString(
  await bundle.loadString(environmentWorldManifestAsset),
);

Future<EnvironmentWorldManifest> loadReleaseEnvironmentWorldManifest(
  AssetBundle bundle,
) async => EnvironmentWorldManifest.fromJsonString(
  await bundle.loadString(environmentReleaseWorldManifestAsset),
);

Future<ui.Image> loadReleaseEnvironmentImage(
  AssetBundle bundle,
  String releasePath,
) async {
  if (!releasePath.startsWith('images/')) {
    throw ArgumentError.value(releasePath, 'releasePath');
  }
  final data = await bundle.load('$environmentReleaseAssetPrefix/$releasePath');
  final bytes = Uint8List.view(
    data.buffer,
    data.offsetInBytes,
    data.lengthInBytes,
  );
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

class AssetBundleEnvironmentChunkRepository
    implements EnvironmentChunkRepository {
  const AssetBundleEnvironmentChunkRepository(
    this.bundle, {
    this.prefix = environmentWorldChunksAssetPrefix,
  });

  final AssetBundle bundle;
  final String prefix;

  const AssetBundleEnvironmentChunkRepository.release(AssetBundle bundle)
    : this(bundle, prefix: environmentReleaseChunksAssetPrefix);

  @override
  Future<EnvironmentChunkDocument> load(
    EnvironmentChunkCoordinate coordinate,
  ) async => EnvironmentChunkDocument.fromJsonString(
    await bundle.loadString('$prefix/${coordinate.key}.json'),
  );
}
