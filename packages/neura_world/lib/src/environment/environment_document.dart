import 'dart:convert';
import 'dart:math' as math;

enum EnvironmentDirection {
  south,
  west,
  east,
  north,
  southWest,
  northWest,
  southEast,
  northEast;

  EnvironmentDirection get next {
    const clockwise = [
      south,
      southWest,
      west,
      northWest,
      north,
      northEast,
      east,
      southEast,
    ];
    return clockwise[(clockwise.indexOf(this) + 1) % clockwise.length];
  }
}

class EditorLayer {
  EditorLayer({
    required this.id,
    required this.name,
    this.parentId,
    this.visible = true,
    this.locked = false,
    this.exported = true,
    this.color,
  });

  final String id;
  String name;
  String? parentId;
  bool visible;
  bool locked;
  bool exported;
  String? color;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
    'visible': visible,
    'locked': locked,
    'exported': exported,
    if (color != null) 'color': color,
  };

  factory EditorLayer.fromJson(Map<String, Object?> json) => EditorLayer(
    id: json['id'] as String,
    name: json['name'] as String,
    parentId: json['parentId'] as String?,
    visible: json['visible'] as bool? ?? true,
    locked: json['locked'] as bool? ?? false,
    exported: json['exported'] as bool? ?? true,
    color: json['color'] as String?,
  );
}

class WorldPoint {
  const WorldPoint(this.x, this.y);

  final double x;
  final double y;

  Map<String, Object> toJson() => {'x': x, 'y': y};

  factory WorldPoint.fromJson(Map<String, Object?> json) =>
      WorldPoint((json['x'] as num).toDouble(), (json['y'] as num).toDouble());
}

class TerrainStroke {
  TerrainStroke({
    required this.materialId,
    required this.radius,
    required this.opacity,
    required this.points,
    this.resetsToBase = false,
    this.seed = 0,
    this.spacing = legacySpacing,
    this.scatter = 0,
    this.sizeJitter = 0,
    this.opacityJitter = 0,
  });

  static const double legacySpacing = 0.22;

  final String materialId;
  final double radius;
  final double opacity;
  final List<WorldPoint> points;
  final bool resetsToBase;
  final int seed;
  final double spacing;
  final double scatter;
  final double sizeJitter;
  final double opacityJitter;

  double get maximumStampExtent =>
      resetsToBase ? 0 : radius * (1 + scatter + sizeJitter);

  Map<String, Object> toJson() => {
    'materialId': materialId,
    'radius': radius,
    'opacity': opacity,
    if (resetsToBase) 'resetsToBase': true,
    'seed': seed,
    'spacing': spacing,
    'scatter': scatter,
    'sizeJitter': sizeJitter,
    'opacityJitter': opacityJitter,
    'points': [for (final point in points) point.toJson()],
  };

  factory TerrainStroke.fromJson(Map<String, Object?> json) => TerrainStroke(
    materialId: json['materialId'] as String,
    radius: (json['radius'] as num).toDouble(),
    opacity: (json['opacity'] as num).toDouble(),
    resetsToBase: json['resetsToBase'] as bool? ?? false,
    seed: (json['seed'] as num?)?.toInt() ?? 0,
    spacing: (json['spacing'] as num? ?? TerrainStroke.legacySpacing)
        .toDouble(),
    scatter: (json['scatter'] as num? ?? 0).toDouble(),
    sizeJitter: (json['sizeJitter'] as num? ?? 0).toDouble(),
    opacityJitter: (json['opacityJitter'] as num? ?? 0).toDouble(),
    points: [
      for (final value in json['points'] as List<Object?>)
        WorldPoint.fromJson(value as Map<String, Object?>),
    ],
  );
}

/// An ordered, opaque material assignment below detail brush strokes.
///
/// Regions are intentionally independent from runtime chunks: a single
/// authored polygon may cross any number of chunks and is clipped only when
/// serialized or rendered. A reset region clears earlier regional fills and
/// reveals the document's current default material.
class TerrainRegion {
  TerrainRegion({
    required this.id,
    required this.materialId,
    required this.points,
    this.resetsToDefault = false,
    this.edgeBlend = 0,
    this.textureScale = 1,
    this.seed = 0,
    this.order = 0,
  });

  final String id;
  final String materialId;
  final List<WorldPoint> points;
  final bool resetsToDefault;
  final double edgeBlend;
  final double textureScale;
  final int seed;
  final int order;

  TerrainRegion copyWith({
    String? materialId,
    List<WorldPoint>? points,
    bool? resetsToDefault,
    double? edgeBlend,
    double? textureScale,
    int? seed,
    int? order,
  }) => TerrainRegion(
    id: id,
    materialId: materialId ?? this.materialId,
    points: points ?? this.points,
    resetsToDefault: resetsToDefault ?? this.resetsToDefault,
    edgeBlend: edgeBlend ?? this.edgeBlend,
    textureScale: textureScale ?? this.textureScale,
    seed: seed ?? this.seed,
    order: order ?? this.order,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'materialId': materialId,
    if (resetsToDefault) 'resetsToDefault': true,
    'edgeBlend': edgeBlend,
    'textureScale': textureScale,
    'seed': seed,
    'order': order,
    'points': [for (final point in points) point.toJson()],
  };

  factory TerrainRegion.fromJson(Map<String, Object?> json) => TerrainRegion(
    id: json['id'] as String,
    materialId: json['materialId'] as String,
    resetsToDefault: json['resetsToDefault'] as bool? ?? false,
    edgeBlend: (json['edgeBlend'] as num? ?? 0).toDouble(),
    textureScale: (json['textureScale'] as num? ?? 1).toDouble(),
    seed: (json['seed'] as num?)?.toInt() ?? 0,
    order: (json['order'] as num?)?.toInt() ?? 0,
    points: [
      for (final value in json['points'] as List<Object?>)
        WorldPoint.fromJson(value as Map<String, Object?>),
    ],
  );
}

class TerrainBrushStamp {
  const TerrainBrushStamp({
    required this.center,
    required this.radius,
    required this.opacity,
  });

  final WorldPoint center;
  final double radius;
  final double opacity;
}

/// Converts a pointer polyline into stable brush stamps whose density does not
/// depend on the platform's pointer-event frequency.
Iterable<TerrainBrushStamp> terrainStrokeStamps(TerrainStroke stroke) sync* {
  if (stroke.resetsToBase ||
      stroke.points.isEmpty ||
      stroke.radius <= 0 ||
      stroke.opacity <= 0) {
    return;
  }
  final spacing = math.max(0.15, stroke.radius * stroke.spacing);
  var stampIndex = 0;

  TerrainBrushStamp makeStamp(WorldPoint base) {
    final angle = _strokeRandom(stroke.seed, stampIndex, 0) * math.pi * 2;
    final distance =
        math.sqrt(_strokeRandom(stroke.seed, stampIndex, 1)) *
        stroke.scatter *
        stroke.radius;
    final sizeVariation =
        (_strokeRandom(stroke.seed, stampIndex, 2) * 2 - 1) * stroke.sizeJitter;
    final opacityVariation =
        (_strokeRandom(stroke.seed, stampIndex, 3) * 2 - 1) *
        stroke.opacityJitter;
    stampIndex++;
    return TerrainBrushStamp(
      center: WorldPoint(
        base.x + math.cos(angle) * distance,
        base.y + math.sin(angle) * distance,
      ),
      radius: math.max(
        stroke.radius * 0.1,
        stroke.radius * (1 + sizeVariation),
      ),
      opacity: (stroke.opacity * (1 + opacityVariation)).clamp(0, 1),
    );
  }

  yield makeStamp(stroke.points.first);
  var previous = stroke.points.first;
  var distanceToNext = spacing;
  for (final point in stroke.points.skip(1)) {
    final dx = point.x - previous.x;
    final dy = point.y - previous.y;
    final segmentLength = math.sqrt(dx * dx + dy * dy);
    if (segmentLength <= 1e-9) {
      previous = point;
      continue;
    }
    var traversed = 0.0;
    while (traversed + distanceToNext <= segmentLength) {
      traversed += distanceToNext;
      final t = traversed / segmentLength;
      yield makeStamp(WorldPoint(previous.x + dx * t, previous.y + dy * t));
      distanceToNext = spacing;
    }
    distanceToNext -= segmentLength - traversed;
    previous = point;
  }
}

double _strokeRandom(int seed, int stampIndex, int channel) {
  var value =
      (seed ^ (stampIndex * 0x9E3779B9) ^ (channel * 0x85EBCA6B)) & 0xFFFFFFFF;
  value ^= value >> 16;
  value = (value * 0x7FEB352D) & 0xFFFFFFFF;
  value ^= value >> 15;
  value = (value * 0x846CA68B) & 0xFFFFFFFF;
  value ^= value >> 16;
  return (value & 0xFFFFFFFF) / 0x100000000;
}

/// Returns the regional material below detail paint at [point]. Later regions
/// override earlier regions, matching the renderer's draw order.
String environmentBaseMaterialAtPoint(
  EnvironmentDocument document,
  WorldPoint point,
) {
  for (final region in document.terrainRegions.reversed) {
    if (!_pointInPolygon(point, region.points)) continue;
    return region.resetsToDefault ? document.baseMaterialId : region.materialId;
  }
  return document.baseMaterialId;
}

/// Returns the visually dominant terrain material at [point]. Detail strokes
/// sit above regional fills; reset masks reveal that regional layer.
String environmentMaterialAtPoint(
  EnvironmentDocument document,
  WorldPoint point, {
  double coverage = 0.75,
}) {
  for (final stroke in document.terrainStrokes.reversed) {
    if (stroke.resetsToBase) {
      if (_pointInPolygon(point, stroke.points)) {
        return environmentBaseMaterialAtPoint(document, point);
      }
      continue;
    }
    if (_terrainStrokeCovers(stroke, point, coverage)) {
      return stroke.materialId;
    }
  }
  return environmentBaseMaterialAtPoint(document, point);
}

bool _pointInPolygon(WorldPoint point, List<WorldPoint> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (
    var current = 0, previous = polygon.length - 1;
    current < polygon.length;
    previous = current++
  ) {
    final a = polygon[current];
    final b = polygon[previous];
    if (_segmentDistanceSquared(point, a, b) < 1e-12) return true;
    final crosses = (a.y > point.y) != (b.y > point.y);
    if (crosses &&
        point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

bool _terrainStrokeCovers(
  TerrainStroke stroke,
  WorldPoint point,
  double coverage,
) {
  if (stroke.points.isEmpty || stroke.opacity <= 0) return false;
  final radius = stroke.radius * coverage;
  final radiusSquared = radius * radius;
  if (stroke.points.length == 1) {
    return _distanceSquared(point, stroke.points.first) <= radiusSquared;
  }
  for (var index = 1; index < stroke.points.length; index++) {
    if (_segmentDistanceSquared(
          point,
          stroke.points[index - 1],
          stroke.points[index],
        ) <=
        radiusSquared) {
      return true;
    }
  }
  return false;
}

double _distanceSquared(WorldPoint a, WorldPoint b) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return dx * dx + dy * dy;
}

double _segmentDistanceSquared(
  WorldPoint point,
  WorldPoint start,
  WorldPoint end,
) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared <= 1e-12) return _distanceSquared(point, start);
  final projection =
      ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared;
  final t = math.max(0.0, math.min(1.0, projection));
  return _distanceSquared(
    point,
    WorldPoint(start.x + dx * t, start.y + dy * t),
  );
}

class PlacedEnvironmentObject {
  PlacedEnvironmentObject({
    required this.id,
    required this.assetId,
    required this.x,
    required this.y,
    this.verticalOffset = 0,
    this.sortBias = 0,
    this.editorLayerId = EnvironmentDocument.rootLayerId,
    this.direction = EnvironmentDirection.south,
  });

  final String id;
  final String assetId;
  double x;
  double y;
  double verticalOffset;
  double sortBias;
  String editorLayerId;
  EnvironmentDirection direction;

  @Deprecated('Use verticalOffset; z was never a render-order control.')
  double get z => verticalOffset;

  @Deprecated('Use verticalOffset; z was never a render-order control.')
  set z(double value) => verticalOffset = value;

  Map<String, Object> toJson() => {
    'id': id,
    'assetId': assetId,
    'x': x,
    'y': y,
    'verticalOffset': verticalOffset,
    if (sortBias != 0) 'sortBias': sortBias,
    'editorLayerId': editorLayerId,
    'direction': direction.name,
  };

  factory PlacedEnvironmentObject.fromJson(Map<String, Object?> json) =>
      PlacedEnvironmentObject(
        id: json['id'] as String,
        assetId: json['assetId'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        verticalOffset:
            (json['verticalOffset'] as num? ?? json['z'] as num? ?? 0)
                .toDouble(),
        sortBias: (json['sortBias'] as num? ?? 0).toDouble(),
        editorLayerId:
            json['editorLayerId'] as String? ?? EnvironmentDocument.rootLayerId,
        direction: EnvironmentDirection.values.byName(
          json['direction'] as String? ?? EnvironmentDirection.south.name,
        ),
      );
}

class EnvironmentDocument {
  EnvironmentDocument({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.baseMaterialId,
    List<TerrainRegion>? terrainRegions,
    List<TerrainStroke>? terrainStrokes,
    List<PlacedEnvironmentObject>? objects,
    List<EditorLayer>? editorLayers,
    String? activeLayerId,
    this.schemaVersion = currentSchemaVersion,
  }) : terrainRegions = List.of(terrainRegions ?? const []),
       terrainStrokes = List.of(terrainStrokes ?? const []),
       objects = List.of(objects ?? const []),
       editorLayers = List.of(editorLayers ?? defaultEditorLayers()),
       activeLayerId = activeLayerId ?? rootLayerId {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Environment dimensions must be positive.');
    }
    final layerIds = this.editorLayers.map((layer) => layer.id).toSet();
    if (layerIds.length != this.editorLayers.length ||
        !layerIds.contains(this.activeLayerId)) {
      throw ArgumentError(
        'Editor layers must be unique and include activeLayerId.',
      );
    }
    for (final layer in this.editorLayers) {
      if (layer.parentId != null && !layerIds.contains(layer.parentId)) {
        throw ArgumentError(
          'Layer ${layer.id} has unknown parent ${layer.parentId}.',
        );
      }
    }
    for (final object in this.objects) {
      if (!layerIds.contains(object.editorLayerId)) {
        throw ArgumentError(
          'Object ${object.id} has unknown editor layer ${object.editorLayerId}.',
        );
      }
    }
  }

  static const currentSchemaVersion = 4;
  static const rootLayerId = 'layer_world';

  static List<EditorLayer> defaultEditorLayers() => [
    EditorLayer(id: rootLayerId, name: 'World'),
  ];

  final int schemaVersion;
  final String id;
  final String name;
  final int width;
  final int height;
  String baseMaterialId;
  final List<TerrainRegion> terrainRegions;
  final List<TerrainStroke> terrainStrokes;
  final List<PlacedEnvironmentObject> objects;
  final List<EditorLayer> editorLayers;
  String activeLayerId;

  EditorLayer? editorLayerById(String id) {
    for (final layer in editorLayers) {
      if (layer.id == id) return layer;
    }
    return null;
  }

  bool contains(double x, double y) =>
      x >= 0 && y >= 0 && x <= width && y <= height;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    'width': width,
    'height': height,
    'baseMaterialId': baseMaterialId,
    'terrainRegions': [for (final region in terrainRegions) region.toJson()],
    'terrainStrokes': [for (final stroke in terrainStrokes) stroke.toJson()],
    'objects': [for (final object in objects) object.toJson()],
    'editorLayers': [for (final layer in editorLayers) layer.toJson()],
    'activeLayerId': activeLayerId,
  };

  String toJsonString({bool pretty = true}) => pretty
      ? const JsonEncoder.withIndent('  ').convert(toJson())
      : jsonEncode(toJson());

  factory EnvironmentDocument.fromJson(Map<String, Object?> json) {
    final version = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    if (version < 1 || version > currentSchemaVersion) {
      throw FormatException('Unsupported environment schema version $version.');
    }
    final editorLayers = [
      for (final value in json['editorLayers'] as List<Object?>? ?? const [])
        EditorLayer.fromJson(value as Map<String, Object?>),
    ];
    return EnvironmentDocument(
      schemaVersion: currentSchemaVersion,
      id: json['id'] as String,
      name: json['name'] as String,
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      baseMaterialId: json['baseMaterialId'] as String,
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
          PlacedEnvironmentObject.fromJson(value as Map<String, Object?>),
      ],
      editorLayers: editorLayers.isEmpty ? null : editorLayers,
      activeLayerId: json['activeLayerId'] as String?,
    );
  }

  factory EnvironmentDocument.fromJsonString(String source) =>
      EnvironmentDocument.fromJson(jsonDecode(source) as Map<String, Object?>);
}
