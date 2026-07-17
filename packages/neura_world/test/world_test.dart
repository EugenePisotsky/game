import 'package:neura_world/neura_world.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  test('isometric projection round-trips world positions', () {
    const projection = IsometricProjection();
    final world = Vector2(12.25, -7.5);

    final restored = projection.screenToWorld(projection.worldToScreen(world));

    expect(restored.x, closeTo(world.x, 0.0001));
    expect(restored.y, closeTo(world.y, 0.0001));
    expect(projection.tileWidth, IsometricProjection.defaultTileWidth);
    expect(projection.tileHeight, IsometricProjection.defaultTileHeight);
    expect(
      projection.tileHeight / projection.tileWidth,
      closeTo(IsometricProjection.trueIsometricRatio, 1e-12),
    );
  });

  test('chunk manager loads a square and handles negative coordinates', () {
    final world = WorldDocument.filled(
      id: 'test',
      name: 'Test',
      width: 32,
      height: 32,
      originX: -16,
      originY: -16,
    );
    final chunks = ChunkManager(world: world, chunkSize: 8, loadRadius: 1);

    chunks.updateAround(Vector2(-0.1, -8.1));

    expect(chunks.loadedChunkCount, 9);
    expect(chunks.coordinateFor(Vector2(-0.1, -8.1)).x, -1);
    expect(chunks.coordinateFor(Vector2(-0.1, -8.1)).y, -2);
  });

  test('chunks contain only cells authored in the world document', () {
    final world = WorldDocument.filled(
      id: 'test',
      name: 'Test',
      width: 3,
      height: 2,
      originX: -1,
      originY: 0,
    );
    world
      ..setRoad(0, 0, RoadType.dirt)
      ..decorations[const CellCoordinate(1, 1)] = PlacedDecoration(
        type: DecorationType.bush,
      );
    final chunk = WorldChunk.fromDocument(
      coordinate: const ChunkCoordinate(0, 0),
      size: 8,
      document: world,
    );

    expect(chunk.tiles, hasLength(4));
    expect(
      chunk.tiles.singleWhere((tile) => tile.x == 0 && tile.y == 0).road,
      RoadType.dirt,
    );
    expect(
      chunk.tiles
          .singleWhere((tile) => tile.x == 1 && tile.y == 1)
          .decoration
          ?.type,
      DecorationType.bush,
    );
  });

  test('world documents round-trip semantic JSON', () {
    final world = WorldDocument.filled(
      id: 'meadow',
      name: 'Meadow',
      width: 4,
      height: 3,
      originX: -2,
      originY: -1,
    );
    world
      ..setRoad(-1, 0, RoadType.dirt)
      ..decorations[const CellCoordinate(1, 1)] = PlacedDecoration(
        type: DecorationType.ruralTreeA1,
        rotation: TileRotation.west,
      )
      ..actors.add(
        const PlacedActor(id: 'sheep_1', type: ActorType.sheep, x: 0, y: 1),
      );

    final restored = WorldDocument.fromJsonString(world.toJsonString());

    expect(restored.groundAt(-1, 0), GroundType.grass);
    expect(restored.roadAt(-1, 0), RoadType.dirt);
    expect(restored.decorationAt(1, 1)?.type, DecorationType.ruralTreeA1);
    expect(restored.decorationAt(1, 1)?.rotation, TileRotation.west);
    expect(restored.actors.single.id, 'sheep_1');
  });

  test('all paintable ground types survive compact row encoding', () {
    final world = WorldDocument.filled(
      id: 'ground_catalog',
      name: 'Ground catalog',
      width: GroundType.values.length,
      height: 1,
    );
    for (var x = 0; x < GroundType.values.length; x++) {
      world.setGround(x, 0, GroundType.values[x]);
    }

    final restored = WorldDocument.fromJsonString(world.toJsonString());

    expect([
      for (var x = 0; x < GroundType.values.length; x++)
        restored.groundAt(x, 0),
    ], GroundType.values);
  });

  test('ordered tile layers preserve asset IDs and rotations', () {
    final world = WorldDocument.filled(
      id: 'layers',
      name: 'Layers',
      width: 2,
      height: 2,
    );
    world.mutableTileLayersAt(1, 1).addAll([
      PlacedTileLayer(assetId: 'ground.i2', rotation: TileRotation.east),
      PlacedTileLayer(assetId: 'ground.j6', rotation: TileRotation.west),
    ]);

    final restored = WorldDocument.fromJsonString(world.toJsonString());
    final layers = restored.tileLayersAt(1, 1);

    expect(layers.map((layer) => layer.assetId), ['ground.i2', 'ground.j6']);
    expect(layers.map((layer) => layer.rotation), [
      TileRotation.east,
      TileRotation.west,
    ]);
    expect(restored.schemaVersion, WorldDocument.currentSchemaVersion);
  });

  test('elevations round-trip and block traversal between levels', () {
    final world = WorldDocument.filled(
      id: 'elevation',
      name: 'Elevation',
      width: 3,
      height: 2,
    )..setElevation(1, 0, 2);

    final restored = WorldDocument.fromJsonString(world.toJsonString());

    expect(restored.elevationAt(1, 0), 2);
    expect(
      restored.canTraverse(
        const CellCoordinate(0, 0),
        const CellCoordinate(1, 0),
      ),
      isFalse,
    );
    expect(
      restored.canTraverse(
        const CellCoordinate(0, 0),
        const CellCoordinate(0, 1),
      ),
      isTrue,
    );
    expect(
      restored.canTraverse(
        const CellCoordinate(0, 0),
        const CellCoordinate(1, 1),
      ),
      isTrue,
    );
  });

  test('earth cliff topology resolves edges and both corner types', () {
    final world = WorldDocument.filled(
      id: 'cliffs',
      name: 'Cliffs',
      width: 7,
      height: 7,
      originX: -3,
    );
    for (final cell in const [
      CellCoordinate(-2, 3),
      CellCoordinate(-1, 3),
      CellCoordinate(0, 3),
      CellCoordinate(1, 3),
      CellCoordinate(-2, 4),
      CellCoordinate(-1, 4),
    ]) {
      world.setElevation(cell.x, cell.y, 1);
    }

    final straight = elevationCliffsAt(world, -2, 2).single;
    final outerTopRight = elevationCliffsAt(world, 2, 2).single;
    final innerNotch = elevationCliffsAt(world, 0, 4).single;
    final outerBottomLeft = elevationCliffsAt(world, -3, 5).single;

    expect({'ground.g1', 'ground.g4'}, contains(straight.assetId));
    expect(straight.rotation, TileRotation.east);
    expect(outerTopRight.assetId, 'ground.g3');
    expect(outerTopRight.rotation, TileRotation.east);
    expect({'ground.g2', 'ground.g5'}, contains(innerNotch.assetId));
    expect(innerNotch.rotation, TileRotation.west);
    expect(outerBottomLeft.rotation, TileRotation.west);
  });

  test('a two-level rise produces stacked cliff segments', () {
    final world = WorldDocument.filled(
      id: 'terrace',
      name: 'Terrace',
      width: 2,
      height: 1,
    )..setElevation(1, 0, 2);

    final cliffs = elevationCliffsAt(world, 0, 0);

    expect(cliffs.map((cliff) => cliff.level), [0, 1]);
    expect(cliffs.map((cliff) => cliff.rotation), [
      TileRotation.north,
      TileRotation.north,
    ]);
  });

  test('derived cliff cells occupy the lower walkable footprint', () {
    final world = WorldDocument.filled(
      id: 'cliff-footprint',
      name: 'Cliff footprint',
      width: 3,
      height: 3,
    );
    world.setElevation(1, 1, 1);

    expect(hasElevationCliffAt(world, 1, 1), isFalse);
    expect(hasElevationCliffAt(world, 1, 0), isTrue);
    expect(hasElevationCliffAt(world, 0, 1), isTrue);
    expect(hasElevationCliffAt(world, 0, 0), isTrue);
  });

  test('road connectivity resolves endpoints, straights, and corners', () {
    final world = WorldDocument.filled(
      id: 'roads',
      name: 'Roads',
      width: 4,
      height: 4,
    );
    world
      ..setRoad(0, 1, RoadType.dirt)
      ..setRoad(1, 1, RoadType.dirt)
      ..setRoad(2, 1, RoadType.dirt)
      ..setRoad(2, 2, RoadType.dirt);

    expect(world.roadTileVariantAt(0, 1), RoadTileVariant.endPositiveX);
    expect(world.roadTileVariantAt(1, 1), RoadTileVariant.straightX);
    expect(world.roadTileVariantAt(2, 1), RoadTileVariant.cornerN);
    expect(world.roadTileVariantAt(2, 2), RoadTileVariant.endNegativeY);
  });

  test('four road neighbors resolve to the junction fallback', () {
    final world = WorldDocument.filled(
      id: 'crossroad',
      name: 'Crossroad',
      width: 3,
      height: 3,
    );
    for (final cell in const [
      CellCoordinate(1, 1),
      CellCoordinate(0, 1),
      CellCoordinate(2, 1),
      CellCoordinate(1, 0),
      CellCoordinate(1, 2),
    ]) {
      world.setRoad(cell.x, cell.y, RoadType.dirt);
    }

    expect(world.roadConnectionsAt(1, 1), 15);
    expect(world.roadTileVariantAt(1, 1), RoadTileVariant.junction);
  });

  test('schema v1 road symbols migrate to semantic road cells', () {
    final restored = WorldDocument.fromJson({
      'schemaVersion': 1,
      'id': 'legacy',
      'name': 'Legacy',
      'width': 3,
      'height': 1,
      'originX': -1,
      'originY': 2,
      'groundRows': ['grg'],
    });

    expect(restored.schemaVersion, WorldDocument.currentSchemaVersion);
    expect(restored.groundAt(0, 2), GroundType.grass);
    expect(restored.roadAt(0, 2), RoadType.dirt);
  });

  test('animal remains inside its configured roaming area', () {
    final animal = Animal(
      home: Vector2(3, -2),
      randomSeed: 7,
      behavior: const AnimalBehavior(
        roamingRadius: 4,
        walkingSpeed: 2,
        minIdleTime: 0.1,
        maxIdleTime: 0.2,
      ),
    );

    for (var i = 0; i < 1200; i++) {
      animal.update(1 / 60);
      expect(animal.position.distanceTo(animal.home), lessThanOrEqualTo(4.001));
    }
  });

  test('animal directions follow the projected isometric movement', () {
    expect(
      Animal.directionForWorldMovement(Vector2(1, -1)),
      MovementDirection.east,
    );
    expect(
      Animal.directionForWorldMovement(Vector2(1, 1)),
      MovementDirection.south,
    );

    for (final direction in MovementDirection.values) {
      expect(
        Animal.directionForWorldMovement(
          Animal.worldMovementForDirection(direction),
        ),
        direction,
      );
    }
  });

  test('animal movement stays aligned with its displayed direction', () {
    final animal = Animal(
      home: Vector2.zero(),
      randomSeed: 11,
      behavior: const AnimalBehavior(
        roamingRadius: 4,
        walkingSpeed: 2,
        minIdleTime: 0.01,
        maxIdleTime: 0.02,
      ),
    );

    for (var i = 0; i < 600; i++) {
      final before = animal.position.clone();
      animal.update(1 / 60);
      final movement = animal.position - before;
      if (movement.length > 0.0001) {
        expect(Animal.directionForWorldMovement(movement), animal.direction);
      }
    }
  });

  test('directions map to the clockwise spritesheet row order', () {
    expect(MovementDirection.east.clockwiseSheetRow, 0);
    expect(MovementDirection.southEast.clockwiseSheetRow, 1);
    expect(MovementDirection.south.clockwiseSheetRow, 2);
    expect(MovementDirection.southWest.clockwiseSheetRow, 3);
    expect(MovementDirection.west.clockwiseSheetRow, 4);
    expect(MovementDirection.northWest.clockwiseSheetRow, 5);
    expect(MovementDirection.north.clockwiseSheetRow, 6);
    expect(MovementDirection.northEast.clockwiseSheetRow, 7);
  });

  test('player updates its facing direction while moving', () {
    final player = Player(position: Vector2.zero());
    player.moveTo(Vector2(1, -1));

    player.update(1 / 60);

    expect(player.direction, MovementDirection.east);
  });
}
