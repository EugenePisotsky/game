import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

class EditorChunkSession {
  EditorChunkSession({
    required this.manifest,
    required this.catalog,
    required AssetBundle bundle,
  }) : _bundleRepository = AssetBundleEnvironmentChunkRepository(bundle) {
    _editorLayers = [
      for (final layer in manifest.editorLayers)
        EditorLayer.fromJson(layer.toJson()),
    ];
    _activeLayerId = manifest.activeLayerId;
    _repository = _EditorChunkRepository(
      fallback: _bundleRepository,
      workingChunks: _workingChunks,
    );
    streamer = EnvironmentChunkStreamingManager(
      manifest: manifest,
      repository: _repository,
      loadRadius: 1,
      unloadRadius: 2,
    );
  }

  final EnvironmentWorldManifest manifest;
  final EnvironmentCatalog catalog;
  final AssetBundleEnvironmentChunkRepository _bundleRepository;
  late final _EditorChunkRepository _repository;
  late final EnvironmentChunkStreamingManager streamer;
  final Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument>
  _workingChunks = {};
  final Set<EnvironmentChunkCoordinate> _dirtyChunks = {};
  late List<EditorLayer> _editorLayers;
  late String _activeLayerId;
  String? _lastDocumentSnapshot;

  Set<EnvironmentChunkCoordinate> get loadedCoordinates =>
      streamer.loadedChunks.keys.toSet();
  Set<EnvironmentChunkCoordinate> get dirtyCoordinates =>
      Set.unmodifiable(_dirtyChunks);

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
      _workingChunks[coordinate] = chunk;
      if (markDirty) _dirtyChunks.add(coordinate);
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
    _lastDocumentSnapshot = snapshot;
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
