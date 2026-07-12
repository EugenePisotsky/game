import 'dart:convert';

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
  });

  final String materialId;
  final double radius;
  final double opacity;
  final List<WorldPoint> points;

  Map<String, Object> toJson() => {
    'materialId': materialId,
    'radius': radius,
    'opacity': opacity,
    'points': [for (final point in points) point.toJson()],
  };

  factory TerrainStroke.fromJson(Map<String, Object?> json) => TerrainStroke(
    materialId: json['materialId'] as String,
    radius: (json['radius'] as num).toDouble(),
    opacity: (json['opacity'] as num).toDouble(),
    points: [
      for (final value in json['points'] as List<Object?>)
        WorldPoint.fromJson(value as Map<String, Object?>),
    ],
  );
}

class PlacedEnvironmentObject {
  PlacedEnvironmentObject({
    required this.id,
    required this.assetId,
    required this.x,
    required this.y,
    this.z = 0,
    this.direction = EnvironmentDirection.south,
  });

  final String id;
  final String assetId;
  double x;
  double y;
  double z;
  EnvironmentDirection direction;

  Map<String, Object> toJson() => {
    'id': id,
    'assetId': assetId,
    'x': x,
    'y': y,
    'z': z,
    'direction': direction.name,
  };

  factory PlacedEnvironmentObject.fromJson(Map<String, Object?> json) =>
      PlacedEnvironmentObject(
        id: json['id'] as String,
        assetId: json['assetId'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        z: (json['z'] as num? ?? 0).toDouble(),
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
    List<TerrainStroke>? terrainStrokes,
    List<PlacedEnvironmentObject>? objects,
    this.schemaVersion = currentSchemaVersion,
  }) : terrainStrokes = List.of(terrainStrokes ?? const []),
       objects = List.of(objects ?? const []) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Environment dimensions must be positive.');
    }
  }

  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final String id;
  final String name;
  final int width;
  final int height;
  String baseMaterialId;
  final List<TerrainStroke> terrainStrokes;
  final List<PlacedEnvironmentObject> objects;

  bool contains(double x, double y) =>
      x >= 0 && y >= 0 && x <= width && y <= height;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    'width': width,
    'height': height,
    'baseMaterialId': baseMaterialId,
    'terrainStrokes': [for (final stroke in terrainStrokes) stroke.toJson()],
    'objects': [for (final object in objects) object.toJson()],
  };

  String toJsonString({bool pretty = true}) => pretty
      ? const JsonEncoder.withIndent('  ').convert(toJson())
      : jsonEncode(toJson());

  factory EnvironmentDocument.fromJson(Map<String, Object?> json) {
    final version = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    if (version != currentSchemaVersion) {
      throw FormatException('Unsupported environment schema version $version.');
    }
    return EnvironmentDocument(
      schemaVersion: version,
      id: json['id'] as String,
      name: json['name'] as String,
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      baseMaterialId: json['baseMaterialId'] as String,
      terrainStrokes: [
        for (final value
            in json['terrainStrokes'] as List<Object?>? ?? const [])
          TerrainStroke.fromJson(value as Map<String, Object?>),
      ],
      objects: [
        for (final value in json['objects'] as List<Object?>? ?? const [])
          PlacedEnvironmentObject.fromJson(value as Map<String, Object?>),
      ],
    );
  }

  factory EnvironmentDocument.fromJsonString(String source) =>
      EnvironmentDocument.fromJson(jsonDecode(source) as Map<String, Object?>);
}
