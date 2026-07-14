import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:path/path.dart' as p;

import 'rust/frb_generated.dart';

const _nativeAssetId = 'package:neura_world/src/rust/frb_generated.dart';
Future<void>? _initialization;

Future<void> initNeuraWorldRust({String? nativeLibraryPath}) =>
    _initialization ??= _initialize(nativeLibraryPath);

Future<void> _initialize(String? nativeLibraryPath) async {
  final explicit = nativeLibraryPath?.trim();
  if (explicit != null && explicit.isNotEmpty) {
    await RustLib.init(externalLibrary: ExternalLibrary.open(explicit));
    return;
  }

  final discovered = await _discoverNativeLibraryPath();
  if (discovered != null) {
    try {
      await RustLib.init(externalLibrary: ExternalLibrary.open(discovered));
      return;
    } on ArgumentError {
      // Fall through to FRB's regular loader for packaged applications.
    }
  }
  await RustLib.init();
}

Future<String?> _discoverNativeLibraryPath() async {
  final roots = _searchRoots().toList(growable: false);
  for (final root in roots) {
    final manifest = File(p.join(root.path, '.dart_tool/native_assets.yaml'));
    if (!await manifest.exists()) continue;
    try {
      final path = parseNeuraNativeAssetPath(
        await manifest.readAsString(),
        assetId: _nativeAssetId,
      );
      if (path != null && await File(path).exists()) return path;
    } on FormatException {
      // Ignore incomplete manifests from interrupted builds.
    } on IOException {
      // Try the next workspace root.
    }
  }

  final libraryName = switch (Platform.operatingSystem) {
    'windows' => 'neura_world_native.dll',
    'macos' || 'ios' => 'libneura_world_native.dylib',
    _ => 'libneura_world_native.so',
  };
  for (final root in roots) {
    final candidate = p.join(root.path, '.dart_tool/lib', libraryName);
    if (await File(candidate).exists()) return candidate;
  }
  return null;
}

Iterable<Directory> _searchRoots() sync* {
  var current = Directory.current.absolute;
  while (true) {
    yield current;
    final parent = current.parent.absolute;
    if (parent.path == current.path) return;
    current = parent;
  }
}

String? parseNeuraNativeAssetPath(String content, {required String assetId}) {
  final jsonText = LineSplitter.split(content)
      .where((line) => !line.trimLeft().startsWith('#'))
      .join('\n')
      .trim();
  if (jsonText.isEmpty) return null;
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map) return null;
  final nativeAssets = decoded['native-assets'];
  if (nativeAssets is! Map) return null;

  final host = _assetPathFromHostMap(
    nativeAssets[Abi.current().toString()],
    assetId,
  );
  if (host != null) return host;
  for (final hostMap in nativeAssets.values) {
    final path = _assetPathFromHostMap(hostMap, assetId);
    if (path != null) return path;
  }
  return null;
}

String? _assetPathFromHostMap(dynamic hostMap, String assetId) {
  if (hostMap is! Map) return null;
  final value = hostMap[assetId];
  if (value is String) return value;
  if (value is List && value.length >= 2 && value[1] is String) {
    return value[1] as String;
  }
  return null;
}
