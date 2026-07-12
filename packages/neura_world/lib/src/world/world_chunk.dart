import 'world_document.dart';

enum GroundType {
  grass,
  rockySoil,
  darkEarth,
  cobblestone,
  woodPlanks,
  stonePavers,
  dryGrass,
}

enum RoadType { dirt }

enum RoadDirection {
  negativeX(-1, 0, 1),
  positiveX(1, 0, 2),
  negativeY(0, -1, 4),
  positiveY(0, 1, 8);

  const RoadDirection(this.dx, this.dy, this.bit);

  final int dx;
  final int dy;
  final int bit;
}

enum RoadTileVariant {
  isolated,
  endNegativeX,
  endPositiveX,
  endNegativeY,
  endPositiveY,
  straightX,
  straightY,
  cornerN,
  cornerE,
  cornerS,
  cornerW,
  junction,
}

RoadTileVariant roadTileVariantForMask(int mask) => switch (mask) {
  0 => RoadTileVariant.isolated,
  1 => RoadTileVariant.endNegativeX,
  2 => RoadTileVariant.endPositiveX,
  4 => RoadTileVariant.endNegativeY,
  8 => RoadTileVariant.endPositiveY,
  3 => RoadTileVariant.straightX,
  12 => RoadTileVariant.straightY,
  9 => RoadTileVariant.cornerN,
  5 => RoadTileVariant.cornerE,
  6 => RoadTileVariant.cornerS,
  10 => RoadTileVariant.cornerW,
  _ => RoadTileVariant.junction,
};

enum DecorationType {
  roundTree,
  wideTree,
  ruralTreeA1,
  ruralTreeA2,
  ruralTreeA3,
  ruralTreeA4,
  ruralTreeA5,
  ruralTreeA6,
  ruralTreeA7,
  ruralTreeA8,
  ruralTreeA9,
  ruralTreeA10,
  ruralTreeA11,
  ruralTreeA12,
  ruralTreeB1,
  ruralTreeB2,
  ruralTreeB3,
  ruralTreeC1,
  ruralTreeC2,
  ruralTreeC3,
  bush,
  lowFlora,
  leafyGroundcover,
  clayPots,
  woodenCrate,
  stoneWell,
  woodenSign,
  fallenLog,
  firewoodPile,
  stonePile,
  hayBale,
  closedChest,
}

class ChunkCoordinate {
  const ChunkCoordinate(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is ChunkCoordinate && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

class WorldTile {
  const WorldTile({
    required this.x,
    required this.y,
    required this.ground,
    required this.elevation,
    this.road,
    this.tileLayers = const [],
    this.decoration,
  });

  final int x;
  final int y;
  final GroundType ground;
  final int elevation;
  final RoadType? road;
  final List<PlacedTileLayer> tileLayers;
  final PlacedDecoration? decoration;
}

class WorldChunk {
  WorldChunk.fromDocument({
    required this.coordinate,
    required this.size,
    required WorldDocument document,
  }) : tiles = List.unmodifiable(_readTiles(coordinate, size, document));

  final ChunkCoordinate coordinate;
  final int size;
  final List<WorldTile> tiles;

  static Iterable<WorldTile> _readTiles(
    ChunkCoordinate coordinate,
    int size,
    WorldDocument document,
  ) sync* {
    final originX = coordinate.x * size;
    final originY = coordinate.y * size;

    for (var localY = 0; localY < size; localY++) {
      for (var localX = 0; localX < size; localX++) {
        final x = originX + localX;
        final y = originY + localY;
        if (!document.containsCell(x, y)) continue;
        yield WorldTile(
          x: x,
          y: y,
          ground: document.groundAt(x, y),
          elevation: document.elevationAt(x, y),
          road: document.roadAt(x, y),
          tileLayers: List.unmodifiable(document.tileLayersAt(x, y)),
          decoration: document.decorationAt(x, y),
        );
      }
    }
  }
}
