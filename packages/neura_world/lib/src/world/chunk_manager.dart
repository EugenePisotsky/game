import 'package:vector_math/vector_math.dart';

import 'world_chunk.dart';
import 'world_document.dart';

/// Keeps only the chunks close to the player in memory.
///
/// Chunking is only a loading strategy: every cell comes from [world].
class ChunkManager {
  ChunkManager({required this.world, this.chunkSize = 8, this.loadRadius = 2});

  final WorldDocument world;
  final int chunkSize;
  final int loadRadius;
  final Map<ChunkCoordinate, WorldChunk> _loaded = {};

  Iterable<WorldChunk> get loadedChunks => _loaded.values;
  int get loadedChunkCount => _loaded.length;

  void updateAround(Vector2 worldPosition) {
    final center = coordinateFor(worldPosition);
    final wanted = <ChunkCoordinate>{};

    for (var y = -loadRadius; y <= loadRadius; y++) {
      for (var x = -loadRadius; x <= loadRadius; x++) {
        final coordinate = ChunkCoordinate(center.x + x, center.y + y);
        wanted.add(coordinate);
        _loaded.putIfAbsent(
          coordinate,
          () => WorldChunk.fromDocument(
            coordinate: coordinate,
            size: chunkSize,
            document: world,
          ),
        );
      }
    }

    _loaded.removeWhere((coordinate, _) => !wanted.contains(coordinate));
  }

  ChunkCoordinate coordinateFor(Vector2 worldPosition) => ChunkCoordinate(
    (worldPosition.x / chunkSize).floor(),
    (worldPosition.y / chunkSize).floor(),
  );
}
