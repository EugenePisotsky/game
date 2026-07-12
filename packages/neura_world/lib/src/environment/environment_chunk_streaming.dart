import 'environment_chunks.dart';
import 'environment_document.dart';

abstract interface class EnvironmentChunkRepository {
  Future<EnvironmentChunkDocument> load(EnvironmentChunkCoordinate coordinate);
}

class InMemoryEnvironmentChunkRepository implements EnvironmentChunkRepository {
  InMemoryEnvironmentChunkRepository(this.chunks);

  final Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument> chunks;

  @override
  Future<EnvironmentChunkDocument> load(
    EnvironmentChunkCoordinate coordinate,
  ) async {
    final chunk = chunks[coordinate];
    if (chunk == null) {
      throw StateError('Missing environment chunk $coordinate.');
    }
    return chunk;
  }
}

class EnvironmentChunkStreamingManager {
  EnvironmentChunkStreamingManager({
    required this.manifest,
    required this.repository,
    this.loadRadius = 1,
    this.unloadRadius = 2,
  }) {
    if (loadRadius < 0 || unloadRadius < loadRadius) {
      throw ArgumentError('Chunk radii must satisfy 0 <= load <= unload.');
    }
  }

  final EnvironmentWorldManifest manifest;
  final EnvironmentChunkRepository repository;
  final int loadRadius;
  final int unloadRadius;

  final Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument> _loaded = {};
  final Set<EnvironmentChunkCoordinate> _preloading = {};
  final Set<EnvironmentChunkCoordinate> _pendingUnload = {};
  final Map<String, int> _assetReferenceCounts = {};
  int _generation = 0;

  Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument> get loadedChunks =>
      Map.unmodifiable(_loaded);
  Set<EnvironmentChunkCoordinate> get preloadingChunks =>
      Set.unmodifiable(_preloading);
  Set<EnvironmentChunkCoordinate> get pendingUnloadChunks =>
      Set.unmodifiable(_pendingUnload);
  Map<String, int> get assetReferenceCounts =>
      Map.unmodifiable(_assetReferenceCounts);

  bool get isLoading => _preloading.isNotEmpty;

  Future<bool> updateAround(WorldPoint point) {
    final center = manifest.coordinateFor(point);
    return _update(
      wanted: _square(center, loadRadius),
      retained: _square(center, unloadRadius),
    );
  }

  Future<bool> updateForBounds({
    required double minX,
    required double minY,
    required double maxX,
    required double maxY,
    int preloadMargin = 1,
    int retainMargin = 2,
  }) {
    final minChunk = manifest.coordinateFor(WorldPoint(minX, minY));
    final maxChunk = manifest.coordinateFor(WorldPoint(maxX, maxY));
    Set<EnvironmentChunkCoordinate> rectangle(int margin) => {
      for (var y = minChunk.y - margin; y <= maxChunk.y + margin; y++)
        for (var x = minChunk.x - margin; x <= maxChunk.x + margin; x++)
          EnvironmentChunkCoordinate(x, y),
    };
    return _update(
      wanted: rectangle(preloadMargin),
      retained: rectangle(retainMargin),
    );
  }

  Future<bool> _update({
    required Set<EnvironmentChunkCoordinate> wanted,
    required Set<EnvironmentChunkCoordinate> retained,
  }) async {
    final generation = ++_generation;
    wanted.retainWhere(manifest.containsChunk);
    retained.retainWhere(manifest.containsChunk);
    final toLoad = wanted.difference(_loaded.keys.toSet());
    _preloading
      ..clear()
      ..addAll(toLoad);
    _pendingUnload
      ..clear()
      ..addAll(
        _loaded.keys.where((coordinate) => !wanted.contains(coordinate)),
      );

    final loaded = await Future.wait([
      for (final coordinate in toLoad)
        repository.load(coordinate).then((chunk) => (coordinate, chunk)),
    ]);
    if (generation != _generation) return false;

    var changed = false;
    for (final entry in loaded) {
      if (_loaded.containsKey(entry.$1)) continue;
      _loaded[entry.$1] = entry.$2;
      _retainAssets(entry.$2);
      changed = true;
    }
    final remove = _loaded.keys
        .where((coordinate) => !retained.contains(coordinate))
        .toList();
    for (final coordinate in remove) {
      final chunk = _loaded.remove(coordinate)!;
      _releaseAssets(chunk);
      changed = true;
    }
    _preloading.clear();
    _pendingUnload
      ..clear()
      ..addAll(
        _loaded.keys.where((coordinate) => !wanted.contains(coordinate)),
      );
    return changed;
  }

  Set<EnvironmentChunkCoordinate> _square(
    EnvironmentChunkCoordinate center,
    int radius,
  ) => {
    for (var y = center.y - radius; y <= center.y + radius; y++)
      for (var x = center.x - radius; x <= center.x + radius; x++)
        EnvironmentChunkCoordinate(x, y),
  };

  void _retainAssets(EnvironmentChunkDocument chunk) {
    for (final assetId in chunk.referencedAssetIds) {
      _assetReferenceCounts.update(
        assetId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  void _releaseAssets(EnvironmentChunkDocument chunk) {
    for (final assetId in chunk.referencedAssetIds) {
      final next = (_assetReferenceCounts[assetId] ?? 1) - 1;
      if (next <= 0) {
        _assetReferenceCounts.remove(assetId);
      } else {
        _assetReferenceCounts[assetId] = next;
      }
    }
  }
}
