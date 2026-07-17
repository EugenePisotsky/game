import 'dart:collection';
import 'dart:convert';

class EnvironmentGeometryPoint {
  const EnvironmentGeometryPoint(this.x, this.y);

  final double x;
  final double y;

  Map<String, Object> toJson() => {'x': x, 'y': y};

  factory EnvironmentGeometryPoint.fromJson(Map<String, Object?> json) =>
      EnvironmentGeometryPoint(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
      );
}

sealed class EnvironmentGeometryShape {
  const EnvironmentGeometryShape();

  Map<String, Object> toJson();

  factory EnvironmentGeometryShape.fromJson(Map<String, Object?> json) {
    EnvironmentGeometryPoint point(String key) =>
        EnvironmentGeometryPoint.fromJson(json[key] as Map<String, Object?>);
    switch (json['type'] as String) {
      case 'circle':
        return EnvironmentCircle(
          center: point('center'),
          radius: (json['radius'] as num).toDouble(),
        );
      case 'ellipse':
        return EnvironmentEllipse(
          center: point('center'),
          radius: point('radius'),
        );
      case 'rectangle':
        return EnvironmentRectangle(
          center: point('center'),
          size: point('size'),
          rotationDegrees: (json['rotationDegrees'] as num? ?? 0).toDouble(),
        );
      case 'polygon':
        return EnvironmentPolygon(
          points: [
            for (final value in json['points'] as List<Object?>)
              EnvironmentGeometryPoint.fromJson(value as Map<String, Object?>),
          ],
        );
      case 'capsule':
        return EnvironmentCapsule(
          start: point('start'),
          end: point('end'),
          radius: (json['radius'] as num).toDouble(),
        );
      default:
        throw FormatException('Unknown geometry shape type ${json['type']}.');
    }
  }
}

class EnvironmentCircle extends EnvironmentGeometryShape {
  const EnvironmentCircle({required this.center, required this.radius});

  final EnvironmentGeometryPoint center;
  final double radius;

  @override
  Map<String, Object> toJson() => {
    'type': 'circle',
    'center': center.toJson(),
    'radius': radius,
  };
}

class EnvironmentEllipse extends EnvironmentGeometryShape {
  const EnvironmentEllipse({required this.center, required this.radius});

  final EnvironmentGeometryPoint center;
  final EnvironmentGeometryPoint radius;

  @override
  Map<String, Object> toJson() => {
    'type': 'ellipse',
    'center': center.toJson(),
    'radius': radius.toJson(),
  };
}

class EnvironmentRectangle extends EnvironmentGeometryShape {
  const EnvironmentRectangle({
    required this.center,
    required this.size,
    this.rotationDegrees = 0,
  });

  final EnvironmentGeometryPoint center;
  final EnvironmentGeometryPoint size;
  final double rotationDegrees;

  @override
  Map<String, Object> toJson() => {
    'type': 'rectangle',
    'center': center.toJson(),
    'size': size.toJson(),
    if (rotationDegrees != 0) 'rotationDegrees': rotationDegrees,
  };
}

class EnvironmentPolygon extends EnvironmentGeometryShape {
  const EnvironmentPolygon({required this.points});

  final List<EnvironmentGeometryPoint> points;

  @override
  Map<String, Object> toJson() => {
    'type': 'polygon',
    'points': [for (final point in points) point.toJson()],
  };
}

class EnvironmentCapsule extends EnvironmentGeometryShape {
  const EnvironmentCapsule({
    required this.start,
    required this.end,
    required this.radius,
  });

  final EnvironmentGeometryPoint start;
  final EnvironmentGeometryPoint end;
  final double radius;

  @override
  Map<String, Object> toJson() => {
    'type': 'capsule',
    'start': start.toJson(),
    'end': end.toJson(),
    'radius': radius,
  };
}

class EnvironmentAssetGeometry {
  const EnvironmentAssetGeometry({
    this.footprint,
    this.blocking = const [],
    this.walkable = const [],
    this.selection = const [],
    this.reviewed = false,
  });

  static const empty = EnvironmentAssetGeometry();

  final EnvironmentGeometryShape? footprint;
  final List<EnvironmentGeometryShape> blocking;
  final List<EnvironmentGeometryShape> walkable;
  final List<EnvironmentGeometryShape> selection;
  final bool reviewed;

  Map<String, Object> toJson() => {
    if (footprint != null) 'footprint': footprint!.toJson(),
    'blocking': [for (final shape in blocking) shape.toJson()],
    if (walkable.isNotEmpty)
      'walkable': [for (final shape in walkable) shape.toJson()],
    if (selection.isNotEmpty)
      'selection': [for (final shape in selection) shape.toJson()],
    'reviewed': reviewed,
  };

  EnvironmentAssetGeometry copyWith({
    EnvironmentGeometryShape? footprint,
    bool clearFootprint = false,
    List<EnvironmentGeometryShape>? blocking,
    List<EnvironmentGeometryShape>? walkable,
    List<EnvironmentGeometryShape>? selection,
    bool? reviewed,
  }) => EnvironmentAssetGeometry(
    footprint: clearFootprint ? null : footprint ?? this.footprint,
    blocking: blocking ?? this.blocking,
    walkable: walkable ?? this.walkable,
    selection: selection ?? this.selection,
    reviewed: reviewed ?? this.reviewed,
  );

  factory EnvironmentAssetGeometry.fromJson(Map<String, Object?> json) {
    List<EnvironmentGeometryShape> shapes(String key) => [
      for (final value in json[key] as List<Object?>? ?? const [])
        EnvironmentGeometryShape.fromJson(value as Map<String, Object?>),
    ];
    return EnvironmentAssetGeometry(
      footprint: json['footprint'] == null
          ? null
          : EnvironmentGeometryShape.fromJson(
              json['footprint'] as Map<String, Object?>,
            ),
      blocking: shapes('blocking'),
      walkable: shapes('walkable'),
      selection: shapes('selection'),
      reviewed: json['reviewed'] as bool? ?? false,
    );
  }
}

enum EnvironmentRenderBand {
  terrain,
  terrainDetail,
  groundCover,
  depthSorted,
  overhead,
  effects;

  static EnvironmentRenderBand forCategory(String category) {
    switch (category.toLowerCase()) {
      case 'ground cover':
      case 'grass':
        return EnvironmentRenderBand.groundCover;
      default:
        return EnvironmentRenderBand.depthSorted;
    }
  }
}

enum EnvironmentAssetViewMode {
  fixed,
  fourWay,
  eightWay;

  static EnvironmentAssetViewMode infer(Iterable<String> directions) {
    final values = directions.toSet();
    if (values.length == 1 && values.contains('south')) return fixed;
    if (values.length == 4 && values.containsAll(_cardinalDirections)) {
      return fourWay;
    }
    if (values.length == 8 && values.containsAll(_allDirections)) {
      return eightWay;
    }
    throw FormatException('Unsupported environment view set: $values.');
  }

  static const _cardinalDirections = {'south', 'west', 'east', 'north'};
  static const _allDirections = {
    'south',
    'west',
    'east',
    'north',
    'southWest',
    'northWest',
    'southEast',
    'northEast',
  };

  Set<String> get directions => switch (this) {
    fixed => const {'south'},
    fourWay => _cardinalDirections,
    eightWay => _allDirections,
  };
}

class EnvironmentCatalog {
  EnvironmentCatalog({
    required List<EnvironmentMaterial> materials,
    required List<EnvironmentObjectAsset> objects,
    List<EnvironmentSourcePack> sourcePacks = const [],
    Map<String, EnvironmentAssetGeometry>? geometryOverrides,
  }) : _materials = List.of(materials),
       _objects = List.of(objects),
       sourcePacks = List.unmodifiable(sourcePacks),
       _geometryOverrides = Map.of(geometryOverrides ?? const {}) {
    this.materials = UnmodifiableListView(_materials);
    this.objects = UnmodifiableListView(_objects);
    for (final material in _materials) {
      if (_materialsById.containsKey(material.id)) {
        throw ArgumentError.value(material.id, 'materials', 'Duplicate ID');
      }
      _materialsById[material.id] = material;
    }
    for (final object in _objects) {
      if (_objectsById.containsKey(object.id)) {
        throw ArgumentError.value(object.id, 'objects', 'Duplicate ID');
      }
      _objectsById[object.id] = object;
    }
  }

  final List<EnvironmentMaterial> _materials;
  final List<EnvironmentObjectAsset> _objects;
  final List<EnvironmentSourcePack> sourcePacks;
  late final UnmodifiableListView<EnvironmentMaterial> materials;
  late final UnmodifiableListView<EnvironmentObjectAsset> objects;
  final Map<String, EnvironmentMaterial> _materialsById = {};
  final Map<String, EnvironmentObjectAsset> _objectsById = {};
  final Map<String, EnvironmentAssetGeometry> _geometryOverrides;

  Map<String, EnvironmentAssetGeometry> get geometryOverrides =>
      Map.unmodifiable(_geometryOverrides);

  EnvironmentMaterial? materialById(String id) => _materialsById[id];

  EnvironmentObjectAsset? objectById(String id) => _objectsById[id];

  void registerMaterial(EnvironmentMaterial material) {
    if (_materialsById.containsKey(material.id)) {
      throw ArgumentError.value(material.id, 'material', 'Duplicate ID');
    }
    _materials.add(material);
    _materialsById[material.id] = material;
  }

  void registerObject(EnvironmentObjectAsset object) {
    if (_objectsById.containsKey(object.id)) {
      throw ArgumentError.value(object.id, 'object', 'Duplicate ID');
    }
    _objects.add(object);
    _objectsById[object.id] = object;
  }

  EnvironmentAssetGeometry geometryForAsset(EnvironmentObjectAsset asset) =>
      _geometryOverrides[asset.id] ?? asset.geometry;

  EnvironmentAssetGeometry? geometryForObjectId(String id) {
    final asset = objectById(id);
    return asset == null ? null : geometryForAsset(asset);
  }

  void setGeometryOverride(String assetId, EnvironmentAssetGeometry geometry) {
    if (objectById(assetId) == null) {
      throw ArgumentError.value(
        assetId,
        'assetId',
        'Unknown environment asset',
      );
    }
    _geometryOverrides[assetId] = geometry;
  }

  void removeGeometryOverride(String assetId) =>
      _geometryOverrides.remove(assetId);

  void applyGeometryOverridesFromJsonString(String source) {
    final json = jsonDecode(source) as Map<String, Object?>;
    final objects = json['objects'] as Map<String, Object?>? ?? const {};
    for (final entry in objects.entries) {
      if (objectById(entry.key) == null) {
        throw FormatException(
          'Geometry override references unknown ${entry.key}.',
        );
      }
      _geometryOverrides[entry.key] = EnvironmentAssetGeometry.fromJson(
        entry.value as Map<String, Object?>,
      );
    }
  }

  void replaceGeometryOverridesFromJsonString(String source) {
    _geometryOverrides.clear();
    applyGeometryOverridesFromJsonString(source);
  }

  String geometryOverridesToJsonString({bool pretty = true}) {
    final value = <String, Object>{
      'schemaVersion': 1,
      'objects': {
        for (final entry in _geometryOverrides.entries)
          entry.key: entry.value.toJson(),
      },
    };
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(value)
        : jsonEncode(value);
  }

  factory EnvironmentCatalog.fromJsonString(String source) {
    final json = jsonDecode(source) as Map<String, Object?>;
    return EnvironmentCatalog(
      sourcePacks: [
        for (final value in json['sourcePacks'] as List<Object?>? ?? const [])
          EnvironmentSourcePack.fromJson(value as Map<String, Object?>),
      ],
      materials: [
        for (final value in json['materials'] as List<Object?>)
          EnvironmentMaterial.fromJson(value as Map<String, Object?>),
      ],
      objects: [
        for (final value in json['objects'] as List<Object?>)
          EnvironmentObjectAsset.fromJson(value as Map<String, Object?>),
      ],
    );
  }
}

class EnvironmentSourcePack {
  const EnvironmentSourcePack({required this.id, required this.name});

  final String id;
  final String name;

  factory EnvironmentSourcePack.fromJson(Map<String, Object?> json) =>
      EnvironmentSourcePack(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

class EnvironmentMaterial {
  const EnvironmentMaterial({
    required this.id,
    required this.name,
    required this.texturePath,
    required this.decalPath,
    this.sourcePack = '',
    this.textureLogicalWidth = 0,
    this.textureLogicalHeight = 0,
    this.decalLogicalWidth = 0,
    this.decalLogicalHeight = 0,
    this.repeatWorldWidth = 0,
    this.repeatWorldHeight = 0,
    this.defaultRadius = 1.5,
    this.tags = const [],
    this.thumbnailPath,
  });

  final String id;
  final String name;
  final String texturePath;
  final String decalPath;
  final String sourcePack;
  final int textureLogicalWidth;
  final int textureLogicalHeight;
  final int decalLogicalWidth;
  final int decalLogicalHeight;
  final double repeatWorldWidth;
  final double repeatWorldHeight;
  final double defaultRadius;
  final List<String> tags;
  final String? thumbnailPath;

  bool get blocksMovement => tags.contains('non-walkable');

  /// World-space size occupied by one complete repeating texture image.
  ///
  /// Older catalogs used the historical 64 texels-per-world-unit convention.
  /// Keeping that fallback here makes the physical scale explicit without
  /// changing existing material rendering.
  double get effectiveRepeatWorldWidth => repeatWorldWidth > 0
      ? repeatWorldWidth
      : (textureLogicalWidth > 0 ? textureLogicalWidth / 64 : 8);

  double get effectiveRepeatWorldHeight => repeatWorldHeight > 0
      ? repeatWorldHeight
      : (textureLogicalHeight > 0 ? textureLogicalHeight / 64 : 8);

  factory EnvironmentMaterial.fromJson(Map<String, Object?> json) =>
      EnvironmentMaterial(
        id: json['id'] as String,
        name: json['name'] as String,
        texturePath: json['texture'] as String,
        decalPath: json['decal'] as String,
        sourcePack: json['sourcePack'] as String? ?? '',
        textureLogicalWidth: (json['textureLogicalWidth'] as num? ?? 0).toInt(),
        textureLogicalHeight: (json['textureLogicalHeight'] as num? ?? 0)
            .toInt(),
        decalLogicalWidth: (json['decalLogicalWidth'] as num? ?? 0).toInt(),
        decalLogicalHeight: (json['decalLogicalHeight'] as num? ?? 0).toInt(),
        repeatWorldWidth: (json['repeatWorldWidth'] as num? ?? 0).toDouble(),
        repeatWorldHeight: (json['repeatWorldHeight'] as num? ?? 0).toDouble(),
        defaultRadius: (json['defaultRadius'] as num? ?? 1.5).toDouble(),
        tags: [
          for (final value in json['tags'] as List<Object?>? ?? const [])
            value as String,
        ],
        thumbnailPath: json['thumbnail'] as String?,
      );
}

class EnvironmentObjectAsset {
  const EnvironmentObjectAsset({
    required this.id,
    required this.name,
    required this.category,
    required this.renderScale,
    required this.views,
    this.family = '',
    this.sourcePack = '',
    this.categoryPath = const [],
    this.viewMode = EnvironmentAssetViewMode.fixed,
    this.renderBand = EnvironmentRenderBand.depthSorted,
    this.sortAnchorX = 0,
    this.sortAnchorY = 0,
    this.defaultSortBias = 0,
    this.geometry = EnvironmentAssetGeometry.empty,
    this.tags = const [],
    this.thumbnailPath,
    this.collisionProfile,
  });

  final String id;
  final String name;
  final String category;
  final String family;
  final String sourcePack;
  final List<String> categoryPath;
  final EnvironmentAssetViewMode viewMode;
  final double renderScale;
  final EnvironmentRenderBand renderBand;
  final double sortAnchorX;
  final double sortAnchorY;
  final double defaultSortBias;
  final EnvironmentAssetGeometry geometry;
  final Map<String, EnvironmentObjectView> views;
  final List<String> tags;
  final String? thumbnailPath;
  final String? collisionProfile;

  String get categoryBreadcrumb =>
      (categoryPath.isEmpty ? [category] : categoryPath).join(' / ');

  String get topLevelCategory =>
      categoryPath.isEmpty ? category : categoryPath.first;

  bool supportsDirection(String direction) => views.containsKey(direction);

  EnvironmentObjectView viewFor(String direction) {
    final view = views[direction];
    if (view == null) {
      throw StateError('Asset $id does not provide direction $direction.');
    }
    return view;
  }

  double depthAt(double x, double y, {double instanceSortBias = 0}) =>
      x + sortAnchorX + y + sortAnchorY + defaultSortBias + instanceSortBias;

  factory EnvironmentObjectAsset.fromJson(Map<String, Object?> json) {
    final categoryPath = [
      for (final value in json['categoryPath'] as List<Object?>? ?? const [])
        value as String,
    ];
    final category =
        json['category'] as String? ??
        (categoryPath.isEmpty ? 'Uncategorized' : categoryPath.last);
    if (categoryPath.isEmpty) categoryPath.add(category);
    final views = {
      for (final entry in (json['views'] as Map<String, Object?>).entries)
        entry.key: EnvironmentObjectView.fromJson(
          entry.value as Map<String, Object?>,
        ),
    };
    final partialViews = json['partialViews'] as bool? ?? false;
    final declaredMode = json['viewMode'] == null
        ? null
        : EnvironmentAssetViewMode.values.byName(json['viewMode'] as String);
    late final EnvironmentAssetViewMode viewMode;
    if (partialViews) {
      if (declaredMode == null || views.isEmpty) {
        throw FormatException(
          'Partial asset ${json['id']} requires a declared viewMode and views.',
        );
      }
      if (!declaredMode.directions.containsAll(views.keys)) {
        throw FormatException(
          'Partial asset ${json['id']} contains views outside '
          '${declaredMode.name}: ${views.keys.toList()}.',
        );
      }
      viewMode = declaredMode;
    } else {
      final inferredMode = EnvironmentAssetViewMode.infer(views.keys);
      viewMode = declaredMode ?? inferredMode;
      if (viewMode != inferredMode) {
        throw FormatException(
          'Asset ${json['id']} declares ${viewMode.name} but its views are '
          '${views.keys.toList()}.',
        );
      }
    }
    return EnvironmentObjectAsset(
      id: json['id'] as String,
      name: json['name'] as String,
      category: category,
      family: json['family'] as String? ?? '',
      sourcePack: json['sourcePack'] as String? ?? '',
      categoryPath: List.unmodifiable(categoryPath),
      viewMode: viewMode,
      renderScale: (json['renderScale'] as num? ?? 1).toDouble(),
      renderBand: json['renderBand'] == null
          ? EnvironmentRenderBand.forCategory(category)
          : EnvironmentRenderBand.values.byName(json['renderBand'] as String),
      sortAnchorX: (json['sortAnchorX'] as num? ?? 0).toDouble(),
      sortAnchorY: (json['sortAnchorY'] as num? ?? 0).toDouble(),
      defaultSortBias: (json['defaultSortBias'] as num? ?? 0).toDouble(),
      geometry: json['geometry'] == null
          ? EnvironmentAssetGeometry.empty
          : EnvironmentAssetGeometry.fromJson(
              json['geometry'] as Map<String, Object?>,
            ),
      tags: [
        for (final value in json['tags'] as List<Object?>? ?? const [])
          value as String,
      ],
      thumbnailPath: json['thumbnail'] as String?,
      collisionProfile: json['collisionProfile'] as String?,
      views: Map.unmodifiable(views),
    );
  }
}

class EnvironmentObjectView {
  const EnvironmentObjectView({
    required this.imagePath,
    this.logicalWidth = 0,
    this.logicalHeight = 0,
    this.pivotX = 0.5,
    this.pivotY = 1,
  });

  final String imagePath;
  final int logicalWidth;
  final int logicalHeight;
  final double pivotX;
  final double pivotY;

  factory EnvironmentObjectView.fromJson(Map<String, Object?> json) =>
      EnvironmentObjectView(
        imagePath: json['image'] as String,
        logicalWidth: (json['logicalWidth'] as num? ?? 0).toInt(),
        logicalHeight: (json['logicalHeight'] as num? ?? 0).toInt(),
        pivotX: (json['pivotX'] as num? ?? 0.5).toDouble(),
        pivotY: (json['pivotY'] as num? ?? 1).toDouble(),
      );
}
