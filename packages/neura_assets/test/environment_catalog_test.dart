import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';

void main() {
  test('catalog lookups stay indexed and registration is explicit', () {
    const material = EnvironmentMaterial(
      id: 'earth',
      name: 'Earth',
      texturePath: 'earth.png',
      decalPath: 'earth_decal.png',
    );
    const object = EnvironmentObjectAsset(
      id: 'tree',
      name: 'Tree',
      category: 'Trees',
      renderScale: 1,
      views: {'south': EnvironmentObjectView(imagePath: 'tree.png')},
    );
    final catalog = EnvironmentCatalog(materials: const [], objects: const [])
      ..registerMaterial(material)
      ..registerObject(object);

    expect(catalog.materialById(material.id), same(material));
    expect(catalog.objectById(object.id), same(object));
    expect(() => catalog.materials.add(material), throwsUnsupportedError);
    expect(() => catalog.objects.add(object), throwsUnsupportedError);
    expect(() => catalog.registerMaterial(material), throwsArgumentError);
    expect(() => catalog.registerObject(object), throwsArgumentError);
  });

  test('catalog parses semantic render metadata and depth corrections', () {
    final catalog = EnvironmentCatalog.fromJsonString('''
      {
        "materials": [],
        "objects": [
          {
            "id": "grass.021",
            "name": "Grass 021",
            "category": "Ground cover",
            "renderScale": 1.0,
            "renderBand": "groundCover",
            "sortAnchorX": 0.25,
            "sortAnchorY": -0.1,
            "defaultSortBias": 0.2,
            "views": {"south": {"image": "grass.png"}}
          }
        ]
      }
    ''');

    final grass = catalog.objects.single;
    expect(grass.renderBand, EnvironmentRenderBand.groundCover);
    expect(grass.depthAt(2, 3, instanceSortBias: -0.1), closeTo(5.25, 0.0001));
    expect(
      EnvironmentRenderBand.groundCover.index,
      lessThan(EnvironmentRenderBand.depthSorted.index),
    );
  });

  test('catalog exposes source packs and logical sprite dimensions', () {
    final catalog = EnvironmentCatalog.fromJsonString('''
      {
        "sourcePacks": [{"id": "owdt", "name": "Dark Town"}],
        "materials": [
          {
            "id": "ground",
            "name": "Ground",
            "sourcePack": "owdt",
            "texture": "ground.png",
            "decal": "decal.png",
            "textureLogicalWidth": 2048,
            "textureLogicalHeight": 2048,
            "repeatWorldWidth": 6.5,
            "repeatWorldHeight": 7.5
          }
        ],
        "objects": [
          {
            "id": "building",
            "name": "Building",
            "category": "Buildings",
            "sourcePack": "owdt",
            "renderScale": 0.25,
            "views": {
              "south": {
                "image": "small_release.png",
                "logicalWidth": 2740,
                "logicalHeight": 3001
              }
            }
          }
        ]
      }
    ''');

    expect(catalog.sourcePacks.single.name, 'Dark Town');
    expect(catalog.materials.single.sourcePack, 'owdt');
    expect(catalog.materials.single.textureLogicalWidth, 2048);
    expect(catalog.materials.single.effectiveRepeatWorldWidth, 6.5);
    expect(catalog.materials.single.effectiveRepeatWorldHeight, 7.5);
    expect(catalog.objects.single.views['south']?.logicalWidth, 2740);
    expect(catalog.objects.single.views['south']?.logicalHeight, 3001);
  });

  test('legacy material repeat size follows logical texture dimensions', () {
    const material = EnvironmentMaterial(
      id: 'legacy',
      name: 'Legacy',
      texturePath: 'ground.png',
      decalPath: 'decal.png',
      textureLogicalWidth: 512,
      textureLogicalHeight: 1024,
    );

    expect(material.effectiveRepeatWorldWidth, 8);
    expect(material.effectiveRepeatWorldHeight, 16);
  });

  test('legacy catalogs infer ground cover without changing other props', () {
    const source = '''
      {
        "materials": [],
        "objects": [
          {
            "id": "grass",
            "name": "Grass",
            "category": "Ground cover",
            "renderScale": 1.0,
            "views": {"south": {"image": "grass.png"}}
          },
          {
            "id": "tree",
            "name": "Tree",
            "category": "Trees",
            "renderScale": 1.0,
            "views": {"south": {"image": "tree.png"}}
          }
        ]
      }
    ''';
    final catalog = EnvironmentCatalog.fromJsonString(source);

    expect(
      catalog.objectById('grass')?.renderBand,
      EnvironmentRenderBand.groundCover,
    );
    expect(
      catalog.objectById('tree')?.renderBand,
      EnvironmentRenderBand.depthSorted,
    );
  });

  test('hierarchical categories and directional modes are validated', () {
    final catalog = EnvironmentCatalog.fromJsonString('''
      {
        "materials": [],
        "objects": [
          {
            "id": "barrel",
            "name": "Barrel",
            "family": "barrel",
            "sourcePack": "ow3",
            "categoryPath": ["Props", "Containers"],
            "viewMode": "fourWay",
            "renderScale": 1.0,
            "views": {
              "south": {"image": "1.png"},
              "west": {"image": "2.png"},
              "east": {"image": "3.png"},
              "north": {"image": "4.png"}
            }
          }
        ]
      }
    ''');

    final barrel = catalog.objects.single;
    expect(barrel.category, 'Containers');
    expect(barrel.categoryBreadcrumb, 'Props / Containers');
    expect(barrel.topLevelCategory, 'Props');
    expect(barrel.family, 'barrel');
    expect(barrel.sourcePack, 'ow3');
    expect(barrel.viewMode, EnvironmentAssetViewMode.fourWay);
    expect(() => barrel.viewFor('southWest'), throwsStateError);
  });

  test('declared view mode cannot hide an incomplete source set', () {
    expect(
      () => EnvironmentCatalog.fromJsonString('''
        {
          "materials": [],
          "objects": [
            {
              "id": "bad",
              "name": "Bad",
              "category": "Props",
              "viewMode": "fourWay",
              "renderScale": 1.0,
              "views": {"south": {"image": "only.png"}}
            }
          ]
        }
      '''),
      throwsFormatException,
    );
  });

  test('release catalogs may retain only referenced directional views', () {
    final catalog = EnvironmentCatalog.fromJsonString('''
      {
        "materials": [],
        "objects": [
          {
            "id": "tree",
            "name": "Tree",
            "category": "Trees",
            "viewMode": "eightWay",
            "partialViews": true,
            "renderScale": 1.0,
            "views": {
              "south": {"image": "south.png"},
              "northWest": {"image": "north_west.png"}
            }
          }
        ]
      }
    ''');

    expect(catalog.objects.single.viewMode, EnvironmentAssetViewMode.eightWay);
    expect(catalog.objects.single.views.keys, {'south', 'northWest'});
  });

  test('generated assets carry role-specific physical geometry', () async {
    final catalog = EnvironmentCatalog.fromJsonString(
      await File('assets/catalogs/environment_catalog.json').readAsString(),
    );

    final tree = catalog.objectById('ow3.tree.006')!;
    final grass = catalog.objectById('ow3.grass.021')!;
    final fence = catalog.objectById('ow3.fence.wood')!;
    final bridge = catalog.objectById('ow3.dock.short')!;

    expect(tree.geometry.footprints.single, isA<EnvironmentEllipse>());
    expect(tree.geometry.blocking.single, isA<EnvironmentEllipse>());
    expect(tree.geometry.reviewed, isFalse);
    expect(grass.geometry.blocking, isEmpty);
    expect(fence.geometry.blocking.single, isA<EnvironmentCapsule>());
    expect(bridge.geometry.walkable.single, isA<EnvironmentRectangle>());
  });

  test('generated water materials are paintable and block movement', () async {
    final catalog = EnvironmentCatalog.fromJsonString(
      await File('assets/catalogs/environment_catalog.json').readAsString(),
    );

    for (var number = 1; number <= 3; number++) {
      final id = 'ow3.water.${number.toString().padLeft(3, '0')}';
      final water = catalog.materialById(id);
      expect(water, isNotNull, reason: id);
      expect(water!.blocksMovement, isTrue, reason: id);
      expect(File('assets/images/${water.texturePath}').existsSync(), isTrue);
      expect(File('assets/images/${water.decalPath}').existsSync(), isTrue);
      expect(File('assets/images/${water.thumbnailPath}').existsSync(), isTrue);
    }
  });

  test(
    'dedicated geometry overrides round-trip independently of base assets',
    () {
      final catalog =
          EnvironmentCatalog.fromJsonString('''
      {
        "materials": [],
        "objects": [
          {
            "id": "tree",
            "name": "Tree",
            "category": "Trees",
            "renderScale": 1.0,
            "views": {"south": {"image": "tree.png"}}
          }
        ]
      }
    ''')..setGeometryOverride(
            'tree',
            const EnvironmentAssetGeometry(
              reviewed: true,
              blocking: [
                EnvironmentEllipse(
                  center: EnvironmentGeometryPoint(0, -0.05),
                  radius: EnvironmentGeometryPoint(0.2, 0.15),
                ),
              ],
            ),
          );

      final serialized = catalog.geometryOverridesToJsonString();
      final restored = EnvironmentCatalog.fromJsonString('''
      {
        "materials": [],
        "objects": [
          {
            "id": "tree",
            "name": "Tree",
            "category": "Trees",
            "renderScale": 1.0,
            "views": {"south": {"image": "tree.png"}}
          }
        ]
      }
    ''')..applyGeometryOverridesFromJsonString(serialized);

      final geometry = restored.geometryForObjectId('tree')!;
      expect(geometry.reviewed, isTrue);
      expect(geometry.blocking.single, isA<EnvironmentEllipse>());
      expect((geometry.blocking.single as EnvironmentEllipse).radius.x, 0.2);
    },
  );

  test('direction geometry overrides replace only their sprite view', () {
    final catalog = EnvironmentCatalog.fromJsonString('''
      {
        "materials": [],
        "objects": [
          {
            "id": "fence",
            "name": "Fence",
            "category": "Fences",
            "renderScale": 1.0,
            "viewMode": "fourWay",
            "views": {
              "south": {"image": "fence_s.png"},
              "west": {"image": "fence_w.png"},
              "east": {"image": "fence_e.png"},
              "north": {"image": "fence_n.png"}
            },
            "geometry": {
              "blocking": [
                {
                  "type": "circle",
                  "center": {"x": 0, "y": 0},
                  "radius": 0.1
                }
              ]
            }
          }
        ]
      }
    ''');
    final fence = catalog.objectById('fence')!;

    catalog.setGeometryOverrideForDirection(
      fence.id,
      'west',
      const EnvironmentAssetGeometry(
        reviewed: true,
        blocking: [
          EnvironmentCapsule(
            start: EnvironmentGeometryPoint(-1, 0.25),
            end: EnvironmentGeometryPoint(1, 0.25),
            radius: 0.12,
          ),
        ],
      ),
    );

    expect(
      catalog.geometryForAsset(fence, direction: 'south').blocking.single,
      isA<EnvironmentCircle>(),
    );
    final west = catalog.geometryForAsset(fence, direction: 'west');
    expect(west.reviewed, isTrue);
    expect(west.blocking.single, isA<EnvironmentCapsule>());

    final serialized = catalog.geometryOverridesToJsonString();
    final restored = EnvironmentCatalog.fromJsonString('''
      {
        "materials": [],
        "objects": [
          {
            "id": "fence",
            "name": "Fence",
            "category": "Fences",
            "renderScale": 1.0,
            "viewMode": "fourWay",
            "views": {
              "south": {"image": "fence_s.png"},
              "west": {"image": "fence_w.png"},
              "east": {"image": "fence_e.png"},
              "north": {"image": "fence_n.png"}
            }
          }
        ]
      }
    ''')..applyGeometryOverridesFromJsonString(serialized);
    final restoredFence = restored.objectById('fence')!;
    expect(
      restored
          .geometryForAsset(restoredFence, direction: 'west')
          .blocking
          .single,
      isA<EnvironmentCapsule>(),
    );
    expect(
      restored.geometryForAsset(restoredFence, direction: 'south').blocking,
      hasLength(1),
    );
  });

  test('legacy footprint loads as one plural depth shape', () {
    final geometry = EnvironmentAssetGeometry.fromJson({
      'footprint': {
        'type': 'circle',
        'center': {'x': 0, 'y': 0},
        'radius': 0.2,
      },
      'blocking': <Object?>[],
    });

    expect(geometry.footprints, hasLength(1));
    expect(geometry.footprints.single, isA<EnvironmentCircle>());
    expect(geometry.toJson(), contains('footprints'));
    expect(geometry.toJson(), isNot(contains('footprint')));
  });

  test(
    'animal assets resolve shared behavior profiles and animation clips',
    () {
      final catalog = EnvironmentCatalog.fromJsonString('''
      {
        "materials": [],
        "animalBehaviorProfiles": [
          {
            "id": "cat_household",
            "name": "Household cat",
            "roamingRadius": 5.0,
            "walkSpeedPixelsPerSecond": 100.0,
            "runSpeedPixelsPerSecond": 170.0,
            "minimumPauseSeconds": 1.0,
            "maximumPauseSeconds": 4.0,
            "idleWeight": 0.2,
            "walkWeight": 0.4,
            "runWeight": 0.3,
            "actionWeight": 0.1
          }
        ],
        "objects": [
          {
            "id": "animals.cat_1",
            "name": "Cat 1",
            "category": "Cat",
            "renderScale": 1.0,
            "viewMode": "fixed",
            "views": {"south": {"image": "cat_idle.png"}},
            "animalAnimation": {
              "behaviorProfileId": "cat_household",
              "frameWidth": 80,
              "frameHeight": 80,
              "directionRows": [
                "south", "west", "east", "north",
                "southWest", "northWest", "southEast", "northEast"
              ],
              "idle": {"image": "cat_idle.png", "frames": 3, "framesPerSecond": 4.0},
              "walk": {"image": "cat_walk.png", "frames": 8, "framesPerSecond": 9.0},
              "run": {"image": "cat_run.png", "frames": 8, "framesPerSecond": 12.0},
              "action": {"image": "cat_action.png", "frames": 3, "framesPerSecond": 5.0, "pingPong": true}
            }
          }
        ]
      }
    ''');

      final cat = catalog.objectById('animals.cat_1')!;
      expect(cat.isAnimal, isTrue);
      expect(cat.animalAnimation!.walk.frames, 8);
      expect(cat.animalAnimation!.rowForDirection('northWest'), 5);
      expect(
        catalog
            .animalBehaviorProfileById(cat.animalAnimation!.behaviorProfileId)!
            .roamingRadius,
        5,
      );
    },
  );
}
