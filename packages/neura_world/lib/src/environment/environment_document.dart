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

const String environmentBaseSurfaceId = 'surface_ground';

enum EnvironmentSurfaceKind { terrain, platform, interior }

enum EnvironmentSurfaceHeightKind { flat, linearRamp }

/// The physical height of a walkable surface.
///
/// Most authored surfaces are flat. A linear ramp interpolates between two
/// world-space points and is the deliberately small first step toward stairs
/// and slopes without introducing an unconstrained height map.
class EnvironmentSurfaceHeight {
  const EnvironmentSurfaceHeight.flat(this.elevation)
    : kind = EnvironmentSurfaceHeightKind.flat,
      endElevation = elevation,
      rampStart = null,
      rampEnd = null;

  const EnvironmentSurfaceHeight.linearRamp({
    required this.elevation,
    required this.endElevation,
    required this.rampStart,
    required this.rampEnd,
  }) : kind = EnvironmentSurfaceHeightKind.linearRamp;

  final EnvironmentSurfaceHeightKind kind;
  final double elevation;
  final double endElevation;
  final WorldPoint? rampStart;
  final WorldPoint? rampEnd;

  double at(WorldPoint point) {
    final start = rampStart;
    final end = rampEnd;
    if (kind == EnvironmentSurfaceHeightKind.flat ||
        start == null ||
        end == null) {
      return elevation;
    }
    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 1e-12) return elevation;
    final t =
        (((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
            .clamp(0.0, 1.0);
    return elevation + (endElevation - elevation) * t;
  }

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'elevation': elevation,
    if (kind == EnvironmentSurfaceHeightKind.linearRamp) ...{
      'endElevation': endElevation,
      'rampStart': rampStart!.toJson(),
      'rampEnd': rampEnd!.toJson(),
    },
  };

  factory EnvironmentSurfaceHeight.fromJson(Map<String, Object?> json) {
    final kind = EnvironmentSurfaceHeightKind.values.byName(
      json['kind'] as String,
    );
    final elevation = (json['elevation'] as num).toDouble();
    return switch (kind) {
      EnvironmentSurfaceHeightKind.flat => EnvironmentSurfaceHeight.flat(
        elevation,
      ),
      EnvironmentSurfaceHeightKind.linearRamp =>
        EnvironmentSurfaceHeight.linearRamp(
          elevation: elevation,
          endElevation: (json['endElevation'] as num).toDouble(),
          rampStart: WorldPoint.fromJson(
            json['rampStart'] as Map<String, Object?>,
          ),
          rampEnd: WorldPoint.fromJson(json['rampEnd'] as Map<String, Object?>),
        ),
    };
  }
}

/// A physical plane actors and objects can stand on.
///
/// Its polygon is gameplay geometry. Surface paint, liquids, and placed
/// objects refer to it by id; they do not carry their own elevation.
class EnvironmentSurface {
  EnvironmentSurface({
    required this.id,
    required this.name,
    required this.materialId,
    required this.points,
    this.kind = EnvironmentSurfaceKind.terrain,
    this.height = const EnvironmentSurfaceHeight.flat(0),
    this.walkable = true,
    this.drawsBaseMaterial = true,
    this.order = 0,
    this.visibilityGroupId,
  });

  final String id;
  String name;
  String materialId;
  final List<WorldPoint> points;
  EnvironmentSurfaceKind kind;
  EnvironmentSurfaceHeight height;
  bool walkable;
  bool drawsBaseMaterial;
  int order;
  String? visibilityGroupId;

  bool contains(WorldPoint point) => _pointInPolygon(point, points);
  double elevationAt(WorldPoint point) => height.at(point);

  EnvironmentSurface copyWith({
    String? name,
    String? materialId,
    List<WorldPoint>? points,
    EnvironmentSurfaceKind? kind,
    EnvironmentSurfaceHeight? height,
    bool? walkable,
    bool? drawsBaseMaterial,
    int? order,
    String? visibilityGroupId,
  }) => EnvironmentSurface(
    id: id,
    name: name ?? this.name,
    materialId: materialId ?? this.materialId,
    points: points ?? this.points,
    kind: kind ?? this.kind,
    height: height ?? this.height,
    walkable: walkable ?? this.walkable,
    drawsBaseMaterial: drawsBaseMaterial ?? this.drawsBaseMaterial,
    order: order ?? this.order,
    visibilityGroupId: visibilityGroupId ?? this.visibilityGroupId,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'materialId': materialId,
    'kind': kind.name,
    'height': height.toJson(),
    'walkable': walkable,
    'drawsBaseMaterial': drawsBaseMaterial,
    'order': order,
    'visibilityGroupId': ?visibilityGroupId,
    'points': [for (final point in points) point.toJson()],
  };

  factory EnvironmentSurface.fromJson(Map<String, Object?> json) =>
      EnvironmentSurface(
        id: json['id'] as String,
        name: json['name'] as String,
        materialId: json['materialId'] as String,
        kind: EnvironmentSurfaceKind.values.byName(
          json['kind'] as String? ?? EnvironmentSurfaceKind.terrain.name,
        ),
        height: EnvironmentSurfaceHeight.fromJson(
          json['height'] as Map<String, Object?>,
        ),
        walkable: json['walkable'] as bool? ?? true,
        drawsBaseMaterial: json['drawsBaseMaterial'] as bool? ?? true,
        order: (json['order'] as num? ?? 0).toInt(),
        visibilityGroupId: json['visibilityGroupId'] as String?,
        points: [
          for (final value in json['points'] as List<Object?>)
            WorldPoint.fromJson(value as Map<String, Object?>),
        ],
      );
}

/// A liquid layer above a solid bed surface.
class EnvironmentLiquidVolume {
  EnvironmentLiquidVolume({
    required this.id,
    required this.name,
    required this.bedSurfaceId,
    required this.materialId,
    required this.points,
    required this.surfaceElevation,
    this.depth = defaultDepth,
    this.endDepth,
    this.depthRampStart,
    this.depthRampEnd,
    this.edgeBlend = 0,
    this.opacity = 0.85,
    this.textureScale = 1,
    this.order = 0,
  });

  static const double defaultDepth = 0.35;

  final String id;
  String name;
  String bedSurfaceId;
  String materialId;
  final List<WorldPoint> points;
  double surfaceElevation;
  double depth;
  double? endDepth;
  WorldPoint? depthRampStart;
  WorldPoint? depthRampEnd;
  double edgeBlend;
  double opacity;
  double textureScale;
  int order;

  bool contains(WorldPoint point) => _pointInPolygon(point, points);

  bool get hasDepthRamp =>
      endDepth != null && depthRampStart != null && depthRampEnd != null;

  double depthAt(WorldPoint point) {
    final endValue = endDepth;
    final start = depthRampStart;
    final end = depthRampEnd;
    if (endValue == null || start == null || end == null) return depth;
    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 1e-12) return depth;
    final t =
        (((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
            .clamp(0, 1)
            .toDouble();
    return depth + (endValue - depth) * t;
  }

  EnvironmentLiquidVolume copyWith({
    String? name,
    String? bedSurfaceId,
    String? materialId,
    List<WorldPoint>? points,
    double? surfaceElevation,
    double? depth,
    double? endDepth,
    WorldPoint? depthRampStart,
    WorldPoint? depthRampEnd,
    bool clearDepthRamp = false,
    double? edgeBlend,
    double? opacity,
    double? textureScale,
    int? order,
  }) => EnvironmentLiquidVolume(
    id: id,
    name: name ?? this.name,
    bedSurfaceId: bedSurfaceId ?? this.bedSurfaceId,
    materialId: materialId ?? this.materialId,
    points: points ?? this.points,
    surfaceElevation: surfaceElevation ?? this.surfaceElevation,
    depth: depth ?? this.depth,
    endDepth: clearDepthRamp ? null : endDepth ?? this.endDepth,
    depthRampStart: clearDepthRamp
        ? null
        : depthRampStart ?? this.depthRampStart,
    depthRampEnd: clearDepthRamp ? null : depthRampEnd ?? this.depthRampEnd,
    edgeBlend: edgeBlend ?? this.edgeBlend,
    opacity: opacity ?? this.opacity,
    textureScale: textureScale ?? this.textureScale,
    order: order ?? this.order,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'bedSurfaceId': bedSurfaceId,
    'materialId': materialId,
    'surfaceElevation': surfaceElevation,
    'depth': depth,
    if (hasDepthRamp)
      'depthRamp': {
        'endDepth': endDepth!,
        'start': depthRampStart!.toJson(),
        'end': depthRampEnd!.toJson(),
      },
    'edgeBlend': edgeBlend,
    'opacity': opacity,
    'textureScale': textureScale,
    'order': order,
    'points': [for (final point in points) point.toJson()],
  };

  factory EnvironmentLiquidVolume.fromJson(Map<String, Object?> json) {
    final ramp = json['depthRamp'] as Map<String, Object?>?;
    return EnvironmentLiquidVolume(
      id: json['id'] as String,
      name: json['name'] as String,
      bedSurfaceId: json['bedSurfaceId'] as String,
      materialId: json['materialId'] as String,
      surfaceElevation: (json['surfaceElevation'] as num).toDouble(),
      depth: (json['depth'] as num).toDouble(),
      endDepth: (ramp?['endDepth'] as num?)?.toDouble(),
      depthRampStart: ramp?['start'] == null
          ? null
          : WorldPoint.fromJson(ramp!['start'] as Map<String, Object?>),
      depthRampEnd: ramp?['end'] == null
          ? null
          : WorldPoint.fromJson(ramp!['end'] as Map<String, Object?>),
      edgeBlend: (json['edgeBlend'] as num? ?? 0).toDouble(),
      opacity: (json['opacity'] as num? ?? 0.85).toDouble(),
      textureScale: (json['textureScale'] as num? ?? 1).toDouble(),
      order: (json['order'] as num? ?? 0).toInt(),
      points: [
        for (final value in json['points'] as List<Object?>)
          WorldPoint.fromJson(value as Map<String, Object?>),
      ],
    );
  }
}

enum EnvironmentSurfaceConnectorKind { stairs, ramp, ladder, portal }

/// An explicit permitted transition between otherwise independent surfaces.
class EnvironmentSurfaceConnector {
  const EnvironmentSurfaceConnector({
    required this.id,
    required this.fromSurfaceId,
    required this.toSurfaceId,
    required this.from,
    required this.to,
    this.kind = EnvironmentSurfaceConnectorKind.stairs,
    this.width = 1,
    this.bidirectional = true,
    this.cost = 1,
  });

  final String id;
  final String fromSurfaceId;
  final String toSurfaceId;
  final WorldPoint from;
  final WorldPoint to;
  final EnvironmentSurfaceConnectorKind kind;
  final double width;
  final bool bidirectional;
  final double cost;

  Map<String, Object> toJson() => {
    'id': id,
    'fromSurfaceId': fromSurfaceId,
    'toSurfaceId': toSurfaceId,
    'from': from.toJson(),
    'to': to.toJson(),
    'kind': kind.name,
    'width': width,
    'bidirectional': bidirectional,
    'cost': cost,
  };

  factory EnvironmentSurfaceConnector.fromJson(Map<String, Object?> json) =>
      EnvironmentSurfaceConnector(
        id: json['id'] as String,
        fromSurfaceId: json['fromSurfaceId'] as String,
        toSurfaceId: json['toSurfaceId'] as String,
        from: WorldPoint.fromJson(json['from'] as Map<String, Object?>),
        to: WorldPoint.fromJson(json['to'] as Map<String, Object?>),
        kind: EnvironmentSurfaceConnectorKind.values.byName(
          json['kind'] as String? ??
              EnvironmentSurfaceConnectorKind.stairs.name,
        ),
        width: (json['width'] as num? ?? 1).toDouble(),
        bidirectional: json['bidirectional'] as bool? ?? true,
        cost: (json['cost'] as num? ?? 1).toDouble(),
      );
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
    this.surfaceId = environmentBaseSurfaceId,
  });

  static const double legacySpacing = 0.22;
  static const double defaultWaterDepth = EnvironmentLiquidVolume.defaultDepth;

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
  final String surfaceId;

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
    'surfaceId': surfaceId,
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
    surfaceId: json['surfaceId'] as String,
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
    this.opacity = 1,
    this.textureScale = 1,
    this.seed = 0,
    this.order = 0,
    this.surfaceId = environmentBaseSurfaceId,
  });

  final String id;
  final String materialId;
  final List<WorldPoint> points;
  final bool resetsToDefault;
  final double edgeBlend;
  final double opacity;
  final double textureScale;
  final int seed;
  final int order;
  final String surfaceId;

  TerrainRegion copyWith({
    String? materialId,
    List<WorldPoint>? points,
    bool? resetsToDefault,
    double? edgeBlend,
    double? opacity,
    double? textureScale,
    int? seed,
    int? order,
    String? surfaceId,
  }) => TerrainRegion(
    id: id,
    materialId: materialId ?? this.materialId,
    points: points ?? this.points,
    resetsToDefault: resetsToDefault ?? this.resetsToDefault,
    edgeBlend: edgeBlend ?? this.edgeBlend,
    opacity: opacity ?? this.opacity,
    textureScale: textureScale ?? this.textureScale,
    seed: seed ?? this.seed,
    order: order ?? this.order,
    surfaceId: surfaceId ?? this.surfaceId,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'materialId': materialId,
    if (resetsToDefault) 'resetsToDefault': true,
    'edgeBlend': edgeBlend,
    if (opacity != 1) 'opacity': opacity,
    'textureScale': textureScale,
    'seed': seed,
    'order': order,
    'surfaceId': surfaceId,
    'points': [for (final point in points) point.toJson()],
  };

  factory TerrainRegion.fromJson(Map<String, Object?> json) => TerrainRegion(
    id: json['id'] as String,
    materialId: json['materialId'] as String,
    resetsToDefault: json['resetsToDefault'] as bool? ?? false,
    edgeBlend: (json['edgeBlend'] as num? ?? 0).toDouble(),
    opacity: (json['opacity'] as num? ?? 1).toDouble(),
    textureScale: (json['textureScale'] as num? ?? 1).toDouble(),
    seed: (json['seed'] as num?)?.toInt() ?? 0,
    order: (json['order'] as num?)?.toInt() ?? 0,
    surfaceId: json['surfaceId'] as String,
    points: [
      for (final value in json['points'] as List<Object?>)
        WorldPoint.fromJson(value as Map<String, Object?>),
    ],
  );
}

enum EnvironmentLiquidInteraction { automatic, submerge, float, ignore }

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
  WorldPoint point, {
  String? surfaceId,
}) {
  final resolvedSurfaceId = surfaceId ?? document.activeSurfaceId;
  for (final region in document.terrainRegions.reversed) {
    if (region.surfaceId != resolvedSurfaceId) continue;
    if (!_pointInPolygon(point, region.points)) continue;
    return region.resetsToDefault
        ? document.surfaceById(resolvedSurfaceId)!.materialId
        : region.materialId;
  }
  return document.surfaceById(resolvedSurfaceId)!.materialId;
}

/// Returns the visually dominant terrain material at [point]. Detail strokes
/// sit above regional fills; reset masks reveal that regional layer.
String environmentMaterialAtPoint(
  EnvironmentDocument document,
  WorldPoint point, {
  double coverage = 0.75,
  String? surfaceId,
}) {
  final resolvedSurfaceId = surfaceId ?? document.activeSurfaceId;
  for (final stroke in document.terrainStrokes.reversed) {
    if (stroke.surfaceId != resolvedSurfaceId) continue;
    if (stroke.resetsToBase) {
      if (_pointInPolygon(point, stroke.points)) {
        return environmentBaseMaterialAtPoint(
          document,
          point,
          surfaceId: resolvedSurfaceId,
        );
      }
      continue;
    }
    if (_terrainStrokeCovers(stroke, point, coverage)) {
      return stroke.materialId;
    }
  }
  return environmentBaseMaterialAtPoint(
    document,
    point,
    surfaceId: resolvedSurfaceId,
  );
}

/// Physical ground and optional liquid surface resolved at one world point.
///
/// Material paint and height remain separate concepts to callers, but legacy
/// terrain operations carry sensible default surface values so existing water
/// immediately behaves as a shallow body. Detail paint decides whether liquid
/// is visible while solid regional fills provide the supporting elevation.
class EnvironmentSurfaceSample {
  const EnvironmentSurfaceSample({
    required this.surfaceId,
    required this.groundElevation,
    this.liquidMaterialId,
    this.liquidSurfaceElevation,
    this.liquidDepth = 0,
    this.liquidVolume,
  });

  final String surfaceId;
  final double groundElevation;
  final String? liquidMaterialId;
  final double? liquidSurfaceElevation;
  final double liquidDepth;
  final EnvironmentLiquidVolume? liquidVolume;

  bool get hasLiquid =>
      liquidMaterialId != null && liquidSurfaceElevation != null;
}

EnvironmentSurfaceSample environmentSurfaceAtPoint(
  EnvironmentDocument document,
  WorldPoint point, {
  String? preferredSurfaceId,
  // Kept as an optional callback while runtime call sites move to explicit
  // liquid volumes. Material tags no longer define physical water.
  bool Function(String materialId)? isLiquidMaterial,
}) {
  final surface = document.resolveSurfaceAt(
    point,
    preferredSurfaceId: preferredSurfaceId,
  );
  final groundElevation = surface.elevationAt(point);
  EnvironmentLiquidVolume? liquid;
  for (final candidate in document.liquidVolumes) {
    if (candidate.bedSurfaceId == surface.id && candidate.contains(point)) {
      if (liquid == null || candidate.order >= liquid.order) liquid = candidate;
    }
  }
  final liquidDepth = liquid?.depthAt(point) ?? 0;
  return EnvironmentSurfaceSample(
    surfaceId: surface.id,
    groundElevation: liquid == null
        ? groundElevation
        : liquid.surfaceElevation - liquidDepth,
    liquidMaterialId: liquid?.materialId,
    liquidSurfaceElevation: liquid?.surfaceElevation,
    liquidDepth: liquidDepth,
    liquidVolume: liquid,
  );
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
    this.behaviorProfileId,
    this.liquidInteraction = EnvironmentLiquidInteraction.automatic,
    this.liquidDraft = 0.12,
    this.supportSurfaceId = environmentBaseSurfaceId,
    this.crossSurfaceOcclusion = false,
    this.occlusionHeight = 0,
  });

  final String id;
  final String assetId;
  double x;
  double y;
  double verticalOffset;
  double sortBias;
  String editorLayerId;
  EnvironmentDirection direction;
  String? behaviorProfileId;
  EnvironmentLiquidInteraction liquidInteraction;
  double liquidDraft;
  String supportSurfaceId;
  bool crossSurfaceOcclusion;
  double occlusionHeight;

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
    'behaviorProfileId': ?behaviorProfileId,
    if (liquidInteraction != EnvironmentLiquidInteraction.automatic)
      'liquidInteraction': liquidInteraction.name,
    if (liquidDraft != 0.12) 'liquidDraft': liquidDraft,
    'supportSurfaceId': supportSurfaceId,
    if (crossSurfaceOcclusion) 'crossSurfaceOcclusion': true,
    if (occlusionHeight != 0) 'occlusionHeight': occlusionHeight,
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
        behaviorProfileId: json['behaviorProfileId'] as String?,
        liquidInteraction: EnvironmentLiquidInteraction.values.byName(
          json['liquidInteraction'] as String? ??
              EnvironmentLiquidInteraction.automatic.name,
        ),
        liquidDraft: (json['liquidDraft'] as num? ?? 0.12).toDouble(),
        supportSurfaceId: json['supportSurfaceId'] as String,
        crossSurfaceOcclusion: json['crossSurfaceOcclusion'] as bool? ?? false,
        occlusionHeight: (json['occlusionHeight'] as num? ?? 0).toDouble(),
      );
}

class EnvironmentDocument {
  EnvironmentDocument({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    String? baseMaterialId,
    List<EnvironmentSurface>? surfaces,
    List<EnvironmentLiquidVolume>? liquidVolumes,
    List<EnvironmentSurfaceConnector>? surfaceConnectors,
    List<TerrainRegion>? terrainRegions,
    List<TerrainStroke>? terrainStrokes,
    List<PlacedEnvironmentObject>? objects,
    List<EditorLayer>? editorLayers,
    String? activeLayerId,
    String? activeSurfaceId,
    this.schemaVersion = currentSchemaVersion,
  }) : surfaces = List.of(
         surfaces ??
             [
               EnvironmentSurface(
                 id: environmentBaseSurfaceId,
                 name: 'Ground',
                 materialId:
                     baseMaterialId ??
                     (throw ArgumentError(
                       'baseMaterialId is required when surfaces are omitted.',
                     )),
                 points: [
                   const WorldPoint(0, 0),
                   WorldPoint(width.toDouble(), 0),
                   WorldPoint(width.toDouble(), height.toDouble()),
                   WorldPoint(0, height.toDouble()),
                 ],
               ),
             ],
       ),
       liquidVolumes = List.of(liquidVolumes ?? const []),
       surfaceConnectors = List.of(surfaceConnectors ?? const []),
       terrainRegions = List.of(terrainRegions ?? const []),
       terrainStrokes = List.of(terrainStrokes ?? const []),
       objects = List.of(objects ?? const []),
       editorLayers = List.of(editorLayers ?? defaultEditorLayers()),
       activeLayerId = activeLayerId ?? rootLayerId,
       activeSurfaceId = activeSurfaceId ?? environmentBaseSurfaceId {
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
    final surfaceIds = this.surfaces.map((surface) => surface.id).toSet();
    if (surfaceIds.length != this.surfaces.length ||
        !surfaceIds.contains(this.activeSurfaceId) ||
        !surfaceIds.contains(environmentBaseSurfaceId)) {
      throw ArgumentError(
        'Surfaces must be unique and include the base and active surfaces.',
      );
    }
    for (final region in this.terrainRegions) {
      if (!surfaceIds.contains(region.surfaceId)) {
        throw ArgumentError(
          'Terrain region ${region.id} has unknown surface ${region.surfaceId}.',
        );
      }
    }
    for (final stroke in this.terrainStrokes) {
      if (!surfaceIds.contains(stroke.surfaceId)) {
        throw ArgumentError(
          'Terrain stroke has unknown surface ${stroke.surfaceId}.',
        );
      }
    }
    for (final liquid in this.liquidVolumes) {
      if (!surfaceIds.contains(liquid.bedSurfaceId)) {
        throw ArgumentError(
          'Liquid ${liquid.id} has unknown bed ${liquid.bedSurfaceId}.',
        );
      }
    }
    for (final connector in this.surfaceConnectors) {
      if (!surfaceIds.contains(connector.fromSurfaceId) ||
          !surfaceIds.contains(connector.toSurfaceId)) {
        throw ArgumentError(
          'Connector ${connector.id} references an unknown surface.',
        );
      }
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
      if (!surfaceIds.contains(object.supportSurfaceId)) {
        throw ArgumentError(
          'Object ${object.id} has unknown support surface '
          '${object.supportSurfaceId}.',
        );
      }
    }
  }

  static const currentSchemaVersion = 6;
  static const rootLayerId = 'layer_world';

  static List<EditorLayer> defaultEditorLayers() => [
    EditorLayer(id: rootLayerId, name: 'World'),
  ];

  final int schemaVersion;
  final String id;
  final String name;
  final int width;
  final int height;
  final List<EnvironmentSurface> surfaces;
  final List<EnvironmentLiquidVolume> liquidVolumes;
  final List<EnvironmentSurfaceConnector> surfaceConnectors;
  final List<TerrainRegion> terrainRegions;
  final List<TerrainStroke> terrainStrokes;
  final List<PlacedEnvironmentObject> objects;
  final List<EditorLayer> editorLayers;
  String activeLayerId;
  String activeSurfaceId;

  EnvironmentSurface get baseSurface => surfaceById(environmentBaseSurfaceId)!;

  String get baseMaterialId => baseSurface.materialId;
  set baseMaterialId(String value) => baseSurface.materialId = value;

  EnvironmentSurface? surfaceById(String id) {
    for (final surface in surfaces) {
      if (surface.id == id) return surface;
    }
    return null;
  }

  EnvironmentSurface resolveSurfaceAt(
    WorldPoint point, {
    String? preferredSurfaceId,
  }) {
    final preferred = preferredSurfaceId == null
        ? null
        : surfaceById(preferredSurfaceId);
    if (preferred != null && preferred.contains(point)) return preferred;
    EnvironmentSurface? resolved;
    for (final surface in surfaces) {
      if (!surface.contains(point)) continue;
      if (resolved == null || surface.order >= resolved.order) {
        resolved = surface;
      }
    }
    return resolved ?? baseSurface;
  }

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
    'surfaces': [for (final surface in surfaces) surface.toJson()],
    'liquidVolumes': [for (final liquid in liquidVolumes) liquid.toJson()],
    'surfaceConnectors': [
      for (final connector in surfaceConnectors) connector.toJson(),
    ],
    'terrainRegions': [for (final region in terrainRegions) region.toJson()],
    'terrainStrokes': [for (final stroke in terrainStrokes) stroke.toJson()],
    'objects': [for (final object in objects) object.toJson()],
    'editorLayers': [for (final layer in editorLayers) layer.toJson()],
    'activeLayerId': activeLayerId,
    'activeSurfaceId': activeSurfaceId,
  };

  String toJsonString({bool pretty = true}) => pretty
      ? const JsonEncoder.withIndent('  ').convert(toJson())
      : jsonEncode(toJson());

  factory EnvironmentDocument.fromJson(Map<String, Object?> json) {
    final version = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    if (version != currentSchemaVersion) {
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
      surfaces: [
        for (final value in json['surfaces'] as List<Object?>)
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
          PlacedEnvironmentObject.fromJson(value as Map<String, Object?>),
      ],
      editorLayers: editorLayers.isEmpty ? null : editorLayers,
      activeLayerId: json['activeLayerId'] as String?,
      activeSurfaceId: json['activeSurfaceId'] as String,
    );
  }

  factory EnvironmentDocument.fromJsonString(String source) =>
      EnvironmentDocument.fromJson(jsonDecode(source) as Map<String, Object?>);
}
