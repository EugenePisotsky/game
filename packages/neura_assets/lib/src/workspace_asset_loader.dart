import 'dart:io';
import 'dart:ui' as ui;

Directory? _cachedRepositoryRoot;

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

  final startingDirectories = <Directory>{
    Directory.current.absolute,
    File(Platform.resolvedExecutable).parent.absolute,
  };
  for (final start in startingDirectories) {
    var directory = start;
    while (true) {
      final candidate = File(
        '${directory.path}/packages/neura_assets/assets/images/$imagePath',
      );
      if (candidate.existsSync()) {
        _cachedRepositoryRoot = directory;
        return candidate;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
  }
  throw FileSystemException(
    'Could not locate generated environment image from ${Directory.current.path}',
    imagePath,
  );
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
