import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';

void main() {
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

  test('generated assets carry role-specific physical geometry', () async {
    final catalog = EnvironmentCatalog.fromJsonString(
      await File('assets/catalogs/environment_catalog.json').readAsString(),
    );

    final tree = catalog.objectById('ow3.tree.006')!;
    final grass = catalog.objectById('ow3.grass.021')!;
    final fence = catalog.objectById('ow3.fence.wood')!;
    final bridge = catalog.objectById('ow3.dock.short')!;

    expect(tree.geometry.footprint, isA<EnvironmentEllipse>());
    expect(tree.geometry.blocking.single, isA<EnvironmentEllipse>());
    expect(tree.geometry.reviewed, isFalse);
    expect(grass.geometry.blocking, isEmpty);
    expect(fence.geometry.blocking.single, isA<EnvironmentCapsule>());
    expect(bridge.geometry.walkable.single, isA<EnvironmentRectangle>());
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
}
