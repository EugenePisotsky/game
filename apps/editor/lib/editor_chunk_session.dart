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
    _preserveLiveReplicatedAreas(document, current);
    _lastDocumentSnapshot = document.toJsonString(pretty: false);
    return document;
  }

  /// Polygonal environment records are copied into every chunk they overlap.
  /// A chunk loaded after an edit can therefore contain an older copy of the
  /// same record. Keep the live editor definition authoritative whenever the
  /// streamed document still contains that record; the next [capture] writes
  /// it into every currently loaded replica.
  void _preserveLiveReplicatedAreas(
    EnvironmentDocument streamed,
    EnvironmentDocument live,
  ) {
    final liveSurfaces = {for (final value in live.surfaces) value.id: value};
    for (var index = 0; index < streamed.surfaces.length; index++) {
      final value = liveSurfaces[streamed.surfaces[index].id];
      if (value != null) {
        streamed.surfaces[index] = EnvironmentSurface.fromJson(value.toJson());
      }
    }

    final liveLiquids = {
      for (final value in live.liquidVolumes) value.id: value,
    };
    for (var index = 0; index < streamed.liquidVolumes.length; index++) {
      final value = liveLiquids[streamed.liquidVolumes[index].id];
      if (value != null) {
        streamed.liquidVolumes[index] = EnvironmentLiquidVolume.fromJson(
          value.toJson(),
        );
      }
    }

    final liveConnectors = {
      for (final value in live.surfaceConnectors) value.id: value,
    };
    for (var index = 0; index < streamed.surfaceConnectors.length; index++) {
      final value = liveConnectors[streamed.surfaceConnectors[index].id];
      if (value != null) {
        streamed.surfaceConnectors[index] =
            EnvironmentSurfaceConnector.fromJson(value.toJson());
      }
    }

    final liveRegions = {
      for (final value in live.terrainRegions) value.id: value,
    };
    for (var index = 0; index < streamed.terrainRegions.length; index++) {
      final value = liveRegions[streamed.terrainRegions[index].id];
      if (value != null) {
        streamed.terrainRegions[index] = TerrainRegion.fromJson(value.toJson());
      }
    }
  }

  void capture(EnvironmentDocument document, {bool markDirty = true}) {
    if (manifest.baseMaterialId != document.baseMaterialId ||
        manifest.activeSurfaceId != document.activeSurfaceId) {
      _manifest = EnvironmentWorldManifest(
        id: manifest.id,
        name: manifest.name,
        chunkSize: manifest.chunkSize,
        width: manifest.width,
        height: manifest.height,
        baseMaterialId: document.baseMaterialId,
        chunks: manifest.chunks,
        playerSpawn: manifest.playerSpawn,
        travelPoints: manifest.travelPoints,
        editorLayers: manifest.editorLayers,
        activeLayerId: manifest.activeLayerId,
        playerSpawnSurfaceId: manifest.playerSpawnSurfaceId,
        activeSurfaceId: document.activeSurfaceId,
      );
      _manifestDirty = true;
    }
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
    await _synchronizeLiveReplicatedAreas(document);
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
        playerSpawnSurfaceId: manifest.playerSpawnSurfaceId,
        activeSurfaceId: document.activeSurfaceId,
      ),
    );
    _dirtyChunks.clear();
    _manifestDirty = false;
    _workingChunks.removeWhere(
      (coordinate, _) => !loadedCoordinates.contains(coordinate),
    );
    _lastDocumentSnapshot = snapshot;
  }

  Future<void> _synchronizeLiveReplicatedAreas(
    EnvironmentDocument document,
  ) async {
    final split = EnvironmentChunkedWorld.fromDocument(
      document,
      chunkSize: manifest.chunkSize,
      worldWidth: manifest.width,
      worldHeight: manifest.height,
      playerSpawn: manifest.playerSpawn.toWorld(manifest.chunkSize),
      objectBounds: _boundsForObject,
    );
    final liveSurfaceIds = {for (final value in document.surfaces) value.id};
    final liveLiquidIds = {
      for (final value in document.liquidVolumes) value.id,
    };
    final liveConnectorIds = {
      for (final value in document.surfaceConnectors) value.id,
    };
    final liveRegionIds = {
      for (final value in document.terrainRegions) value.id,
    };
    final entries = await Future.wait([
      for (final coordinate in manifest.chunks)
        _repository
            .load(coordinate)
            .then((chunk) => MapEntry(coordinate, chunk)),
    ]);
    for (final entry in entries) {
      final coordinate = entry.key;
      final previous = entry.value;
      final desired = split.chunks[coordinate];
      if (desired == null) continue;
      final rebuilt = EnvironmentChunkDocument(
        worldId: previous.worldId,
        coordinate: coordinate,
        size: previous.size,
        baseMaterialId: manifest.baseMaterialId,
        surfaces: _mergeReplicatedRecords(
          previous.surfaces,
          desired.surfaces,
          liveSurfaceIds,
          (value) => value.id,
        ),
        liquidVolumes: _mergeReplicatedRecords(
          previous.liquidVolumes,
          desired.liquidVolumes,
          liveLiquidIds,
          (value) => value.id,
        ),
        surfaceConnectors: _mergeReplicatedRecords(
          previous.surfaceConnectors,
          desired.surfaceConnectors,
          liveConnectorIds,
          (value) => value.id,
        ),
        terrainRegions: _mergeReplicatedRecords(
          previous.terrainRegions,
          desired.terrainRegions,
          liveRegionIds,
          (value) => value.id,
        ),
        terrainStrokes: previous.terrainStrokes,
        objects: previous.objects,
        overlapObjectIds: previous.overlapObjectIds,
      );
      _workingChunks[coordinate] = rebuilt;
      if (rebuilt.toJsonString(pretty: false) !=
          previous.toJsonString(pretty: false)) {
        _dirtyChunks.add(coordinate);
      }
    }
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
        surfaces: previous.surfaces,
        liquidVolumes: previous.liquidVolumes,
        surfaceConnectors: previous.surfaceConnectors,
        terrainRegions: previous.terrainRegions,
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
    behaviorProfileId: object.behaviorProfileId,
    liquidInteraction: object.liquidInteraction,
    liquidDraft: object.liquidDraft,
    supportSurfaceId: object.supportSurfaceId,
    crossSurfaceOcclusion: object.crossSurfaceOcclusion,
    occlusionHeight: object.occlusionHeight,
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
      playerSpawnSurfaceId: manifest.activeSurfaceId,
      activeSurfaceId: manifest.activeSurfaceId,
    );
    _manifestDirty = true;
  }

  EnvironmentDocument buildDocument() {
    final surfaces = <EnvironmentSurface>[];
    final surfaceIds = <String>{};
    final liquids = <EnvironmentLiquidVolume>[];
    final liquidIds = <String>{};
    final connectors = <EnvironmentSurfaceConnector>[];
    final connectorIds = <String>{};
    final regions = <TerrainRegion>[];
    final regionIds = <String>{};
    final strokes = <TerrainStroke>[];
    final strokeKeys = <String>{};
    final objects = <PlacedEnvironmentObject>[];
    for (final coordinate in loadedCoordinates.toList()..sort()) {
      final chunk =
          _workingChunks[coordinate] ?? streamer.loadedChunks[coordinate];
      if (chunk == null) continue;
      final originX = coordinate.x * manifest.chunkSize;
      final originY = coordinate.y * manifest.chunkSize;
      WorldPoint globalPoint(WorldPoint point) =>
          WorldPoint(point.x + originX, point.y + originY);
      for (final surface in chunk.surfaces) {
        if (!surfaceIds.add(surface.id)) continue;
        surfaces.add(
          EnvironmentSurface(
            id: surface.id,
            name: surface.name,
            materialId: surface.materialId,
            points: [for (final point in surface.points) globalPoint(point)],
            kind: surface.kind,
            height: switch (surface.height.kind) {
              EnvironmentSurfaceHeightKind.flat =>
                EnvironmentSurfaceHeight.flat(surface.height.elevation),
              EnvironmentSurfaceHeightKind.linearRamp =>
                EnvironmentSurfaceHeight.linearRamp(
                  elevation: surface.height.elevation,
                  endElevation: surface.height.endElevation,
                  rampStart: globalPoint(surface.height.rampStart!),
                  rampEnd: globalPoint(surface.height.rampEnd!),
                ),
            },
            walkable: surface.walkable,
            drawsBaseMaterial: surface.drawsBaseMaterial,
            order: surface.order,
            visibilityGroupId: surface.visibilityGroupId,
          ),
        );
      }
      for (final liquid in chunk.liquidVolumes) {
        if (!liquidIds.add(liquid.id)) continue;
        liquids.add(
          EnvironmentLiquidVolume(
            id: liquid.id,
            name: liquid.name,
            bedSurfaceId: liquid.bedSurfaceId,
            materialId: liquid.materialId,
            points: [for (final point in liquid.points) globalPoint(point)],
            surfaceElevation: liquid.surfaceElevation,
            depth: liquid.depth,
            endDepth: liquid.endDepth,
            depthRampStart: liquid.depthRampStart == null
                ? null
                : globalPoint(liquid.depthRampStart!),
            depthRampEnd: liquid.depthRampEnd == null
                ? null
                : globalPoint(liquid.depthRampEnd!),
            edgeBlend: liquid.edgeBlend,
            opacity: liquid.opacity,
            textureScale: liquid.textureScale,
            order: liquid.order,
          ),
        );
      }
      for (final connector in chunk.surfaceConnectors) {
        if (!connectorIds.add(connector.id)) continue;
        connectors.add(
          EnvironmentSurfaceConnector(
            id: connector.id,
            fromSurfaceId: connector.fromSurfaceId,
            toSurfaceId: connector.toSurfaceId,
            from: globalPoint(connector.from),
            to: globalPoint(connector.to),
            kind: connector.kind,
            width: connector.width,
            bidirectional: connector.bidirectional,
            cost: connector.cost,
          ),
        );
      }
      for (final region in chunk.terrainRegions) {
        if (!regionIds.add(region.id)) continue;
        regions.add(
          TerrainRegion(
            id: region.id,
            materialId: region.materialId,
            resetsToDefault: region.resetsToDefault,
            edgeBlend: region.edgeBlend,
            opacity: region.opacity,
            textureScale: region.textureScale,
            seed: region.seed,
            order: region.order,
            surfaceId: region.surfaceId,
            points: [
              for (final point in region.points)
                WorldPoint(point.x + originX, point.y + originY),
            ],
          ),
        );
      }
      for (final stroke in chunk.terrainStrokes) {
        final global = TerrainStroke(
          materialId: stroke.materialId,
          radius: stroke.radius,
          opacity: stroke.opacity,
          resetsToBase: stroke.resetsToBase,
          seed: stroke.seed,
          spacing: stroke.spacing,
          scatter: stroke.scatter,
          sizeJitter: stroke.sizeJitter,
          opacityJitter: stroke.opacityJitter,
          surfaceId: stroke.surfaceId,
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
    regions.sort((a, b) => a.order.compareTo(b.order));
    return EnvironmentDocument(
      id: manifest.id,
      name: manifest.name,
      width: manifest.width.ceil(),
      height: manifest.height.ceil(),
      baseMaterialId: manifest.baseMaterialId,
      surfaces: [
        EnvironmentSurface(
          id: environmentBaseSurfaceId,
          name: 'Ground',
          materialId: manifest.baseMaterialId,
          points: [
            const WorldPoint(0, 0),
            WorldPoint(manifest.width, 0),
            WorldPoint(manifest.width, manifest.height),
            WorldPoint(0, manifest.height),
          ],
        ),
        ...surfaces,
      ],
      liquidVolumes: liquids,
      surfaceConnectors: connectors,
      terrainRegions: regions,
      terrainStrokes: strokes,
      objects: objects,
      editorLayers: _editorLayers,
      activeLayerId: _activeLayerId,
      activeSurfaceId:
          surfaceIds.contains(manifest.activeSurfaceId) ||
              manifest.activeSurfaceId == environmentBaseSurfaceId
          ? manifest.activeSurfaceId
          : environmentBaseSurfaceId,
    );
  }

  void _adoptLoadedChunks() {
    for (final entry in streamer.loadedChunks.entries) {
      _workingChunks.putIfAbsent(entry.key, () => entry.value);
    }
  }

  EnvironmentObjectBounds _boundsForObject(PlacedEnvironmentObject object) {
    final asset = catalog.objectById(object.assetId);
    final footprints = asset == null
        ? const <EnvironmentGeometryShape>[]
        : catalog
              .geometryForAsset(asset, direction: object.direction.name)
              .footprints;
    if (footprints.isEmpty) {
      return EnvironmentObjectBounds(
        minX: object.x - 0.5,
        minY: object.y - 0.5,
        maxX: object.x + 0.5,
        maxY: object.y + 0.5,
      );
    }
    final points = [
      for (final footprint in footprints)
        ...environmentShapeOutline(footprint, object),
    ];
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

List<T> _mergeReplicatedRecords<T>(
  List<T> existing,
  List<T> desired,
  Set<String> liveIds,
  String Function(T value) idOf,
) => [
  for (final value in existing)
    if (!liveIds.contains(idOf(value))) value,
  ...desired,
];
