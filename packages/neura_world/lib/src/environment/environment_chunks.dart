import 'dart:convert';
import 'dart:math' as math;

import 'environment_document.dart';

class EnvironmentChunkCoordinate
    implements Comparable<EnvironmentChunkCoordinate> {
  const EnvironmentChunkCoordinate(this.x, this.y);

  final int x;
  final int y;

  String get key => '${x}_$y';

  Map<String, Object> toJson() => {'x': x, 'y': y};

  factory EnvironmentChunkCoordinate.fromJson(Map<String, Object?> json) =>
      EnvironmentChunkCoordinate(
        (json['x'] as num).toInt(),
        (json['y'] as num).toInt(),
      );

  @override
  int compareTo(EnvironmentChunkCoordinate other) {
    final row = y.compareTo(other.y);
    return row != 0 ? row : x.compareTo(other.x);
  }

  @override
  bool operator ==(Object other) =>
      other is EnvironmentChunkCoordinate && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => '($x, $y)';
}

class ChunkLocalPosition {
  const ChunkLocalPosition({
    required this.chunk,
    required this.localX,
    required this.localY,
  });

  final EnvironmentChunkCoordinate chunk;
  final double localX;
  final double localY;

  WorldPoint toWorld(double chunkSize) =>
      WorldPoint(chunk.x * chunkSize + localX, chunk.y * chunkSize + localY);

  Map<String, Object> toJson() => {
    'chunk': chunk.toJson(),
    'localPosition': {'x': localX, 'y': localY},
  };

  factory ChunkLocalPosition.fromWorld(
    WorldPoint point, {
    required double chunkSize,
  }) {
    final chunk = EnvironmentChunkCoordinate(
      (point.x / chunkSize).floor(),
      (point.y / chunkSize).floor(),
    );
    return ChunkLocalPosition(
      chunk: chunk,
      localX: point.x - chunk.x * chunkSize,
      localY: point.y - chunk.y * chunkSize,
    );
  }
}

class EnvironmentObjectBounds {
  const EnvironmentObjectBounds({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  Map<String, Object> toJson() => {
    'min': {'x': minX, 'y': minY},
    'max': {'x': maxX, 'y': maxY},
  };

  factory EnvironmentObjectBounds.fromJson(Map<String, Object?> json) {
    final min = json['min'] as Map<String, Object?>;
    final max = json['max'] as Map<String, Object?>;
    return EnvironmentObjectBounds(
      minX: (min['x'] as num).toDouble(),
      minY: (min['y'] as num).toDouble(),
      maxX: (max['x'] as num).toDouble(),
      maxY: (max['y'] as num).toDouble(),
    );
  }

  bool overlapsChunk(EnvironmentChunkCoordinate coordinate, double chunkSize) {
    final left = coordinate.x * chunkSize;
    final top = coordinate.y * chunkSize;
    return maxX >= left &&
        minX <= left + chunkSize &&
        maxY >= top &&
        minY <= top + chunkSize;
  }
}

class ChunkPlacedEnvironmentObject {
  ChunkPlacedEnvironmentObject({
    required this.id,
    required this.assetId,
    required this.localX,
    required this.localY,
    required this.editorLayerId,
    required this.bounds,
    this.verticalOffset = 0,
    this.sortBias = 0,
    this.direction = EnvironmentDirection.south,
    this.behaviorProfileId,
    this.liquidInteraction = EnvironmentLiquidInteraction.automatic,
    this.liquidDraft = 0.12,
    this.supportSurfaceId = environmentBaseSurfaceId,
    this.crossSurfaceOcclusion = false,
    this.occlusionHeight = 0,
  });

  final String id;
  final String assetId;
  final double localX;
  final double localY;
  final double verticalOffset;
  final double sortBias;
  final String editorLayerId;
  final EnvironmentDirection direction;
  final String? behaviorProfileId;
  final EnvironmentLiquidInteraction liquidInteraction;
  final double liquidDraft;
  final String supportSurfaceId;
  final bool crossSurfaceOcclusion;
  final double occlusionHeight;
  final EnvironmentObjectBounds bounds;

  PlacedEnvironmentObject toWorldObject(
    EnvironmentChunkCoordinate coordinate,
    double chunkSize,
  ) => PlacedEnvironmentObject(
    id: id,
    assetId: assetId,
    x: coordinate.x * chunkSize + localX,
    y: coordinate.y * chunkSize + localY,
    verticalOffset: verticalOffset,
    sortBias: sortBias,
    editorLayerId: editorLayerId,
    direction: direction,
    behaviorProfileId: behaviorProfileId,
    liquidInteraction: liquidInteraction,
    liquidDraft: liquidDraft,
    supportSurfaceId: supportSurfaceId,
    crossSurfaceOcclusion: crossSurfaceOcclusion,
    occlusionHeight: occlusionHeight,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'assetId': assetId,
    'localPosition': {'x': localX, 'y': localY},
    'verticalOffset': verticalOffset,
    if (sortBias != 0) 'sortBias': sortBias,
    'direction': direction.name,
    'behaviorProfileId': ?behaviorProfileId,
    if (liquidInteraction != EnvironmentLiquidInteraction.automatic)
      'liquidInteraction': liquidInteraction.name,
    if (liquidDraft != 0.12) 'liquidDraft': liquidDraft,
    'supportSurfaceId': supportSurfaceId,
    if (crossSurfaceOcclusion) 'crossSurfaceOcclusion': true,
    if (occlusionHeight != 0) 'occlusionHeight': occlusionHeight,
    'editorLayerId': editorLayerId,
    'bounds': bounds.toJson(),
  };

  factory ChunkPlacedEnvironmentObject.fromJson(Map<String, Object?> json) {
    final position = json['localPosition'] as Map<String, Object?>;
    return ChunkPlacedEnvironmentObject(
      id: json['id'] as String,
      assetId: json['assetId'] as String,
      localX: (position['x'] as num).toDouble(),
      localY: (position['y'] as num).toDouble(),
      verticalOffset: (json['verticalOffset'] as num? ?? 0).toDouble(),
      sortBias: (json['sortBias'] as num? ?? 0).toDouble(),
      direction: EnvironmentDirection.values.byName(
        json['direction'] as String? ?? EnvironmentDirection.south.name,
      ),
      behaviorProfileId: json['behaviorProfileId'] as String?,
      liquidInteraction: EnvironmentLiquidInteraction.values.byName(
        json['liquidInteraction'] as String? ??
            EnvironmentLiquidInteraction.automatic.name,
      ),
      liquidDraft: (json['liquidDraft'] as num? ?? 0.12).toDouble(),
      supportSurfaceId: json['supportSurfaceId'] as String,
      crossSurfaceOcclusion: json['crossSurfaceOcclusion'] as bool? ?? false,
      occlusionHeight: (json['occlusionHeight'] as num? ?? 0).toDouble(),
      editorLayerId:
          json['editorLayerId'] as String? ?? EnvironmentDocument.rootLayerId,
      bounds: EnvironmentObjectBounds.fromJson(
        json['bounds'] as Map<String, Object?>,
      ),
    );
  }
}

class EnvironmentChunkDocument {
  EnvironmentChunkDocument({
    required this.worldId,
    required this.coordinate,
    required this.size,
    required this.baseMaterialId,
    List<EnvironmentSurface>? surfaces,
    List<EnvironmentLiquidVolume>? liquidVolumes,
    List<EnvironmentSurfaceConnector>? surfaceConnectors,
    List<TerrainRegion>? terrainRegions,
    List<TerrainStroke>? terrainStrokes,
    List<ChunkPlacedEnvironmentObject>? objects,
    Set<String>? overlapObjectIds,
    this.schemaVersion = currentSchemaVersion,
  }) : surfaces = List.of(surfaces ?? const []),
       liquidVolumes = List.of(liquidVolumes ?? const []),
       surfaceConnectors = List.of(surfaceConnectors ?? const []),
       terrainRegions = List.of(terrainRegions ?? const []),
       terrainStrokes = List.of(terrainStrokes ?? const []),
       objects = List.of(objects ?? const []),
       overlapObjectIds = Set.of(overlapObjectIds ?? const {});

  static const currentSchemaVersion = 4;

  final int schemaVersion;
  final String worldId;
  final EnvironmentChunkCoordinate coordinate;
  final double size;
  final String baseMaterialId;
  final List<EnvironmentSurface> surfaces;
  final List<EnvironmentLiquidVolume> liquidVolumes;
  final List<EnvironmentSurfaceConnector> surfaceConnectors;
  final List<TerrainRegion> terrainRegions;
  final List<TerrainStroke> terrainStrokes;
  final List<ChunkPlacedEnvironmentObject> objects;
  final Set<String> overlapObjectIds;

  Iterable<PlacedEnvironmentObject> get worldObjects =>
      objects.map((object) => object.toWorldObject(coordinate, size));

  Set<String> get referencedAssetIds => {
    for (final region in terrainRegions)
      if (!region.resetsToDefault) region.materialId,
    for (final stroke in terrainStrokes) stroke.materialId,
    for (final surface in surfaces) surface.materialId,
    for (final liquid in liquidVolumes) liquid.materialId,
    for (final object in objects) object.assetId,
  };

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'worldId': worldId,
    'coordinate': coordinate.toJson(),
    'size': size,
    'baseMaterialId': baseMaterialId,
    'surfaces': [for (final surface in surfaces) surface.toJson()],
    'liquidVolumes': [for (final liquid in liquidVolumes) liquid.toJson()],
    'surfaceConnectors': [
      for (final connector in surfaceConnectors) connector.toJson(),
    ],
    'terrainRegions': [for (final region in terrainRegions) region.toJson()],
    'terrainStrokes': [for (final stroke in terrainStrokes) stroke.toJson()],
    'objects': [for (final object in objects) object.toJson()],
    'overlapObjectIds': overlapObjectIds.toList()..sort(),
  };

  String toJsonString({bool pretty = true}) => pretty
      ? const JsonEncoder.withIndent('  ').convert(toJson())
      : jsonEncode(toJson());

  factory EnvironmentChunkDocument.fromJson(Map<String, Object?> json) {
    final version = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    if (version != currentSchemaVersion) {
      throw FormatException('Unsupported environment chunk schema $version.');
    }
    return EnvironmentChunkDocument(
      schemaVersion: version,
      worldId: json['worldId'] as String,
      coordinate: EnvironmentChunkCoordinate.fromJson(
        json['coordinate'] as Map<String, Object?>,
      ),
      size: (json['size'] as num).toDouble(),
      baseMaterialId: json['baseMaterialId'] as String,
      surfaces: [
        for (final value in json['surfaces'] as List<Object?>? ?? const [])
          EnvironmentSurface.fromJson(value as Map<String, Object?>),
      ],
      liquidVolumes: [
        for (final value in json['liquidVolumes'] as List<Object?>? ?? const [])
          EnvironmentLiquidVolume.fromJson(value as Map<String, Object?>),
      ],
      surfaceConnectors: [
        for (final value
            in json['surfaceConnectors'] as List<Object?>? ?? const [])
          EnvironmentSurfaceConnector.fromJson(value as Map<String, Object?>),
      ],
      terrainRegions: [
        for (final value
            in json['terrainRegions'] as List<Object?>? ?? const [])
          TerrainRegion.fromJson(value as Map<String, Object?>),
      ],
      terrainStrokes: [
        for (final value
            in json['terrainStrokes'] as List<Object?>? ?? const [])
          TerrainStroke.fromJson(value as Map<String, Object?>),
      ],
      objects: [
        for (final value in json['objects'] as List<Object?>? ?? const [])
          ChunkPlacedEnvironmentObject.fromJson(value as Map<String, Object?>),
      ],
      overlapObjectIds: {
        for (final value
            in json['overlapObjectIds'] as List<Object?>? ?? const [])
          value as String,
      },
    );
  }

  factory EnvironmentChunkDocument.fromJsonString(String source) =>
      EnvironmentChunkDocument.fromJson(
        jsonDecode(source) as Map<String, Object?>,
      );
}

class EnvironmentTravelPoint {
  const EnvironmentTravelPoint({required this.id, required this.position});

  final String id;
  final ChunkLocalPosition position;

  Map<String, Object> toJson() => {'id': id, ...position.toJson()};
}

class EnvironmentWorldManifest {
  EnvironmentWorldManifest({
    required this.id,
    required this.name,
    required this.chunkSize,
    required this.width,
    required this.height,
    required this.baseMaterialId,
    required this.chunks,
    required this.playerSpawn,
    List<EnvironmentTravelPoint>? travelPoints,
    List<EditorLayer>? editorLayers,
    String? activeLayerId,
    this.playerSpawnSurfaceId = environmentBaseSurfaceId,
    this.activeSurfaceId = environmentBaseSurfaceId,
    this.schemaVersion = currentSchemaVersion,
  }) : travelPoints = List.of(travelPoints ?? const []),
       editorLayers = List.of(
         editorLayers ?? EnvironmentDocument.defaultEditorLayers(),
       ),
       activeLayerId = activeLayerId ?? EnvironmentDocument.rootLayerId;

  static const currentSchemaVersion = 2;

  final int schemaVersion;
  final String id;
  final String name;
  final double chunkSize;
  final double width;
  final double height;
  final String baseMaterialId;
  final List<EnvironmentChunkCoordinate> chunks;
  final ChunkLocalPosition playerSpawn;
  final List<EnvironmentTravelPoint> travelPoints;
  final List<EditorLayer> editorLayers;
  final String activeLayerId;
  final String playerSpawnSurfaceId;
  final String activeSurfaceId;

  bool containsChunk(EnvironmentChunkCoordinate coordinate) =>
      chunks.contains(coordinate);

  EnvironmentChunkCoordinate coordinateFor(WorldPoint point) =>
      EnvironmentChunkCoordinate(
        (point.x / chunkSize).floor(),
        (point.y / chunkSize).floor(),
      );

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    'chunkSize': chunkSize,
    'width': width,
    'height': height,
    'baseMaterialId': baseMaterialId,
    'chunks': [for (final chunk in chunks) chunk.toJson()],
    'playerSpawn': playerSpawn.toJson(),
    'travelPoints': [for (final point in travelPoints) point.toJson()],
    'editorLayers': [for (final layer in editorLayers) layer.toJson()],
    'activeLayerId': activeLayerId,
    'playerSpawnSurfaceId': playerSpawnSurfaceId,
    'activeSurfaceId': activeSurfaceId,
  };

  String toJsonString({bool pretty = true}) => pretty
      ? const JsonEncoder.withIndent('  ').convert(toJson())
      : jsonEncode(toJson());

  factory EnvironmentWorldManifest.fromJson(Map<String, Object?> json) {
    final chunkSize = (json['chunkSize'] as num).toDouble();
    ChunkLocalPosition position(Map<String, Object?> value) {
      final chunk = EnvironmentChunkCoordinate.fromJson(
        value['chunk'] as Map<String, Object?>,
      );
      final local = value['localPosition'] as Map<String, Object?>;
      return ChunkLocalPosition(
        chunk: chunk,
        localX: (local['x'] as num).toDouble(),
        localY: (local['y'] as num).toDouble(),
      );
    }

    final version = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    if (version != currentSchemaVersion) {
      throw FormatException(
        'Unsupported environment manifest schema $version.',
      );
    }
    return EnvironmentWorldManifest(
      schemaVersion: version,
      id: json['id'] as String,
      name: json['name'] as String,
      chunkSize: chunkSize,
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      baseMaterialId: json['baseMaterialId'] as String,
      chunks: [
        for (final value in json['chunks'] as List<Object?>)
          EnvironmentChunkCoordinate.fromJson(value as Map<String, Object?>),
      ]..sort(),
      playerSpawn: position(json['playerSpawn'] as Map<String, Object?>),
      travelPoints: [
        for (final value in json['travelPoints'] as List<Object?>? ?? const [])
          EnvironmentTravelPoint(
            id: (value as Map<String, Object?>)['id'] as String,
            position: position(value),
          ),
      ],
      editorLayers: [
        for (final value in json['editorLayers'] as List<Object?>? ?? const [])
          EditorLayer.fromJson(value as Map<String, Object?>),
      ],
      activeLayerId: json['activeLayerId'] as String?,
      playerSpawnSurfaceId: json['playerSpawnSurfaceId'] as String,
      activeSurfaceId: json['activeSurfaceId'] as String,
    );
  }

  factory EnvironmentWorldManifest.fromJsonString(String source) =>
      EnvironmentWorldManifest.fromJson(
        jsonDecode(source) as Map<String, Object?>,
      );
}

typedef EnvironmentObjectBoundsResolver = EnvironmentObjectBounds Function(
  PlacedEnvironmentObject object,
);

class EnvironmentChunkedWorld {
  const EnvironmentChunkedWorld({required this.manifest, required this.chunks});

  final EnvironmentWorldManifest manifest;
  final Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument> chunks;

  factory EnvironmentChunkedWorld.fromDocument(
    EnvironmentDocument document, {
    double chunkSize = 32,
    double? worldWidth,
    double? worldHeight,
    WorldPoint playerSpawn = const WorldPoint(0, 0),
    EnvironmentObjectBoundsResolver? objectBounds,
  }) {
    final width = worldWidth ?? document.width.toDouble();
    final height = worldHeight ?? document.height.toDouble();
    final columns = (width / chunkSize).ceil();
    final rows = (height / chunkSize).ceil();
    final coordinates = [
      for (var y = 0; y < rows; y++)
        for (var x = 0; x < columns; x++) EnvironmentChunkCoordinate(x, y),
    ];
    final surfaces = <EnvironmentChunkCoordinate, List<EnvironmentSurface>>{
      for (final coordinate in coordinates) coordinate: [],
    };
    final liquids = <EnvironmentChunkCoordinate, List<EnvironmentLiquidVolume>>{
      for (final coordinate in coordinates) coordinate: [],
    };
    final connectors =
        <EnvironmentChunkCoordinate, List<EnvironmentSurfaceConnector>>{
          for (final coordinate in coordinates) coordinate: [],
        };
    final regions = <EnvironmentChunkCoordinate, List<TerrainRegion>>{
      for (final coordinate in coordinates) coordinate: [],
    };
    final strokes = <EnvironmentChunkCoordinate, List<TerrainStroke>>{
      for (final coordinate in coordinates) coordinate: [],
    };
    final objects =
        <EnvironmentChunkCoordinate, List<ChunkPlacedEnvironmentObject>>{
          for (final coordinate in coordinates) coordinate: [],
        };

    EnvironmentObjectBounds polygonBounds(
      List<WorldPoint> points, {
      double padding = 0,
    }) => EnvironmentObjectBounds(
      minX: points.map((point) => point.x).reduce(math.min) - padding,
      minY: points.map((point) => point.y).reduce(math.min) - padding,
      maxX: points.map((point) => point.x).reduce(math.max) + padding,
      maxY: points.map((point) => point.y).reduce(math.max) + padding,
    );

    WorldPoint localPoint(
      WorldPoint point,
      EnvironmentChunkCoordinate coordinate,
    ) => WorldPoint(
      point.x - coordinate.x * chunkSize,
      point.y - coordinate.y * chunkSize,
    );

    EnvironmentSurfaceHeight localHeight(
      EnvironmentSurfaceHeight height,
      EnvironmentChunkCoordinate coordinate,
    ) => switch (height.kind) {
      EnvironmentSurfaceHeightKind.flat => EnvironmentSurfaceHeight.flat(
        height.elevation,
      ),
      EnvironmentSurfaceHeightKind.linearRamp =>
        EnvironmentSurfaceHeight.linearRamp(
          elevation: height.elevation,
          endElevation: height.endElevation,
          rampStart: localPoint(height.rampStart!, coordinate),
          rampEnd: localPoint(height.rampEnd!, coordinate),
        ),
    };

    for (final surface in document.surfaces) {
      // The rectangular base surface is derived from the manifest dimensions.
      if (surface.id == environmentBaseSurfaceId || surface.points.length < 3) {
        continue;
      }
      final bounds = polygonBounds(surface.points);
      for (final coordinate in coordinates) {
        if (!bounds.overlapsChunk(coordinate, chunkSize)) continue;
        surfaces[coordinate]!.add(
          EnvironmentSurface(
            id: surface.id,
            name: surface.name,
            materialId: surface.materialId,
            points: [
              for (final point in surface.points) localPoint(point, coordinate),
            ],
            kind: surface.kind,
            height: localHeight(surface.height, coordinate),
            walkable: surface.walkable,
            drawsBaseMaterial: surface.drawsBaseMaterial,
            order: surface.order,
            visibilityGroupId: surface.visibilityGroupId,
          ),
        );
      }
    }

    for (final liquid in document.liquidVolumes) {
      if (liquid.points.length < 3) continue;
      final bounds = polygonBounds(liquid.points, padding: liquid.edgeBlend);
      for (final coordinate in coordinates) {
        if (!bounds.overlapsChunk(coordinate, chunkSize)) continue;
        liquids[coordinate]!.add(
          EnvironmentLiquidVolume(
            id: liquid.id,
            name: liquid.name,
            bedSurfaceId: liquid.bedSurfaceId,
            materialId: liquid.materialId,
            points: [
              for (final point in liquid.points) localPoint(point, coordinate),
            ],
            surfaceElevation: liquid.surfaceElevation,
            depth: liquid.depth,
            endDepth: liquid.endDepth,
            depthRampStart: liquid.depthRampStart == null
                ? null
                : localPoint(liquid.depthRampStart!, coordinate),
            depthRampEnd: liquid.depthRampEnd == null
                ? null
                : localPoint(liquid.depthRampEnd!, coordinate),
            edgeBlend: liquid.edgeBlend,
            opacity: liquid.opacity,
            textureScale: liquid.textureScale,
            order: liquid.order,
          ),
        );
      }
    }

    for (final connector in document.surfaceConnectors) {
      final bounds = polygonBounds([
        connector.from,
        connector.to,
      ], padding: connector.width);
      for (final coordinate in coordinates) {
        if (!bounds.overlapsChunk(coordinate, chunkSize)) continue;
        connectors[coordinate]!.add(
          EnvironmentSurfaceConnector(
            id: connector.id,
            fromSurfaceId: connector.fromSurfaceId,
            toSurfaceId: connector.toSurfaceId,
            from: localPoint(connector.from, coordinate),
            to: localPoint(connector.to, coordinate),
            kind: connector.kind,
            width: connector.width,
            bidirectional: connector.bidirectional,
            cost: connector.cost,
          ),
        );
      }
    }

    for (final region in document.terrainRegions) {
      if (region.points.length < 3) continue;
      final minX =
          region.points.map((point) => point.x).reduce(math.min) -
          region.edgeBlend;
      final minY =
          region.points.map((point) => point.y).reduce(math.min) -
          region.edgeBlend;
      final maxX =
          region.points.map((point) => point.x).reduce(math.max) +
          region.edgeBlend;
      final maxY =
          region.points.map((point) => point.y).reduce(math.max) +
          region.edgeBlend;
      final bounds = EnvironmentObjectBounds(
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY,
      );
      for (final coordinate in coordinates) {
        if (!bounds.overlapsChunk(coordinate, chunkSize)) continue;
        regions[coordinate]!.add(
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
                WorldPoint(
                  point.x - coordinate.x * chunkSize,
                  point.y - coordinate.y * chunkSize,
                ),
            ],
          ),
        );
      }
    }

    for (final stroke in document.terrainStrokes) {
      if (stroke.points.isEmpty) continue;
      final extent = stroke.maximumStampExtent;
      final minX =
          stroke.points
              .map((point) => point.x)
              .reduce((a, b) => a < b ? a : b) -
          extent;
      final minY =
          stroke.points
              .map((point) => point.y)
              .reduce((a, b) => a < b ? a : b) -
          extent;
      final maxX =
          stroke.points
              .map((point) => point.x)
              .reduce((a, b) => a > b ? a : b) +
          extent;
      final maxY =
          stroke.points
              .map((point) => point.y)
              .reduce((a, b) => a > b ? a : b) +
          extent;
      for (final coordinate in coordinates) {
        final bounds = EnvironmentObjectBounds(
          minX: minX,
          minY: minY,
          maxX: maxX,
          maxY: maxY,
        );
        if (!bounds.overlapsChunk(coordinate, chunkSize)) continue;
        strokes[coordinate]!.add(
          TerrainStroke(
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
                WorldPoint(
                  point.x - coordinate.x * chunkSize,
                  point.y - coordinate.y * chunkSize,
                ),
            ],
          ),
        );
      }
    }

    for (final object in document.objects) {
      final owner = EnvironmentChunkCoordinate(
        (object.x / chunkSize).floor(),
        (object.y / chunkSize).floor(),
      );
      if (!objects.containsKey(owner)) continue;
      final bounds =
          objectBounds?.call(object) ??
          EnvironmentObjectBounds(
            minX: object.x - 0.5,
            minY: object.y - 0.5,
            maxX: object.x + 0.5,
            maxY: object.y + 0.5,
          );
      objects[owner]!.add(
        ChunkPlacedEnvironmentObject(
          id: object.id,
          assetId: object.assetId,
          localX: object.x - owner.x * chunkSize,
          localY: object.y - owner.y * chunkSize,
          verticalOffset: object.verticalOffset,
          sortBias: object.sortBias,
          direction: object.direction,
          behaviorProfileId: object.behaviorProfileId,
          liquidInteraction: object.liquidInteraction,
          liquidDraft: object.liquidDraft,
          supportSurfaceId: object.supportSurfaceId,
          crossSurfaceOcclusion: object.crossSurfaceOcclusion,
          occlusionHeight: object.occlusionHeight,
          editorLayerId: object.editorLayerId,
          bounds: bounds,
        ),
      );
    }

    final chunks = {
      for (final coordinate in coordinates)
        coordinate: EnvironmentChunkDocument(
          worldId: document.id,
          coordinate: coordinate,
          size: chunkSize,
          baseMaterialId: document.baseMaterialId,
          surfaces: surfaces[coordinate],
          liquidVolumes: liquids[coordinate],
          surfaceConnectors: connectors[coordinate],
          terrainRegions: regions[coordinate],
          terrainStrokes: strokes[coordinate],
          objects: objects[coordinate],
          overlapObjectIds: {
            for (final entries in objects.values)
              for (final object in entries)
                if (object.bounds.overlapsChunk(coordinate, chunkSize))
                  object.id,
          },
        ),
    };
    return EnvironmentChunkedWorld(
      manifest: EnvironmentWorldManifest(
        id: document.id,
        name: document.name,
        chunkSize: chunkSize,
        width: width,
        height: height,
        baseMaterialId: document.baseMaterialId,
        chunks: coordinates,
        playerSpawn: ChunkLocalPosition.fromWorld(
          playerSpawn,
          chunkSize: chunkSize,
        ),
        editorLayers: document.editorLayers,
        activeLayerId: document.activeLayerId,
        playerSpawnSurfaceId: document.activeSurfaceId,
        activeSurfaceId: document.activeSurfaceId,
      ),
      chunks: chunks,
    );
  }
}

enum EnvironmentWorldEdge { left, right, top, bottom }

/// Adds one complete chunk row or column to a rectangular world.
///
/// The runtime world keeps its origin at zero. Extending [left] or [top]
/// therefore rebases existing content by one chunk, which preserves its visual
/// relationship to the editor camera without requiring signed world bounds.
EnvironmentChunkedWorld extendEnvironmentChunkedWorld(
  EnvironmentWorldManifest manifest,
  Map<EnvironmentChunkCoordinate, EnvironmentChunkDocument> sourceChunks,
  EnvironmentWorldEdge edge,
) {
  final size = manifest.chunkSize;
  final columns = (manifest.width / size).ceil();
  final rows = (manifest.height / size).ceil();
  final expected = {
    for (var y = 0; y < rows; y++)
      for (var x = 0; x < columns; x++) EnvironmentChunkCoordinate(x, y),
  };
  if (!manifest.chunks.toSet().containsAll(expected) ||
      !sourceChunks.keys.toSet().containsAll(expected)) {
    throw StateError('World extension requires a complete rectangular world.');
  }

  final shiftX = edge == EnvironmentWorldEdge.left ? 1 : 0;
  final shiftY = edge == EnvironmentWorldEdge.top ? 1 : 0;
  final worldShiftX = shiftX * size;
  final worldShiftY = shiftY * size;
  final nextColumns =
      columns +
      (edge == EnvironmentWorldEdge.left || edge == EnvironmentWorldEdge.right
          ? 1
          : 0);
  final nextRows =
      rows +
      (edge == EnvironmentWorldEdge.top || edge == EnvironmentWorldEdge.bottom
          ? 1
          : 0);

  final chunks = <EnvironmentChunkCoordinate, EnvironmentChunkDocument>{};
  for (final entry in sourceChunks.entries) {
    final coordinate = EnvironmentChunkCoordinate(
      entry.key.x + shiftX,
      entry.key.y + shiftY,
    );
    final source = entry.value;
    chunks[coordinate] = EnvironmentChunkDocument(
      worldId: source.worldId,
      coordinate: coordinate,
      size: source.size,
      baseMaterialId: source.baseMaterialId,
      surfaces: source.surfaces,
      liquidVolumes: source.liquidVolumes,
      surfaceConnectors: source.surfaceConnectors,
      terrainRegions: source.terrainRegions,
      terrainStrokes: source.terrainStrokes,
      objects: [
        for (final object in source.objects)
          ChunkPlacedEnvironmentObject(
            id: object.id,
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
            bounds: EnvironmentObjectBounds(
              minX: object.bounds.minX + worldShiftX,
              minY: object.bounds.minY + worldShiftY,
              maxX: object.bounds.maxX + worldShiftX,
              maxY: object.bounds.maxY + worldShiftY,
            ),
          ),
      ],
      overlapObjectIds: source.overlapObjectIds,
    );
  }

  for (var y = 0; y < nextRows; y++) {
    for (var x = 0; x < nextColumns; x++) {
      final coordinate = EnvironmentChunkCoordinate(x, y);
      chunks.putIfAbsent(
        coordinate,
        () => EnvironmentChunkDocument(
          worldId: manifest.id,
          coordinate: coordinate,
          size: size,
          baseMaterialId: manifest.baseMaterialId,
        ),
      );
    }
  }

  final allObjects = [for (final chunk in chunks.values) ...chunk.objects];
  for (final entry in chunks.entries.toList()) {
    final chunk = entry.value;
    chunks[entry.key] = EnvironmentChunkDocument(
      worldId: chunk.worldId,
      coordinate: chunk.coordinate,
      size: chunk.size,
      baseMaterialId: chunk.baseMaterialId,
      surfaces: chunk.surfaces,
      liquidVolumes: chunk.liquidVolumes,
      surfaceConnectors: chunk.surfaceConnectors,
      terrainRegions: chunk.terrainRegions,
      terrainStrokes: chunk.terrainStrokes,
      objects: chunk.objects,
      overlapObjectIds: {
        for (final object in allObjects)
          if (object.bounds.overlapsChunk(entry.key, size)) object.id,
      },
    );
  }

  ChunkLocalPosition shiftPosition(ChunkLocalPosition position) =>
      ChunkLocalPosition(
        chunk: EnvironmentChunkCoordinate(
          position.chunk.x + shiftX,
          position.chunk.y + shiftY,
        ),
        localX: position.localX,
        localY: position.localY,
      );

  final coordinates = chunks.keys.toList()..sort();
  return EnvironmentChunkedWorld(
    manifest: EnvironmentWorldManifest(
      id: manifest.id,
      name: manifest.name,
      chunkSize: size,
      width: nextColumns * size,
      height: nextRows * size,
      baseMaterialId: manifest.baseMaterialId,
      chunks: coordinates,
      playerSpawn: shiftPosition(manifest.playerSpawn),
      travelPoints: [
        for (final point in manifest.travelPoints)
          EnvironmentTravelPoint(
            id: point.id,
            position: shiftPosition(point.position),
          ),
      ],
      editorLayers: manifest.editorLayers,
      activeLayerId: manifest.activeLayerId,
      playerSpawnSurfaceId: manifest.playerSpawnSurfaceId,
      activeSurfaceId: manifest.activeSurfaceId,
    ),
    chunks: chunks,
  );
}
