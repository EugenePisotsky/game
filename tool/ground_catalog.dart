import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const sourceDirectory = 'content/Fantasy tileset - 2D Isometric/Environment';
const sourceManifestPath = 'catalog/ground_catalog.source.json';
const generatedAssetDirectory =
    'packages/neura_assets/assets/images/ground/catalog';
const runtimeCatalogPath =
    'packages/neura_assets/assets/catalogs/ground_catalog.json';
const rotations = ['e', 'n', 's', 'w'];

void main(List<String> arguments) {
  if (arguments.length != 1 ||
      !const {
        'bootstrap',
        'curate',
        'check',
        'sync',
      }.contains(arguments.single)) {
    stderr.writeln(
      'Usage: dart run tool/ground_catalog.dart '
      '<bootstrap|curate|check|sync>',
    );
    exitCode = 64;
    return;
  }

  switch (arguments.single) {
    case 'bootstrap':
      _bootstrap();
    case 'curate':
      _curate();
    case 'check':
      _loadAndValidate();
      stdout.writeln('Ground catalog is valid.');
    case 'sync':
      final catalog = _loadAndValidate();
      _sync(catalog);
  }
}

void _curate() {
  final manifestFile = File(sourceManifestPath);
  final catalog =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
  for (final value in catalog['items'] as List<Object?>) {
    final item = value as Map<String, Object?>;
    final family = item['sourceFamily'] as String;
    final role = _roleFor(family);
    item
      ..['name'] = _catalogNames[family] ?? family
      ..['role'] = role
      ..['stackable'] = _isStackable(family, role)
      ..['enabled'] = family != 'Ground I10';
  }
  manifestFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(catalog),
  );
  stdout.writeln('Applied audited metadata to 113 Ground families.');
}

void _bootstrap() {
  final manifestFile = File(sourceManifestPath);
  if (manifestFile.existsSync()) {
    stderr.writeln(
      '$sourceManifestPath already exists; refusing to overwrite.',
    );
    exitCode = 1;
    return;
  }

  final families = _discoverSourceFamilies();
  manifestFile.parent.createSync(recursive: true);
  manifestFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'collections': [
        for (final letter in _collectionLetters(families))
          {
            'id': 'ground.${letter.toLowerCase()}',
            'name': 'Ground $letter',
            'description': '',
          },
      ],
      'items': [
        for (final family in families)
          {
            'id': _semanticId(family),
            'sourceFamily': family,
            'name': family,
            'collection':
                'ground.${family.substring('Ground '.length, 'Ground '.length + 1).toLowerCase()}',
            'role': 'unknown',
            'stackable': false,
            'enabled': false,
            'description': '',
            'notes': <String>[],
          },
      ],
    }),
  );
  stdout.writeln(
    'Created $sourceManifestPath with ${families.length} families.',
  );
}

Map<String, Object?> _loadAndValidate() {
  final manifestFile = File(sourceManifestPath);
  if (!manifestFile.existsSync()) {
    throw StateError('Run bootstrap first: $sourceManifestPath is missing.');
  }
  final catalog =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
  final items = catalog['items'] as List<Object?>? ?? const [];
  final discovered = _discoverSourceFamilies().toSet();
  final described = <String>{};
  final ids = <String>{};

  for (final value in items) {
    final item = value as Map<String, Object?>;
    final id = item['id'] as String;
    final sourceFamily = item['sourceFamily'] as String;
    if (!ids.add(id)) throw FormatException('Duplicate catalog id: $id');
    if (!described.add(sourceFamily)) {
      throw FormatException('Duplicate source family: $sourceFamily');
    }
    if (!discovered.contains(sourceFamily)) {
      throw FormatException('Missing source family: $sourceFamily');
    }

    final variants = _sourceVariantsFor(sourceFamily);
    if (variants.keys.toSet().difference(rotations.toSet()).isNotEmpty ||
        rotations.toSet().difference(variants.keys.toSet()).isNotEmpty) {
      throw FormatException(
        '$sourceFamily must have exactly E/N/S/W variants.',
      );
    }
    for (final file in variants.values) {
      final dimensions = _pngDimensions(file);
      final isAllowedOverview = sourceFamily == 'Ground I10';
      if (dimensions != (256, 256) && !isAllowedOverview) {
        throw FormatException(
          '${file.path} is ${dimensions.$1}x${dimensions.$2}; expected 256x256.',
        );
      }
    }
  }

  final missingDescriptions = discovered.difference(described);
  if (missingDescriptions.isNotEmpty) {
    throw FormatException(
      'Manifest does not describe: ${missingDescriptions.join(', ')}',
    );
  }
  return catalog;
}

void _sync(Map<String, Object?> catalog) {
  final outputDirectory = Directory(generatedAssetDirectory)
    ..createSync(recursive: true);
  final runtimeItems = <Map<String, Object?>>[];
  final expectedOutputs = <String>{};

  for (final value in catalog['items'] as List<Object?>) {
    final item = value as Map<String, Object?>;
    if (item['enabled'] != true) continue;
    final id = item['id'] as String;
    final sourceFamily = item['sourceFamily'] as String;
    final assetPaths = <String, String>{};
    for (final entry in _sourceVariantsFor(sourceFamily).entries) {
      final fileName = '${id.replaceAll('.', '_')}_${entry.key}.png';
      final destination = File('${outputDirectory.path}/$fileName');
      entry.value.copySync(destination.path);
      expectedOutputs.add(destination.absolute.path);
      assetPaths[entry.key] = 'ground/catalog/$fileName';
    }
    runtimeItems.add({
      'id': item['id'],
      'name': item['name'],
      'collection': item['collection'],
      'role': item['role'],
      'stackable': item['stackable'],
      'description': item['description'],
      'assets': assetPaths,
    });
  }

  for (final entity in outputDirectory.listSync()) {
    if (entity is File &&
        entity.path.endsWith('.png') &&
        !expectedOutputs.contains(entity.absolute.path)) {
      entity.deleteSync();
    }
  }

  final runtimeFile = File(runtimeCatalogPath);
  runtimeFile.parent.createSync(recursive: true);
  runtimeFile.writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert({
      'schemaVersion': catalog['schemaVersion'],
      'collections': catalog['collections'],
      'items': runtimeItems,
    }),
  );
  stdout.writeln(
    'Synced ${runtimeItems.length} families and '
    '${expectedOutputs.length} rotated assets.',
  );
}

List<String> _discoverSourceFamilies() {
  final pattern = RegExp(r'^Ground ([A-J])(\d+)_([ENSW])\.png$');
  final families = <String>{};
  for (final entity in Directory(sourceDirectory).listSync()) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    final match = pattern.firstMatch(name);
    if (match != null) families.add('Ground ${match[1]}${match[2]}');
  }
  return families.toList()..sort(_compareFamilies);
}

Map<String, File> _sourceVariantsFor(String sourceFamily) => {
  for (final rotation in rotations)
    rotation: File(
      '$sourceDirectory/${sourceFamily}_${rotation.toUpperCase()}.png',
    ),
};

Set<String> _collectionLetters(List<String> families) => {
  for (final family in families)
    family.substring('Ground '.length, 'Ground '.length + 1),
};

String _semanticId(String family) =>
    'ground.${family.substring('Ground '.length).toLowerCase()}';

int _compareFamilies(String a, String b) {
  final pattern = RegExp(r'^Ground ([A-J])(\d+)$');
  final aMatch = pattern.firstMatch(a)!;
  final bMatch = pattern.firstMatch(b)!;
  final byCollection = aMatch[1]!.compareTo(bMatch[1]!);
  return byCollection != 0
      ? byCollection
      : int.parse(aMatch[2]!).compareTo(int.parse(bMatch[2]!));
}

(int, int) _pngDimensions(File file) {
  final bytes = file.openSync()..setPositionSync(16);
  try {
    final dimensions = bytes.readSync(8);
    final data = ByteData.sublistView(Uint8List.fromList(dimensions));
    return (data.getUint32(0), data.getUint32(4));
  } finally {
    bytes.closeSync();
  }
}

const _catalogNames = <String, String>{
  'Ground A1': 'Dirt Foundation',
  'Ground A2': 'Bright Grass — Full',
  'Ground A3': 'Bright Grass — Irregular Fill',
  'Ground A4': 'Bright Grass — Edge',
  'Ground A5': 'Bright Grass — Worn Ring',
  'Ground A6': 'Bright Grass — Patch',
  'Ground A7': 'Leafy Ground Patch',
  'Ground A8': 'Leafy Ground Edge',
  'Ground A9': 'Sparse Ground Flecks',
  'Ground A10': 'Dense Groundcover',
  'Ground A11': 'Groundcover Edge',
  'Ground A12': 'Groundcover Corner',
  'Ground A14': 'Sandy Bank — Edge',
  'Ground A15': 'Sandy Bank — Concave',
  'Ground A16': 'Sand Mound',
  'Ground A17': 'Sandy Bank — Corner',
  'Ground A18': 'Dark Grass — Full',
  'Ground A19': 'Dark Grass — Edge',
  'Ground A20': 'Dark Grass — Corner',
  'Ground A21': 'Dark Grass — Remnant',
  'Ground A22': 'White Flowers — Dense',
  'Ground A23': 'White Flowers — Edge',
  'Ground A24': 'White Flowers — Corner',
  'Ground B1': 'Rocky Earth — Full Gravel',
  'Ground B2': 'Rocky Earth — Gravel Edge',
  'Ground B3': 'Rocky Earth — Sparse Corner',
  'Ground B4': 'Rocky Earth — Center Patch',
  'Ground B5': 'Rocky Earth — Gravel Border',
  'Ground B6': 'Rocky Earth — Sparse Gravel',
  'Ground C1': 'Packed Dirt — Shaded Edge',
  'Ground C2': 'Packed Dirt — Split',
  'Ground C3': 'Packed Dirt — Plain',
  'Ground C4': 'Packed Dirt — Pitted',
  'Ground C5': 'Packed Dirt — Scuffed',
  'Ground C6': 'Packed Dirt — Scuffed Edge',
  'Ground D1': 'Pale Stone Floor',
  'Ground D2': 'Raised Stone Platform — Notched',
  'Ground D3': 'Raised Stone Platform — Corner',
  'Ground D4': 'Raised Stone Wall Face',
  'Ground E1': 'Cobblestone Patch',
  'Ground E2': 'Cobblestone Small Corner',
  'Ground E3': 'Cobblestone Edge',
  'Ground E4': 'Cobblestone Half Patch',
  'Ground E5': 'Cobblestone Broken Patch',
  'Ground E6': 'Cobblestone Corner Trail',
  'Ground E7': 'Cobblestone Cluster',
  'Ground E8': 'Cobblestone Perimeter',
  'Ground E9': 'Cobblestone Corner Arc',
  'Ground E10': 'Dense Pebble Scatter',
  'Ground E11': 'Medium Pebble Scatter',
  'Ground E12': 'Light Pebble Scatter',
  'Ground E13': 'Compact Pebble Scatter',
  'Ground E14': 'Sparse Large Stones',
  'Ground E15': 'Mixed Pebble Scatter',
  'Ground F1': 'Wooden Floor',
  'Ground F2': 'Small Wooden Floor',
  'Ground F3': 'Raised Wooden Platform',
  'Ground F4': 'Supported Wooden Platform',
  'Ground F5': 'Large Cellar Hatch',
  'Ground F6': 'Open Ladder Hatch',
  'Ground G1': 'Earth Cliff Edge A',
  'Ground G2': 'Earth Cliff Ramp A',
  'Ground G3': 'Earth Cliff Corner',
  'Ground G4': 'Earth Cliff Edge B',
  'Ground G5': 'Earth Cliff Ramp B',
  'Ground G6': 'Cliff Grass Edge',
  'Ground G7': 'Cliff Grass Corner',
  'Ground G8': 'Rocky Earth Cliff Edge',
  'Ground G9': 'Rocky Outer Cliff Corner',
  'Ground G10': 'Rocky Inner Cliff Corner',
  'Ground G11': 'Rocky Sloped Cliff Edge',
  'Ground G12': 'Narrow Stone Cliff A',
  'Ground G13': 'Stone Cliff Inner Corner',
  'Ground G14': 'Stone Cliff Wall',
  'Ground G15': 'Stone Cliff Pillar',
  'Ground G16': 'Jagged Earth Cliff Wall',
  'Ground G17': 'Smooth Earth Cliff Wall',
  'Ground G18': 'Narrow Stone Cliff B',
  'Ground G19': 'Narrow Stone Cliff C',
  'Ground G20': 'Grounded Stone Cliff Wall',
  'Ground G21': 'Grounded Stone Cliff Corner',
  'Ground G22': 'Stone Cliff Cave Entrance',
  'Ground H1': 'Stone Pavers — Full A',
  'Ground H2': 'Stone Pavers — Edge Wedge',
  'Ground H3': 'Stone Pavers — Broken Edge',
  'Ground H4': 'Stone Pavers — Full B',
  'Ground H5': 'Stone Pavers — Broken Band Large',
  'Ground H6': 'Stone Pavers — Broken Band Small',
  'Ground H7': 'Stone Pavers — Scattered Large',
  'Ground H8': 'Stone Pavers — Scattered Center',
  'Ground H9': 'Stone Pavers — Damaged Full A',
  'Ground H10': 'Stone Pavers — Damaged Full B',
  'Ground H11': 'Stone Pavers — Damaged Full C',
  'Ground I1': 'Dirt Track — Straight',
  'Ground I2': 'Dirt Track — Corner',
  'Ground I3': 'Dirt Track — End',
  'Ground I4': 'Dirt Track — Broad Worn',
  'Ground I5': 'Dirt Track — Rutted',
  'Ground I6': 'Dirt Track — Isolated Patch',
  'Ground I7': 'Dirt Track — Wide Irregular',
  'Ground I8': 'Dirt Track — T Junction',
  'Ground I9': 'Plain Dirt Block',
  'Ground I10': 'Dirt Track — Incomplete Overview',
  'Ground J1': 'Dry Grass — Full',
  'Ground J2': 'Dry Grass — Edge',
  'Ground J3': 'Dry Grass — Corner',
  'Ground J4': 'Dry Grass — Perimeter',
  'Ground J5': 'Dry Grass — Dense Patch',
  'Ground J6': 'Dry Grass — Clumps',
  'Ground J7': 'Dry Grass — Rows',
  'Ground J8': 'Dry Grass — Sparse',
  'Ground J9': 'Dry Grass — Split Bands',
  'Ground J10': 'Dry Grass — Tuft Pair',
};

String _roleFor(String family) {
  if (_structuralFamilies.contains(family)) return 'structural';
  if (_baseFamilies.contains(family)) return 'base';
  if (_surfaceFamilies.contains(family)) return 'surface';
  if (_transitionFamilies.contains(family)) return 'transition';
  return 'overlay';
}

bool _isStackable(String family, String role) =>
    const {'surface', 'transition', 'overlay'}.contains(role) &&
    !_replacementTransitionFamilies.contains(family);

const _baseFamilies = <String>{
  'Ground A1',
  'Ground B1',
  'Ground B2',
  'Ground B3',
  'Ground B4',
  'Ground B5',
  'Ground B6',
  'Ground C1',
  'Ground C2',
  'Ground C3',
  'Ground C4',
  'Ground C5',
  'Ground C6',
  'Ground D1',
  'Ground I9',
};

const _surfaceFamilies = <String>{
  'Ground A2',
  'Ground A18',
  'Ground E1',
  'Ground F1',
  'Ground F2',
  'Ground H1',
  'Ground H4',
  'Ground H9',
  'Ground H10',
  'Ground H11',
  'Ground J1',
};

const _transitionFamilies = <String>{
  'Ground A3',
  'Ground A4',
  'Ground A5',
  'Ground A11',
  'Ground A12',
  'Ground A14',
  'Ground A15',
  'Ground A16',
  'Ground A17',
  'Ground A19',
  'Ground A20',
  'Ground A23',
  'Ground A24',
  'Ground E2',
  'Ground E3',
  'Ground E4',
  'Ground E6',
  'Ground E9',
  'Ground G1',
  'Ground G2',
  'Ground G3',
  'Ground G4',
  'Ground G5',
  'Ground G8',
  'Ground G9',
  'Ground G10',
  'Ground G11',
  'Ground H2',
  'Ground H3',
  'Ground H5',
  'Ground J2',
  'Ground J3',
  'Ground J4',
  'Ground J9',
};

const _structuralFamilies = <String>{
  'Ground D2',
  'Ground D3',
  'Ground D4',
  'Ground F3',
  'Ground F4',
  'Ground F5',
  'Ground F6',
  'Ground G12',
  'Ground G13',
  'Ground G14',
  'Ground G15',
  'Ground G16',
  'Ground G17',
  'Ground G18',
  'Ground G19',
  'Ground G20',
  'Ground G21',
  'Ground G22',
  'Ground I1',
  'Ground I2',
  'Ground I3',
  'Ground I4',
  'Ground I5',
  'Ground I6',
  'Ground I7',
  'Ground I8',
  'Ground I10',
};

const _replacementTransitionFamilies = <String>{
  'Ground A14',
  'Ground A15',
  'Ground A16',
  'Ground A17',
  'Ground G1',
  'Ground G2',
  'Ground G3',
  'Ground G4',
  'Ground G5',
  'Ground G8',
  'Ground G9',
  'Ground G10',
  'Ground G11',
};
