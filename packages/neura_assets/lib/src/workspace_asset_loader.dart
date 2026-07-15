import 'dart:io';
import 'dart:math' as math;
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

/// Resolves an editor-only environment-library image without decoding it.
File workspaceEnvironmentFile(String imagePath) {
  if (PathTraversalGuard.isUnsafe(imagePath) ||
      !const [
        'environment_generated/',
        'environment_v2/',
      ].any(imagePath.startsWith)) {
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
    'Workspace environment image does not exist',
    candidate.path,
  );
}

File generatedEnvironmentFile(String imagePath) =>
    workspaceEnvironmentFile(imagePath);

abstract final class PathTraversalGuard {
  static bool isUnsafe(String path) =>
      path.isEmpty ||
      path.startsWith('/') ||
      path.split('/').any((component) => component == '..');
}

File environmentCatalogFile() => File(
  '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/catalogs/environment_catalog.json',
);

File environmentGeometryOverridesFile() => File(
  '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/catalogs/environment_geometry_overrides.json',
);

File environmentWorldManifestFile() => File(
  '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/worlds/environment_world.json',
);

File environmentStarterDocumentFile() => File(
  '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/worlds/environment_starter.json',
);

File environmentReleaseAssetReportFile() => File(
  '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/release/asset_report.json',
);

Future<EnvironmentWorldManifest>
loadWorkspaceEnvironmentWorldManifest() async =>
    EnvironmentWorldManifest.fromJsonString(
      await environmentWorldManifestFile().readAsString(),
    );

class WorkspaceEnvironmentChunkRepository
    implements EnvironmentChunkRepository {
  const WorkspaceEnvironmentChunkRepository();

  @override
  Future<EnvironmentChunkDocument> load(
    EnvironmentChunkCoordinate coordinate,
  ) async => EnvironmentChunkDocument.fromJsonString(
    await File(
      '${repositoryRootForNeuraAssets().path}/packages/neura_assets/assets/worlds/chunks/${coordinate.key}.json',
    ).readAsString(),
  );
}

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

/// Loads a full environment image from a repository checkout.
///
/// The complete imported library is intentionally not bundled into every
/// Flutter app. Editor previews load it on demand; game export will later copy
/// only the assets referenced by an exported world.
Future<ui.Image> loadWorkspaceEnvironmentImage(String imagePath) async {
  final loaded = await loadWorkspaceEnvironmentImageForEditor(imagePath);
  return loaded.image;
}

class WorkspaceEnvironmentImage {
  const WorkspaceEnvironmentImage({
    required this.image,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final ui.Image image;
  final int sourceWidth;
  final int sourceHeight;
}

/// Decodes a workspace image at a bounded editor resolution while retaining
/// its original logical dimensions for correct world-space rendering.
Future<WorkspaceEnvironmentImage> loadWorkspaceEnvironmentImageForEditor(
  String imagePath, {
  int? maximumDimension,
}) async {
  final bytes = await workspaceEnvironmentFile(imagePath).readAsBytes();
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final sourceWidth = descriptor.width;
  final sourceHeight = descriptor.height;
  final largestDimension = math.max(sourceWidth, sourceHeight);
  final targetDimension = maximumDimension == null
      ? null
      : math.min(maximumDimension, largestDimension);
  final codec = await descriptor.instantiateCodec(
    targetWidth: sourceWidth >= sourceHeight ? targetDimension : null,
    targetHeight: sourceHeight > sourceWidth ? targetDimension : null,
  );
  try {
    final frame = await codec.getNextFrame();
    return WorkspaceEnvironmentImage(
      image: frame.image,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

Future<ui.Image> loadGeneratedEnvironmentImage(String imagePath) =>
    loadWorkspaceEnvironmentImage(imagePath);
