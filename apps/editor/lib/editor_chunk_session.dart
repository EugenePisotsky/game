import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

class DuplicateObjectIdOccurrence {
  const DuplicateObjectIdOccurrence({
    required this.chunk,
    required this.assetId,
    required this.position,
  });

  final EnvironmentChunkCoordinate chunk;
  final String assetId;
  final WorldPoint position;
}

class DuplicateObjectIdIssue {
  const DuplicateObjectIdIssue({required this.id, required this.occurrences});

  final String id;
  final List<DuplicateObjectIdOccurrence> occurrences;
}

class ObjectIdRepair {
  const ObjectIdRepair({
    required this.previousId,
    required this.replacementId,
    required this.chunk,
  });

  final String previousId;
  final String replacementId;
  final EnvironmentChunkCoordinate chunk;
}

class ObjectIdRepairResult {
  const ObjectIdRepairResult({required this.document, required this.repairs});

  final EnvironmentDocument document;
  final List<ObjectIdRepair> repairs;
}

class EditorChunkSession {
  EditorChunkSession({
    required EnvironmentWorldManifest manifest,
    required this.catalog,
    AssetBundle? bundle,
    EnvironmentChunkRepository? repository,
  }) : _manifest = manifest,
       assert(bundle != null || repository != null),
       _sourceRepository =
           repository ?? AssetBundleEnvironmentChunkRepository(bundle!) {
    _editorLayers = [
      for (final layer in manifest.editorLayers)
        EditorLayer.fromJson(layer.toJson()),
    ];
    _activeLayerId = manifest.activeLayerId;
    _repository = _EditorChunkRepository(
      fallback: _sourceRepository,
      workingChunks: _workingChunks,
    );
    streamer = EnvironmentChunkStreamingManager(
      manifest: manifest,
      repository: _repository,
      loadRadius: 1,
      unloadRadius: 2,
    );
  }

  EnvironmentWorldManifest _manifest;
  EnvironmentWorldManifest get manifest => _manifest;
  final EnvironmentCatalog catalog;
  final EnvironmentChunkRepository _sourceRepository;
  late final _EditorChunkRepository _repository;
  late EnvironmentChunkStreamingManager streamer;
  final Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument>
  _workingChunks = {};
  final Set<EnvironmentChunkCoordinate> _dirtyChunks = {};
  late List<EditorLayer> _editorLayers;
  late String _activeLayerId;
  String? _lastDocumentSnapshot;
  bool _manifestDirty = false;

  Set<EnvironmentChunkCoordinate> get loadedCoordinates =>
      streamer.loadedChunks.keys.toSet();
  Set<EnvironmentChunkCoordinate> get dirtyCoordinates =>
      Set.unmodifiable(_dirtyChunks);
  bool get manifestDirty => _manifestDirty;
  WorldPoint get playerSpawn =>
      manifest.playerSpawn.toWorld(manifest.chunkSize);

  Future<EnvironmentDocument> initialize() async {
    final spawn = manifest.playerSpawn.toWorld(manifest.chunkSize);
    await streamer.updateForBounds(
      minX: spawn.x - 16,
      minY: spawn.y - 16,
      maxX: spawn.x + 16,
      maxY: spawn.y + 16,
      preloadMargin: 1,
      retainMargin: 2,
    );
    _adoptLoadedChunks();
    final document = buildDocument();
    _lastDocumentSnapshot = document.toJsonString(pretty: false);
    return document;
  }

  Future<EnvironmentDocument?> streamForBounds(
    EnvironmentDocument current, {
    required double minX,
    required double minY,
    required double maxX,
    required double maxY,
  }) async {
    final currentSnapshot = current.toJsonString(pretty: false);
    capture(current, markDirty: currentSnapshot != _lastDocumentSnapshot);
    final changed = await streamer.updateForBounds(
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
    );
    if (!changed) return null;
    _adoptLoadedChunks();
    final document = buildDocument();
    _lastDocumentSnapshot = document.toJsonString(pretty: false);
    return document;
  }

  void capture(EnvironmentDocument document, {bool markDirty = true}) {
    _editorLayers = [
      for (final layer in document.editorLayers)
        EditorLayer.fromJson(layer.toJson()),
    ];
    _activeLayerId = document.activeLayerId;
    final split = EnvironmentChunkedWorld.fromDocument(
      document,
      chunkSize: manifest.chunkSize,
      worldWidth: manifest.width,
      worldHeight: manifest.height,
      playerSpawn: manifest.playerSpawn.toWorld(manifest.chunkSize),
      objectBounds: _boundsForObject,
    );
    for (final coordinate in loadedCoordinates) {
      final chunk = split.chunks[coordinate];
      if (chunk == null) continue;
      final previous =
          _workingChunks[coordinate] ?? streamer.loadedChunks[coordinate];
      _workingChunks[coordinate] = chunk;
      if (markDirty &&
          previous?.toJsonString(pretty: false) !=
              chunk.toJsonString(pretty: false)) {
        _dirtyChunks.add(coordinate);
      }
    }
  }

  Future<void> saveDirty(EnvironmentDocument document) async {
    final snapshot = document.toJsonString(pretty: false);
    capture(document, markDirty: snapshot != _lastDocumentSnapshot);
    final dirty = _dirtyChunks.toList()..sort();
    for (final coordinate in dirty) {
      final chunk = _workingChunks[coordinate];
      if (chunk != null) await saveEnvironmentChunkDocument(chunk);
    }
    await saveEnvironmentWorldManifest(
      EnvironmentWorldManifest(
        id: manifest.id,
        name: manifest.name,
        chunkSize: manifest.chunkSize,
        width: manifest.width,
        height: manifest.height,
        baseMaterialId: manifest.baseMaterialId,
        chunks: manifest.chunks,
        playerSpawn: manifest.playerSpawn,
        travelPoints: manifest.travelPoints,
        editorLayers: _editorLayers,
        activeLayerId: _activeLayerId,
      ),
    );
    _dirtyChunks.clear();
    _manifestDirty = false;
    _workingChunks.removeWhere(
      (coordinate, _) => !loadedCoordinates.contains(coordinate),
    );
    _lastDocumentSnapshot = snapshot;
  }

  Future<List<DuplicateObjectIdIssue>> findDuplicateObjectIds(
    EnvironmentDocument current,
  ) async {
    final chunks = await _loadCompleteWorld(current);
    final occurrences = <String, List<DuplicateObjectIdOccurrence>>{};
    for (final coordinate in chunks.keys.toList()..sort()) {
      final chunk = chunks[coordinate]!;
      for (final object in chunk.objects) {
        occurrences
            .putIfAbsent(object.id, () => [])
            .add(
              DuplicateObjectIdOccurrence(
                chunk: coordinate,
                assetId: object.assetId,
                position: WorldPoint(
                  coordinate.x * manifest.chunkSize + object.localX,
                  coordinate.y * manifest.chunkSize + object.localY,
                ),
              ),
            );
      }
    }
    return [
      for (final entry in occurrences.entries)
        if (entry.value.length > 1)
          DuplicateObjectIdIssue(
            id: entry.key,
            occurrences: List.unmodifiable(entry.value),
          ),
    ]..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<ObjectIdRepairResult> repairDuplicateObjectIds(
    EnvironmentDocument current,
  ) async {
    final source = await _loadCompleteWorld(current);
    final coordinates = source.keys.toList()..sort();
    final usedIds = {
      for (final chunk in source.values)
        for (final object in chunk.objects) object.id,
    };
    final seenIds = <String>{};
    final repairs = <ObjectIdRepair>[];
    final objectsByChunk =
        <EnvironmentChunkCoordinate, List<ChunkPlacedEnvironmentObject>>{};

    for (final coordinate in coordinates) {
      final objects = <ChunkPlacedEnvironmentObject>[];
      for (final object in source[coordinate]!.objects) {
        var id = object.id;
        if (!seenIds.add(id)) {
          id = _replacementObjectId(id, coordinate, usedIds);
          usedIds.add(id);
          seenIds.add(id);
          repairs.add(
            ObjectIdRepair(
              previousId: object.id,
              replacementId: id,
              chunk: coordinate,
            ),
          );
        }
        objects.add(_copyChunkObject(object, id: id));
      }
      objectsByChunk[coordinate] = objects;
    }

    for (final coordinate in coordinates) {
      final previous = source[coordinate]!;
      final rebuilt = EnvironmentChunkDocument(
        worldId: previous.worldId,
        coordinate: previous.coordinate,
        size: previous.size,
        baseMaterialId: previous.baseMaterialId,
        terrainStrokes: previous.terrainStrokes,
        objects: objectsByChunk[coordinate],
        overlapObjectIds: {
          for (final objects in objectsByChunk.values)
            for (final object in objects)
              if (object.bounds.overlapsChunk(coordinate, manifest.chunkSize))
                object.id,
        },
      );
      _workingChunks[coordinate] = rebuilt;
      if (rebuilt.toJsonString(pretty: false) !=
          previous.toJsonString(pretty: false)) {
        _dirtyChunks.add(coordinate);
      }
    }

    final document = buildDocument();
    _lastDocumentSnapshot = document.toJsonString(pretty: false);
    return ObjectIdRepairResult(
      document: document,
      repairs: List.unmodifiable(repairs),
    );
  }

  Future<Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument>>
  _loadCompleteWorld(EnvironmentDocument current) async {
    final currentSnapshot = current.toJsonString(pretty: false);
    capture(current, markDirty: currentSnapshot != _lastDocumentSnapshot);
    final entries = await Future.wait([
      for (final coordinate in manifest.chunks)
        _repository
            .load(coordinate)
            .then((chunk) => MapEntry(coordinate, chunk)),
    ]);
    return Map.fromEntries(entries);
  }

  static ChunkPlacedEnvironmentObject _copyChunkObject(
    ChunkPlacedEnvironmentObject object, {
    required String id,
  }) => ChunkPlacedEnvironmentObject(
    id: id,
    assetId: object.assetId,
    localX: object.localX,
    localY: object.localY,
    verticalOffset: object.verticalOffset,
    sortBias: object.sortBias,
    editorLayerId: object.editorLayerId,
    direction: object.direction,
    bounds: object.bounds,
  );

  static String _replacementObjectId(
    String original,
    EnvironmentChunkCoordinate coordinate,
    Set<String> usedIds,
  ) {
    var suffix = 1;
    while (true) {
      final candidate =
          '${original}_repair_${coordinate.x}_${coordinate.y}_$suffix';
      if (!usedIds.contains(candidate)) return candidate;
      suffix++;
    }
  }

  Future<({EnvironmentDocument document, WorldPoint worldShift})> extendWorld(
    EnvironmentDocument current,
    EnvironmentWorldEdge edge, {
    required EnvironmentObjectBounds visibleBounds,
  }) async {
    final currentSnapshot = current.toJsonString(pretty: false);
    capture(current, markDirty: currentSnapshot != _lastDocumentSnapshot);
    final entries = await Future.wait([
      for (final coordinate in manifest.chunks)
        _repository
            .load(coordinate)
            .then((chunk) => MapEntry(coordinate, chunk)),
    ]);
    final sourceChunks =
        Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument>.fromEntries(
          entries,
        );
    final extended = extendEnvironmentChunkedWorld(
      manifest,
      sourceChunks,
      edge,
    );
    final shift = WorldPoint(
      edge == EnvironmentWorldEdge.left ? manifest.chunkSize : 0,
      edge == EnvironmentWorldEdge.top ? manifest.chunkSize : 0,
    );
    _manifest = extended.manifest;
    _workingChunks
      ..clear()
      ..addAll(extended.chunks);
    _dirtyChunks
      ..clear()
      ..addAll(extended.chunks.keys);
    _manifestDirty = true;
    streamer = EnvironmentChunkStreamingManager(
      manifest: manifest,
      repository: _repository,
      loadRadius: 1,
      unloadRadius: 2,
    );
    await streamer.updateForBounds(
      minX: visibleBounds.minX + shift.x,
      minY: visibleBounds.minY + shift.y,
      maxX: visibleBounds.maxX + shift.x,
      maxY: visibleBounds.maxY + shift.y,
    );
    _lastDocumentSnapshot = null;
    final document = buildDocument();
    _lastDocumentSnapshot = document.toJsonString(pretty: false);
    return (document: document, worldShift: shift);
  }

  void setPlayerSpawn(WorldPoint point) {
    final epsilon = manifest.chunkSize / 1000000;
    final clamped = WorldPoint(
      point.x.clamp(0, manifest.width - epsilon),
      point.y.clamp(0, manifest.height - epsilon),
    );
    final position = ChunkLocalPosition.fromWorld(
      clamped,
      chunkSize: manifest.chunkSize,
    );
    if (!manifest.containsChunk(position.chunk)) return;
    _manifest = EnvironmentWorldManifest(
      id: manifest.id,
      name: manifest.name,
      chunkSize: manifest.chunkSize,
      width: manifest.width,
      height: manifest.height,
      baseMaterialId: manifest.baseMaterialId,
      chunks: manifest.chunks,
      playerSpawn: position,
      travelPoints: manifest.travelPoints,
      editorLayers: manifest.editorLayers,
      activeLayerId: manifest.activeLayerId,
    );
    _manifestDirty = true;
  }

  EnvironmentDocument buildDocument() {
    final strokes = <TerrainStroke>[];
    final strokeKeys = <String>{};
    final objects = <PlacedEnvironmentObject>[];
    for (final coordinate in loadedCoordinates.toList()..sort()) {
      final chunk =
          _workingChunks[coordinate] ?? streamer.loadedChunks[coordinate];
      if (chunk == null) continue;
      final originX = coordinate.x * manifest.chunkSize;
      final originY = coordinate.y * manifest.chunkSize;
      for (final stroke in chunk.terrainStrokes) {
        final global = TerrainStroke(
          materialId: stroke.materialId,
          radius: stroke.radius,
          opacity: stroke.opacity,
          seed: stroke.seed,
          spacing: stroke.spacing,
          scatter: stroke.scatter,
          sizeJitter: stroke.sizeJitter,
          opacityJitter: stroke.opacityJitter,
          points: [
            for (final point in stroke.points)
              WorldPoint(point.x + originX, point.y + originY),
          ],
        );
        final key = jsonEncode(global.toJson());
        if (strokeKeys.add(key)) strokes.add(global);
      }
      objects.addAll(chunk.worldObjects);
    }
    return EnvironmentDocument(
      id: manifest.id,
      name: manifest.name,
      width: manifest.width.ceil(),
      height: manifest.height.ceil(),
      baseMaterialId: manifest.baseMaterialId,
      terrainStrokes: strokes,
      objects: objects,
      editorLayers: _editorLayers,
      activeLayerId: _activeLayerId,
    );
  }

  void _adoptLoadedChunks() {
    for (final entry in streamer.loadedChunks.entries) {
      _workingChunks.putIfAbsent(entry.key, () => entry.value);
    }
  }

  EnvironmentObjectBounds _boundsForObject(PlacedEnvironmentObject object) {
    final asset = catalog.objectById(object.assetId);
    final footprint = asset == null
        ? null
        : catalog.geometryForAsset(asset).footprint;
    if (footprint == null) {
      return EnvironmentObjectBounds(
        minX: object.x - 0.5,
        minY: object.y - 0.5,
        maxX: object.x + 0.5,
        maxY: object.y + 0.5,
      );
    }
    final points = environmentShapeOutline(footprint, object);
    return EnvironmentObjectBounds(
      minX: points.map((point) => point.x).reduce((a, b) => a < b ? a : b),
      minY: points.map((point) => point.y).reduce((a, b) => a < b ? a : b),
      maxX: points.map((point) => point.x).reduce((a, b) => a > b ? a : b),
      maxY: points.map((point) => point.y).reduce((a, b) => a > b ? a : b),
    );
  }
}

class _EditorChunkRepository implements EnvironmentChunkRepository {
  const _EditorChunkRepository({
    required this.fallback,
    required this.workingChunks,
  });

  final EnvironmentChunkRepository fallback;
  final Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument> workingChunks;

  @override
  Future<EnvironmentChunkDocument> load(
    EnvironmentChunkCoordinate coordinate,
  ) => workingChunks[coordinate] == null
      ? fallback.load(coordinate)
      : Future.value(workingChunks[coordinate]);
}
