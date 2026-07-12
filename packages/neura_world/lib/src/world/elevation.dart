import 'world_document.dart';

const elevationStepPixels = 64.0;

const earthElevationAssetIds = {
  'ground.g1',
  'ground.g2',
  'ground.g3',
  'ground.g4',
  'ground.g5',
};

class ElevationCliff {
  const ElevationCliff({
    required this.assetId,
    required this.rotation,
    required this.level,
  });

  final String assetId;
  final TileRotation rotation;
  final int level;

  PlacedTileLayer get layer =>
      PlacedTileLayer(assetId: assetId, rotation: rotation);
}

/// Whether a derived vertical cliff occupies this cell's walkable footprint.
///
/// Cliff art is anchored to the lower cell beside a higher surface, so that
/// lower cell must not be treated as ordinary traversable ground.
bool hasElevationCliffAt(WorldDocument document, int x, int y) =>
    elevationCliffsAt(document, x, y).isNotEmpty;

List<ElevationCliff> elevationCliffsAt(WorldDocument document, int x, int y) {
  final base = document.elevationAt(x, y);
  final neighborElevations = <_Neighbor, int>{
    for (final neighbor in _Neighbor.values)
      if (document.containsCell(x + neighbor.dx, y + neighbor.dy))
        neighbor: document.elevationAt(x + neighbor.dx, y + neighbor.dy),
  };
  if (neighborElevations.isEmpty) return const [];
  final highest = neighborElevations.values.reduce(
    (current, value) => value > current ? value : current,
  );
  final cliffs = <ElevationCliff>[];
  for (var level = base; level < highest; level++) {
    final high = {
      for (final entry in neighborElevations.entries)
        if (entry.value > level) entry.key,
    };
    final cardinal = high.where((direction) => direction.cardinal).toSet();
    if (cardinal.length == 1) {
      final direction = cardinal.single;
      cliffs.add(
        ElevationCliff(
          assetId: _variantAt(x, y, level, 'ground.g1', 'ground.g4'),
          rotation: _straightRotation(direction),
          level: level,
        ),
      );
      continue;
    }
    if (cardinal.length == 2 && _areAdjacent(cardinal)) {
      cliffs.add(
        ElevationCliff(
          assetId: _variantAt(x, y, level, 'ground.g2', 'ground.g5'),
          rotation: _innerRotation(cardinal),
          level: level,
        ),
      );
      continue;
    }
    if (cardinal.isNotEmpty) {
      for (final direction in cardinal) {
        cliffs.add(
          ElevationCliff(
            assetId: _variantAt(x, y, level, 'ground.g1', 'ground.g4'),
            rotation: _straightRotation(direction),
            level: level,
          ),
        );
      }
      continue;
    }
    for (final diagonal in high.where((direction) => !direction.cardinal)) {
      cliffs.add(
        ElevationCliff(
          assetId: 'ground.g3',
          rotation: _outerRotation(diagonal),
          level: level,
        ),
      );
    }
  }
  return cliffs;
}

String _variantAt(int x, int y, int level, String first, String second) =>
    ((x * 31 + y * 17 + level * 13) & 1) == 0 ? first : second;

bool _areAdjacent(Set<_Neighbor> directions) =>
    !(directions.contains(_Neighbor.north) &&
        directions.contains(_Neighbor.south)) &&
    !(directions.contains(_Neighbor.east) &&
        directions.contains(_Neighbor.west));

TileRotation _straightRotation(_Neighbor highNeighbor) =>
    switch (highNeighbor) {
      _Neighbor.north => TileRotation.west,
      _Neighbor.east => TileRotation.north,
      _Neighbor.south => TileRotation.east,
      _Neighbor.west => TileRotation.south,
      _ => throw StateError('$highNeighbor is not cardinal'),
    };

TileRotation _innerRotation(Set<_Neighbor> highNeighbors) {
  if (highNeighbors.containsAll({_Neighbor.north, _Neighbor.west})) {
    return TileRotation.west;
  }
  if (highNeighbors.containsAll({_Neighbor.north, _Neighbor.east})) {
    return TileRotation.north;
  }
  if (highNeighbors.containsAll({_Neighbor.south, _Neighbor.east})) {
    return TileRotation.east;
  }
  return TileRotation.south;
}

TileRotation _outerRotation(_Neighbor highNeighbor) => switch (highNeighbor) {
  _Neighbor.northWest => TileRotation.south,
  _Neighbor.northEast => TileRotation.west,
  _Neighbor.southEast => TileRotation.north,
  _Neighbor.southWest => TileRotation.east,
  _ => throw StateError('$highNeighbor is not diagonal'),
};

enum _Neighbor {
  north(0, -1, true),
  northEast(1, -1, false),
  east(1, 0, true),
  southEast(1, 1, false),
  south(0, 1, true),
  southWest(-1, 1, false),
  west(-1, 0, true),
  northWest(-1, -1, false);

  const _Neighbor(this.dx, this.dy, this.cardinal);

  final int dx;
  final int dy;
  final bool cardinal;
}
