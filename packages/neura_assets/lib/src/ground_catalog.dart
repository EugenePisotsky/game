import 'dart:convert';

class GroundCatalog {
  const GroundCatalog({required this.collections, required this.items});

  factory GroundCatalog.fromJsonString(String source) {
    final json = jsonDecode(source) as Map<String, Object?>;
    return GroundCatalog(
      collections: [
        for (final value in json['collections'] as List<Object?>)
          GroundCatalogCollection.fromJson(value as Map<String, Object?>),
      ],
      items: [
        for (final value in json['items'] as List<Object?>)
          GroundCatalogItem.fromJson(value as Map<String, Object?>),
      ],
    );
  }

  final List<GroundCatalogCollection> collections;
  final List<GroundCatalogItem> items;

  List<GroundCatalogItem> itemsIn(String collectionId) => [
    for (final item in items)
      if (item.collectionId == collectionId) item,
  ];

  GroundCatalogItem? itemById(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }
}

class GroundCatalogCollection {
  const GroundCatalogCollection({
    required this.id,
    required this.name,
    required this.description,
  });

  factory GroundCatalogCollection.fromJson(Map<String, Object?> json) =>
      GroundCatalogCollection(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
      );

  final String id;
  final String name;
  final String description;
}

class GroundCatalogItem {
  const GroundCatalogItem({
    required this.id,
    required this.name,
    required this.collectionId,
    required this.role,
    required this.stackable,
    required this.description,
    required this.assets,
  });

  factory GroundCatalogItem.fromJson(Map<String, Object?> json) =>
      GroundCatalogItem(
        id: json['id'] as String,
        name: json['name'] as String,
        collectionId: json['collection'] as String,
        role: json['role'] as String,
        stackable: json['stackable'] as bool,
        description: json['description'] as String? ?? '',
        assets: {
          for (final entry in (json['assets'] as Map<String, Object?>).entries)
            entry.key: entry.value as String,
        },
      );

  final String id;
  final String name;
  final String collectionId;
  final String role;
  final bool stackable;
  final String description;
  final Map<String, String> assets;

  String assetForKey(String rotationKey) => assets[rotationKey]!;
}
