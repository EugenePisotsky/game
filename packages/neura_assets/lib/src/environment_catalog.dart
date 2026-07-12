import 'dart:convert';

class EnvironmentCatalog {
  const EnvironmentCatalog({required this.materials, required this.objects});

  final List<EnvironmentMaterial> materials;
  final List<EnvironmentObjectAsset> objects;

  EnvironmentMaterial? materialById(String id) {
    for (final material in materials) {
      if (material.id == id) return material;
    }
    return null;
  }

  EnvironmentObjectAsset? objectById(String id) {
    for (final object in objects) {
      if (object.id == id) return object;
    }
    return null;
  }

  factory EnvironmentCatalog.fromJsonString(String source) {
    final json = jsonDecode(source) as Map<String, Object?>;
    return EnvironmentCatalog(
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

class EnvironmentMaterial {
  const EnvironmentMaterial({
    required this.id,
    required this.name,
    required this.texturePath,
    required this.decalPath,
    this.defaultRadius = 1.5,
    this.tags = const [],
    this.thumbnailPath,
  });

  final String id;
  final String name;
  final String texturePath;
  final String decalPath;
  final double defaultRadius;
  final List<String> tags;
  final String? thumbnailPath;

  factory EnvironmentMaterial.fromJson(Map<String, Object?> json) =>
      EnvironmentMaterial(
        id: json['id'] as String,
        name: json['name'] as String,
        texturePath: json['texture'] as String,
        decalPath: json['decal'] as String,
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
    this.tags = const [],
    this.thumbnailPath,
    this.collisionProfile,
  });

  final String id;
  final String name;
  final String category;
  final double renderScale;
  final Map<String, EnvironmentObjectView> views;
  final List<String> tags;
  final String? thumbnailPath;
  final String? collisionProfile;

  EnvironmentObjectView viewFor(String direction) =>
      views[direction] ?? views['south'] ?? views.values.first;

  factory EnvironmentObjectAsset.fromJson(Map<String, Object?> json) =>
      EnvironmentObjectAsset(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String,
        renderScale: (json['renderScale'] as num? ?? 1).toDouble(),
        tags: [
          for (final value in json['tags'] as List<Object?>? ?? const [])
            value as String,
        ],
        thumbnailPath: json['thumbnail'] as String?,
        collisionProfile: json['collisionProfile'] as String?,
        views: {
          for (final entry in (json['views'] as Map<String, Object?>).entries)
            entry.key: EnvironmentObjectView.fromJson(
              entry.value as Map<String, Object?>,
            ),
        },
      );
}

class EnvironmentObjectView {
  const EnvironmentObjectView({
    required this.imagePath,
    this.pivotX = 0.5,
    this.pivotY = 1,
  });

  final String imagePath;
  final double pivotX;
  final double pivotY;

  factory EnvironmentObjectView.fromJson(Map<String, Object?> json) =>
      EnvironmentObjectView(
        imagePath: json['image'] as String,
        pivotX: (json['pivotX'] as num? ?? 0.5).toDouble(),
        pivotY: (json['pivotY'] as num? ?? 1).toDouble(),
      );
}
