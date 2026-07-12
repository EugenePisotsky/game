import 'dart:convert';

import 'world_chunk.dart';

class CellCoordinate {
  const CellCoordinate(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is CellCoordinate && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

enum ActorType { sheep }

enum TileRotation { north, east, south, west }

class PlacedTileLayer {
  PlacedTileLayer({required this.assetId, required this.rotation});

  final String assetId;
  TileRotation rotation;

  Map<String, Object> toJson() => {
    'assetId': assetId,
    'rotation': rotation.name,
  };
}

class PlacedDecoration {
  PlacedDecoration({required this.type, this.rotation = TileRotation.north});

  final DecorationType type;
  TileRotation rotation;

  Map<String, Object> toJson() => {
    'type': type.name,
    'rotation': rotation.name,
  };
}

class PlacedActor {
  const PlacedActor({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
  });

  final String id;
  final ActorType type;
  final double x;
  final double y;

  Map<String, Object> toJson() => {'id': id, 'type': type.name, 'x': x, 'y': y};
}

/// The complete, hand-authored description of one world area.
///
/// The runtime may stream this document in chunks, but it never invents cells.
class WorldDocument {
  static const currentSchemaVersion = 5;

  WorldDocument({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.originX,
    required this.originY,
    required List<GroundType> ground,
    Map<CellCoordinate, int>? elevations,
    Map<CellCoordinate, RoadType>? roads,
    Map<CellCoordinate, List<PlacedTileLayer>>? tileLayers,
    Map<CellCoordinate, PlacedDecoration>? decorations,
    List<PlacedActor>? actors,
    this.spawnX = 0,
    this.spawnY = 0,
    this.schemaVersion = currentSchemaVersion,
  }) : assert(width > 0 && height > 0),
       assert(ground.length == width * height),
       _ground = List.of(ground),
       elevations = Map.of(elevations ?? const {}),
       roads = Map.of(roads ?? const {}),
       tileLayers = {
         for (final entry in (tileLayers ?? const {}).entries)
           entry.key: List.of(entry.value),
       },
       decorations = Map.of(decorations ?? const {}),
       actors = List.of(actors ?? const []);

  factory WorldDocument.filled({
    required String id,
    required String name,
    required int width,
    required int height,
    int originX = 0,
    int originY = 0,
    GroundType ground = GroundType.grass,
  }) => WorldDocument(
    id: id,
    name: name,
    width: width,
    height: height,
    originX: originX,
    originY: originY,
    ground: List.filled(width * height, ground),
  );

  factory WorldDocument.fromJson(Map<String, Object?> json) {
    final width = _integer(json, 'width');
    final height = _integer(json, 'height');
    final originX = _integer(json, 'originX');
    final originY = _integer(json, 'originY');
    final rows = (json['groundRows'] as List<Object?>?)
        ?.map((row) => row as String)
        .toList();
    if (rows == null ||
        rows.length != height ||
        rows.any((r) => r.length != width)) {
      throw const FormatException('groundRows must match the world dimensions');
    }

    final ground = <GroundType>[];
    final roads = <CellCoordinate, RoadType>{};
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final symbols = rows[rowIndex].split('');
      for (var columnIndex = 0; columnIndex < symbols.length; columnIndex++) {
        final symbol = symbols[columnIndex];
        if (symbol == 'r') {
          // Schema v1 stored roads as ground. Migrate them into the road layer.
          ground.add(GroundType.grass);
          roads[CellCoordinate(originX + columnIndex, originY + rowIndex)] =
              RoadType.dirt;
          continue;
        }
        ground.add(switch (symbol) {
          'g' => GroundType.grass,
          'k' => GroundType.rockySoil,
          'e' => GroundType.darkEarth,
          'c' => GroundType.cobblestone,
          'w' => GroundType.woodPlanks,
          'p' => GroundType.stonePavers,
          'd' => GroundType.dryGrass,
          _ => throw FormatException('Unknown ground symbol: $symbol'),
        });
      }
    }

    for (final value in (json['roads'] as List<Object?>? ?? const [])) {
      final item = value as Map<String, Object?>;
      roads[CellCoordinate(_integer(item, 'x'), _integer(item, 'y'))] = RoadType
          .values
          .byName(item['type'] as String);
    }

    final tileLayers = <CellCoordinate, List<PlacedTileLayer>>{};
    for (final value in (json['tileLayers'] as List<Object?>? ?? const [])) {
      final item = value as Map<String, Object?>;
      final cell = CellCoordinate(_integer(item, 'x'), _integer(item, 'y'));
      tileLayers[cell] = [
        for (final layerValue in (item['layers'] as List<Object?>? ?? const []))
          PlacedTileLayer(
            assetId: (layerValue as Map<String, Object?>)['assetId'] as String,
            rotation: TileRotation.values.byName(
              layerValue['rotation'] as String,
            ),
          ),
      ];
    }

    final elevations = <CellCoordinate, int>{};
    for (final value in (json['elevations'] as List<Object?>? ?? const [])) {
      final item = value as Map<String, Object?>;
      final elevation = _integer(item, 'value');
      if (elevation < 0) {
        throw const FormatException('Cell elevation cannot be negative');
      }
      if (elevation > 0) {
        elevations[CellCoordinate(_integer(item, 'x'), _integer(item, 'y'))] =
            elevation;
      }
    }

    final decorations = <CellCoordinate, PlacedDecoration>{};
    for (final value in (json['decorations'] as List<Object?>? ?? const [])) {
      final item = value as Map<String, Object?>;
      decorations[CellCoordinate(
        _integer(item, 'x'),
        _integer(item, 'y'),
      )] = PlacedDecoration(
        type: DecorationType.values.byName(item['type'] as String),
        rotation: TileRotation.values.byName(
          item['rotation'] as String? ?? TileRotation.north.name,
        ),
      );
    }

    final actors = <PlacedActor>[];
    for (final value in (json['actors'] as List<Object?>? ?? const [])) {
      final item = value as Map<String, Object?>;
      actors.add(
        PlacedActor(
          id: item['id'] as String,
          type: ActorType.values.byName(item['type'] as String),
          x: (item['x'] as num).toDouble(),
          y: (item['y'] as num).toDouble(),
        ),
      );
    }

    final spawn = json['spawn'] as Map<String, Object?>?;
    return WorldDocument(
      schemaVersion: currentSchemaVersion,
      id: json['id'] as String,
      name: json['name'] as String,
      width: width,
      height: height,
      originX: originX,
      originY: originY,
      ground: ground,
      elevations: elevations,
      roads: roads,
      tileLayers: tileLayers,
      decorations: decorations,
      actors: actors,
      spawnX: (spawn?['x'] as num?)?.toDouble() ?? 0,
      spawnY: (spawn?['y'] as num?)?.toDouble() ?? 0,
    );
  }

  factory WorldDocument.fromJsonString(String source) =>
      WorldDocument.fromJson(jsonDecode(source) as Map<String, Object?>);

  final int schemaVersion;
  final String id;
  final String name;
  final int width;
  final int height;
  final int originX;
  final int originY;
  final double spawnX;
  final double spawnY;
  final List<GroundType> _ground;
  final Map<CellCoordinate, int> elevations;
  final Map<CellCoordinate, RoadType> roads;
  final Map<CellCoordinate, List<PlacedTileLayer>> tileLayers;
  final Map<CellCoordinate, PlacedDecoration> decorations;
  final List<PlacedActor> actors;

  int get maxX => originX + width - 1;
  int get maxY => originY + height - 1;

  bool containsCell(int x, int y) =>
      x >= originX && x <= maxX && y >= originY && y <= maxY;

  GroundType groundAt(int x, int y) => _ground[_indexOf(x, y)];

  void setGround(int x, int y, GroundType value) {
    _ground[_indexOf(x, y)] = value;
  }

  int elevationAt(int x, int y) {
    if (!containsCell(x, y)) throw RangeError('Cell ($x, $y) is outside $id');
    return elevations[CellCoordinate(x, y)] ?? 0;
  }

  void setElevation(int x, int y, int value) {
    if (!containsCell(x, y)) throw RangeError('Cell ($x, $y) is outside $id');
    if (value < 0) throw RangeError.value(value, 'value', 'Must be >= 0');
    final cell = CellCoordinate(x, y);
    if (value == 0) {
      elevations.remove(cell);
    } else {
      elevations[cell] = value;
    }
  }

  bool canTraverse(CellCoordinate from, CellCoordinate to) {
    if (!containsCell(from.x, from.y) || !containsCell(to.x, to.y)) {
      return false;
    }
    final dx = (from.x - to.x).abs();
    final dy = (from.y - to.y).abs();
    return dx <= 1 &&
        dy <= 1 &&
        dx + dy > 0 &&
        elevationAt(from.x, from.y) == elevationAt(to.x, to.y);
  }

  RoadType? roadAt(int x, int y) => roads[CellCoordinate(x, y)];

  void setRoad(int x, int y, RoadType value) {
    if (!containsCell(x, y)) throw RangeError('Cell ($x, $y) is outside $id');
    roads[CellCoordinate(x, y)] = value;
  }

  bool removeRoad(int x, int y) => roads.remove(CellCoordinate(x, y)) != null;

  int roadConnectionsAt(int x, int y) {
    final type = roadAt(x, y);
    if (type == null) return 0;
    var mask = 0;
    for (final direction in RoadDirection.values) {
      final neighborX = x + direction.dx;
      final neighborY = y + direction.dy;
      if (containsCell(neighborX, neighborY) &&
          elevationAt(x, y) == elevationAt(neighborX, neighborY) &&
          roadAt(neighborX, neighborY) == type) {
        mask |= direction.bit;
      }
    }
    return mask;
  }

  RoadTileVariant roadTileVariantAt(int x, int y) =>
      roadTileVariantForMask(roadConnectionsAt(x, y));

  List<PlacedTileLayer> tileLayersAt(int x, int y) =>
      tileLayers[CellCoordinate(x, y)] ?? const [];

  List<PlacedTileLayer> mutableTileLayersAt(int x, int y) {
    if (!containsCell(x, y)) throw RangeError('Cell ($x, $y) is outside $id');
    return tileLayers.putIfAbsent(CellCoordinate(x, y), () => []);
  }

  void removeTileLayerAt(int x, int y, int index) {
    final coordinate = CellCoordinate(x, y);
    final layers = tileLayers[coordinate];
    if (layers == null || index < 0 || index >= layers.length) return;
    layers.removeAt(index);
    if (layers.isEmpty) tileLayers.remove(coordinate);
  }

  PlacedDecoration? decorationAt(int x, int y) =>
      decorations[CellCoordinate(x, y)];

  PlacedActor? actorAt(int x, int y) {
    for (final actor in actors.reversed) {
      if (actor.x.round() == x && actor.y.round() == y) return actor;
    }
    return null;
  }

  Map<String, Object> toJson() {
    final elevationList = elevations.entries.toList()
      ..sort((a, b) {
        final byY = a.key.y.compareTo(b.key.y);
        return byY != 0 ? byY : a.key.x.compareTo(b.key.x);
      });
    final roadList = roads.entries.toList()
      ..sort((a, b) {
        final byY = a.key.y.compareTo(b.key.y);
        return byY != 0 ? byY : a.key.x.compareTo(b.key.x);
      });
    final tileLayerList =
        tileLayers.entries.where((entry) => entry.value.isNotEmpty).toList()
          ..sort((a, b) {
            final byY = a.key.y.compareTo(b.key.y);
            return byY != 0 ? byY : a.key.x.compareTo(b.key.x);
          });
    final decorationList = decorations.entries.toList()
      ..sort((a, b) {
        final byY = a.key.y.compareTo(b.key.y);
        return byY != 0 ? byY : a.key.x.compareTo(b.key.x);
      });
    final actorList = List.of(actors)..sort((a, b) => a.id.compareTo(b.id));
    return {
      'schemaVersion': schemaVersion,
      'id': id,
      'name': name,
      'width': width,
      'height': height,
      'originX': originX,
      'originY': originY,
      'spawn': {'x': spawnX, 'y': spawnY},
      'groundRows': [
        for (var y = originY; y <= maxY; y++)
          [for (var x = originX; x <= maxX; x++) _groundSymbol(groundAt(x, y))]
              .join(),
      ],
      'elevations': [
        for (final entry in elevationList)
          {'x': entry.key.x, 'y': entry.key.y, 'value': entry.value},
      ],
      'roads': [
        for (final entry in roadList)
          {'x': entry.key.x, 'y': entry.key.y, 'type': entry.value.name},
      ],
      'tileLayers': [
        for (final entry in tileLayerList)
          {
            'x': entry.key.x,
            'y': entry.key.y,
            'layers': entry.value.map((layer) => layer.toJson()).toList(),
          },
      ],
      'decorations': [
        for (final entry in decorationList)
          {'x': entry.key.x, 'y': entry.key.y, ...entry.value.toJson()},
      ],
      'actors': actorList.map((actor) => actor.toJson()).toList(),
    };
  }

  String toJsonString({bool pretty = true}) =>
      (pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder())
          .convert(toJson());

  WorldDocument copy() => WorldDocument.fromJson(toJson());

  int _indexOf(int x, int y) {
    if (!containsCell(x, y)) {
      throw RangeError('Cell ($x, $y) is outside $id');
    }
    return (y - originY) * width + (x - originX);
  }

  static int _integer(Map<String, Object?> json, String key) =>
      (json[key] as num).toInt();

  static String _groundSymbol(GroundType ground) => switch (ground) {
    GroundType.grass => 'g',
    GroundType.rockySoil => 'k',
    GroundType.darkEarth => 'e',
    GroundType.cobblestone => 'c',
    GroundType.woodPlanks => 'w',
    GroundType.stonePavers => 'p',
    GroundType.dryGrass => 'd',
  };
}
