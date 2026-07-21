import 'dart:async';

import 'package:neura_world/neura_world.dart';
import 'package:test/test.dart';

void main() {
  test(
    'split world preserves stable local coordinates and indexes seam paint',
    () {
      final document = EnvironmentDocument(
        id: 'world',
        name: 'World',
        width: 64,
        height: 32,
        baseMaterialId: 'ground',
        terrainStrokes: [
          TerrainStroke(
            materialId: 'road',
            radius: 2,
            opacity: 1,
            points: const [WorldPoint(30, 10), WorldPoint(34, 10)],
          ),
        ],
        objects: [
          PlacedEnvironmentObject(
            id: 'tree',
            assetId: 'tree_asset',
            x: 33.5,
            y: 7,
            behaviorProfileId: 'cat_household',
            liquidInteraction: EnvironmentLiquidInteraction.submerge,
            liquidDraft: 0.3,
            crossSurfaceOcclusion: true,
            occlusionHeight: 6,
          ),
        ],
      );
      final world = EnvironmentChunkedWorld.fromDocument(
        document,
        chunkSize: 32,
        playerSpawn: const WorldPoint(33, 4),
        objectBounds: (object) =>
            const EnvironmentObjectBounds(minX: 31, minY: 5, maxX: 36, maxY: 9),
      );

      expect(world.manifest.chunks, hasLength(2));
      expect(
        world.chunks[const EnvironmentChunkCoordinate(0, 0)]!.terrainStrokes,
        hasLength(1),
      );
      expect(
        world.chunks[const EnvironmentChunkCoordinate(1, 0)]!.terrainStrokes,
        hasLength(1),
      );
      final right = world.chunks[const EnvironmentChunkCoordinate(1, 0)]!;
      final left = world.chunks[const EnvironmentChunkCoordinate(0, 0)]!;
      expect(right.objects.single.localX, 1.5);
      expect(right.overlapObjectIds, contains('tree'));
      expect(left.overlapObjectIds, contains('tree'));
      expect(right.objects.single.toWorldObject(right.coordinate, 32).x, 33.5);
      expect(right.terrainStrokes.single.points.first.x, -2);
      expect(
        world.manifest.playerSpawn.chunk,
        const EnvironmentChunkCoordinate(1, 0),
      );
      expect(world.manifest.playerSpawn.localX, 1);

      final restoredManifest = EnvironmentWorldManifest.fromJsonString(
        world.manifest.toJsonString(),
      );
      final restoredChunk = EnvironmentChunkDocument.fromJsonString(
        right.toJsonString(),
      );
      expect(restoredManifest.chunkSize, 32);
      expect(restoredManifest.activeLayerId, EnvironmentDocument.rootLayerId);
      expect(restoredChunk.objects.single.id, 'tree');
      expect(restoredChunk.objects.single.behaviorProfileId, 'cat_household');
      expect(
        restoredChunk.objects.single.liquidInteraction,
        EnvironmentLiquidInteraction.submerge,
      );
      expect(restoredChunk.objects.single.liquidDraft, 0.3);
      expect(restoredChunk.objects.single.crossSurfaceOcclusion, isTrue);
      expect(restoredChunk.objects.single.occlusionHeight, 6);
      expect(
        restoredChunk.objects.single
            .toWorldObject(restoredChunk.coordinate, 32)
            .behaviorProfileId,
        'cat_household',
      );
    },
  );

  test('split world preserves reset-to-base polygons across chunk seams', () {
    final world = EnvironmentChunkedWorld.fromDocument(
      EnvironmentDocument(
        id: 'world',
        name: 'World',
        width: 64,
        height: 32,
        baseMaterialId: 'ground',
        terrainStrokes: [
          TerrainStroke(
            materialId: 'ground',
            radius: 0,
            opacity: 1,
            resetsToBase: true,
            points: const [
              WorldPoint(30, 8),
              WorldPoint(34, 8),
              WorldPoint(34, 12),
              WorldPoint(30, 12),
            ],
          ),
        ],
      ),
      chunkSize: 32,
    );

    final left = world.chunks[const EnvironmentChunkCoordinate(0, 0)]!;
    final right = world.chunks[const EnvironmentChunkCoordinate(1, 0)]!;
    expect(left.terrainStrokes.single.resetsToBase, isTrue);
    expect(right.terrainStrokes.single.resetsToBase, isTrue);
    expect(right.terrainStrokes.single.points.first.x, -2);
  });

  test('split world preserves ordered terrain regions across chunk seams', () {
    final world = EnvironmentChunkedWorld.fromDocument(
      EnvironmentDocument(
        id: 'world',
        name: 'World',
        width: 64,
        height: 32,
        baseMaterialId: 'ground',
        surfaces: [
          EnvironmentSurface(
            id: environmentBaseSurfaceId,
            name: 'Ground',
            materialId: 'ground',
            points: const [
              WorldPoint(0, 0),
              WorldPoint(64, 0),
              WorldPoint(64, 32),
              WorldPoint(0, 32),
            ],
          ),
          EnvironmentSurface(
            id: 'surface_river_bed',
            name: 'River bed',
            materialId: 'sand',
            drawsBaseMaterial: false,
            height: const EnvironmentSurfaceHeight.flat(-0.6),
            points: const [
              WorldPoint(30, 8),
              WorldPoint(34, 8),
              WorldPoint(34, 12),
              WorldPoint(30, 12),
            ],
          ),
        ],
        liquidVolumes: [
          EnvironmentLiquidVolume(
            id: 'river',
            name: 'River',
            bedSurfaceId: 'surface_river_bed',
            materialId: 'water',
            surfaceElevation: 1,
            depth: 0.6,
            endDepth: 1.6,
            depthRampStart: const WorldPoint(30, 10),
            depthRampEnd: const WorldPoint(34, 10),
            opacity: 0.8,
            edgeBlend: 0.5,
            order: 4,
            points: const [
              WorldPoint(30, 8),
              WorldPoint(34, 8),
              WorldPoint(34, 12),
              WorldPoint(30, 12),
            ],
          ),
        ],
        terrainRegions: [
          TerrainRegion(
            id: 'river_detail',
            materialId: 'sand',
            order: 4,
            opacity: 0.8,
            edgeBlend: 0.5,
            surfaceId: 'surface_river_bed',
            points: const [
              WorldPoint(30, 8),
              WorldPoint(34, 8),
              WorldPoint(34, 12),
              WorldPoint(30, 12),
            ],
          ),
        ],
      ),
      chunkSize: 32,
    );

    final left = world.chunks[const EnvironmentChunkCoordinate(0, 0)]!;
    final right = world.chunks[const EnvironmentChunkCoordinate(1, 0)]!;
    expect(left.terrainRegions.single.id, 'river_detail');
    expect(right.terrainRegions.single.id, 'river_detail');
    expect(right.terrainRegions.single.points.first.x, -2);
    expect(left.terrainRegions.single.opacity, 0.8);
    expect(right.terrainRegions.single.edgeBlend, 0.5);
    expect(right.terrainRegions.single.order, 4);
    expect(right.terrainRegions.single.surfaceId, 'surface_river_bed');
    expect(right.surfaces.single.height.elevation, -0.6);
    expect(right.surfaces.single.drawsBaseMaterial, isFalse);
    expect(right.liquidVolumes.single.surfaceElevation, 1);
    expect(right.liquidVolumes.single.depth, 0.6);
    expect(right.liquidVolumes.single.endDepth, 1.6);
    expect(right.liquidVolumes.single.depthRampStart?.x, -2);
    expect(right.liquidVolumes.single.depthRampEnd?.x, 2);
    expect(right.referencedAssetIds, contains('water'));

    final restored = EnvironmentChunkDocument.fromJsonString(
      right.toJsonString(),
    );
    expect(
      restored.schemaVersion,
      EnvironmentChunkDocument.currentSchemaVersion,
    );
    expect(restored.terrainRegions.single.materialId, 'sand');
    expect(restored.liquidVolumes.single.materialId, 'water');
    expect(restored.liquidVolumes.single.endDepth, 1.6);
    expect(restored.liquidVolumes.single.depthRampStart?.x, -2);
    expect(restored.surfaces.single.drawsBaseMaterial, isFalse);
  });

  test(
    'streamer loads 3x3, tracks references, and unloads with hysteresis',
    () async {
      final world = _gridWorld(3, 3);
      final manager = EnvironmentChunkStreamingManager(
        manifest: world.manifest,
        repository: InMemoryEnvironmentChunkRepository(world.chunks),
        loadRadius: 1,
        unloadRadius: 2,
      );

      expect(await manager.updateAround(const WorldPoint(48, 48)), isTrue);
      expect(manager.loadedChunks, hasLength(9));
      expect(manager.assetReferenceCounts['tree'], 9);

      expect(await manager.updateAround(const WorldPoint(80, 48)), isFalse);
      expect(manager.loadedChunks, hasLength(9));
      expect(manager.pendingUnloadChunks.any((chunk) => chunk.x == 0), isTrue);

      expect(await manager.updateAround(const WorldPoint(176, 48)), isTrue);
      expect(manager.loadedChunks, isEmpty);
      expect(manager.assetReferenceCounts, isEmpty);
    },
  );

  test('extending upper-left rebases content and adds an empty edge', () {
    final source = _gridWorld(2, 1);
    final manifest = EnvironmentWorldManifest(
      id: source.manifest.id,
      name: source.manifest.name,
      chunkSize: 32,
      width: 64,
      height: 32,
      baseMaterialId: source.manifest.baseMaterialId,
      chunks: source.manifest.chunks,
      playerSpawn: const ChunkLocalPosition(
        chunk: EnvironmentChunkCoordinate(0, 0),
        localX: 7,
        localY: 8,
      ),
      travelPoints: const [
        EnvironmentTravelPoint(
          id: 'exit',
          position: ChunkLocalPosition(
            chunk: EnvironmentChunkCoordinate(1, 0),
            localX: 2,
            localY: 3,
          ),
        ),
      ],
    );

    final extended = extendEnvironmentChunkedWorld(
      manifest,
      source.chunks,
      EnvironmentWorldEdge.left,
    );

    expect(extended.manifest.width, 96);
    expect(extended.manifest.height, 32);
    expect(extended.chunks, hasLength(3));
    expect(
      extended.chunks[const EnvironmentChunkCoordinate(0, 0)]!.objects,
      isEmpty,
    );
    final shifted = extended.chunks[const EnvironmentChunkCoordinate(1, 0)]!;
    expect(shifted.objects.single.localX, 4);
    expect(shifted.worldObjects.single.x, 36);
    expect(shifted.objects.single.bounds.minX, 35);
    final spawn = extended.manifest.playerSpawn.toWorld(32);
    expect((spawn.x, spawn.y), (39, 8));
    final exit = extended.manifest.travelPoints.single.position.toWorld(32);
    expect((exit.x, exit.y), (66, 3));
  });

  test('extending lower-left preserves existing world coordinates', () {
    final source = _gridWorld(2, 1);
    final extended = extendEnvironmentChunkedWorld(
      source.manifest,
      source.chunks,
      EnvironmentWorldEdge.bottom,
    );

    expect(extended.manifest.width, 64);
    expect(extended.manifest.height, 64);
    expect(extended.chunks, hasLength(4));
    expect(
      extended.chunks[const EnvironmentChunkCoordinate(0, 1)]!.objects,
      isEmpty,
    );
    expect(
      extended
          .chunks[const EnvironmentChunkCoordinate(0, 0)]!
          .worldObjects
          .single
          .x,
      4,
    );
  });

  test(
    'obsolete asynchronous chunk requests are ignored after reversal',
    () async {
      final world = _gridWorld(2, 1);
      final repository = _DelayedRepository(world.chunks);
      final manager = EnvironmentChunkStreamingManager(
        manifest: world.manifest,
        repository: repository,
        loadRadius: 0,
        unloadRadius: 0,
      );

      final first = manager.updateAround(const WorldPoint(1, 1));
      final second = manager.updateAround(const WorldPoint(33, 1));
      repository.complete(const EnvironmentChunkCoordinate(1, 0));
      expect(await second, isTrue);
      repository.complete(const EnvironmentChunkCoordinate(0, 0));
      expect(await first, isFalse);
      expect(manager.loadedChunks.keys, [
        const EnvironmentChunkCoordinate(1, 0),
      ]);
      expect(manager.cancelledRequestCount, 1);
    },
  );
}

EnvironmentChunkedWorld _gridWorld(int columns, int rows) {
  final document = EnvironmentDocument(
    id: 'streaming',
    name: 'Streaming',
    width: columns * 32,
    height: rows * 32,
    baseMaterialId: 'ground',
  );
  final world = EnvironmentChunkedWorld.fromDocument(document, chunkSize: 32);
  final chunks = {
    for (final entry in world.chunks.entries)
      entry.key: EnvironmentChunkDocument(
        worldId: entry.value.worldId,
        coordinate: entry.key,
        size: 32,
        baseMaterialId: 'ground',
        objects: [
          ChunkPlacedEnvironmentObject(
            id: 'tree_${entry.key.key}',
            assetId: 'tree',
            localX: 4,
            localY: 4,
            editorLayerId: EnvironmentDocument.rootLayerId,
            bounds: EnvironmentObjectBounds(
              minX: entry.key.x * 32 + 3,
              minY: entry.key.y * 32 + 3,
              maxX: entry.key.x * 32 + 5,
              maxY: entry.key.y * 32 + 5,
            ),
          ),
        ],
      ),
  };
  return EnvironmentChunkedWorld(manifest: world.manifest, chunks: chunks);
}

class _DelayedRepository implements EnvironmentChunkRepository {
  _DelayedRepository(this.chunks);

  final Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument> chunks;
  final Map<EnvironmentChunkCoordinate, Completer<EnvironmentChunkDocument>>
  _pending = {};

  @override
  Future<EnvironmentChunkDocument> load(
    EnvironmentChunkCoordinate coordinate,
  ) => (_pending[coordinate] ??= Completer()).future;

  void complete(EnvironmentChunkCoordinate coordinate) {
    _pending[coordinate]!.complete(chunks[coordinate]);
  }
}
