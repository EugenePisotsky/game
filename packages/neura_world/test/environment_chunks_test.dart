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
    },
  );

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
