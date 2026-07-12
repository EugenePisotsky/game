import 'dart:io';
import 'dart:ui' as ui;

import 'package:neura_world/neura_world.dart';

Directory? _cachedRepositoryRoot;

Directory repositoryRootForNeuraAssets() {
  final cached = _cachedRepositoryRoot;
  if (cached != null) return cached;
  final startingDirectories = <Directory>{
    Directory.current.absolute,
    File(Platform.resolvedExecutable).parent.absolute,
  };
  for (final start in startingDirectories) {
    var directory = start;
    while (true) {
      if (Directory('${directory.path}/packages/neura_assets').existsSync()) {
        _cachedRepositoryRoot = directory;
        return directory;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
  }
  throw FileSystemException(
    'Could not locate the Neura repository from ${Directory.current.path}',
  );
}

/// Resolves an imported source-library image without decoding it.
File generatedEnvironmentFile(String imagePath) {
  if (!imagePath.startsWith('environment_generated/')) {
    throw ArgumentError.value(imagePath, 'imagePath');
  }
  final cached = _cachedRepositoryRoot;
  if (cached != null) {
    final candidate = File(
      '${cached.path}/packages/neura_assets/assets/images/$imagePath',
    );
    if (candidate.existsSync()) return candidate;
    _cachedRepositoryRoot = null;
  }

  final candidate = File(
    '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/images/$imagePath',
  );
  if (candidate.existsSync()) return candidate;
  throw FileSystemException(
    'Generated environment image does not exist',
    candidate.path,
  );
}

File environmentGeometryOverridesFile() => File(
  '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/catalogs/environment_geometry_overrides.json',
);

Future<void> saveEnvironmentGeometryOverrides(String source) =>
    environmentGeometryOverridesFile().writeAsString('$source\n', flush: true);

Future<void> saveEnvironmentChunkDocument(
  EnvironmentChunkDocument chunk,
) async {
  final file = File(
    '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/worlds/chunks/${chunk.coordinate.key}.json',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString('${chunk.toJsonString()}\n', flush: true);
}

Future<void> saveEnvironmentWorldManifest(
  EnvironmentWorldManifest manifest,
) async {
  final file = File(
    '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/worlds/environment_world.json',
  );
  await file.writeAsString('${manifest.toJsonString()}\n', flush: true);
}

/// Loads a full generated environment image from a repository checkout.
///
/// The complete imported library is intentionally not bundled into every
/// Flutter app. Editor previews load it on demand; game export will later copy
/// only the assets referenced by an exported world.
Future<ui.Image> loadGeneratedEnvironmentImage(String imagePath) async {
  final bytes = await generatedEnvironmentFile(imagePath).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}
