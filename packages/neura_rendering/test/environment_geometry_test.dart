import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  test('tree collider blocks only the padded trunk area', () {
    const shape = EnvironmentEllipse(
      center: EnvironmentGeometryPoint(0, 0),
      radius: EnvironmentGeometryPoint(0.24, 0.18),
    );
    final tree = PlacedEnvironmentObject(
      id: 'tree',
      assetId: 'tree',
      x: 4,
      y: 5,
    );

    expect(
      environmentShapeContainsPoint(
        shape,
        tree,
        const WorldPoint(4.3, 5),
        padding: 0.12,
      ),
      isTrue,
    );
    expect(
      environmentShapeContainsPoint(
        shape,
        tree,
        const WorldPoint(5, 5),
        padding: 0.12,
      ),
      isFalse,
    );
  });

  test('direction rotates thin fence collision geometry', () {
    const shape = EnvironmentCapsule(
      start: EnvironmentGeometryPoint(-1, 0),
      end: EnvironmentGeometryPoint(1, 0),
      radius: 0.1,
    );
    final fence = PlacedEnvironmentObject(
      id: 'fence',
      assetId: 'fence',
      x: 3,
      y: 3,
      direction: EnvironmentDirection.west,
    );

    expect(
      environmentShapeContainsPoint(shape, fence, const WorldPoint(3, 3.8)),
      isTrue,
    );
    expect(
      environmentShapeContainsPoint(shape, fence, const WorldPoint(3.8, 3)),
      isFalse,
    );
  });

  test('building footprint separates actors behind, inside, and in front', () {
    const asset = EnvironmentObjectAsset(
      id: 'building',
      name: 'Building',
      category: 'Buildings',
      renderScale: 1,
      views: {'south': EnvironmentObjectView(imagePath: 'building.png')},
      geometry: EnvironmentAssetGeometry(
        footprints: [
          EnvironmentRectangle(
            center: EnvironmentGeometryPoint(0, 0),
            size: EnvironmentGeometryPoint(4, 2),
          ),
        ],
      ),
    );
    final building = PlacedEnvironmentObject(
      id: 'building',
      assetId: asset.id,
      x: 10,
      y: 10,
    );

    expect(
      environmentObjectFootprintDepthSpan(asset, building),
      isA<EnvironmentDepthSpan>()
          .having((span) => span.back, 'back', closeTo(17, 0.0001))
          .having((span) => span.front, 'front', closeTo(23, 0.0001)),
    );
    expect(
      environmentPointRelativeToObjectFootprint(
        const WorldPoint(8, 8),
        asset,
        building,
      ),
      EnvironmentPointFootprintPosition.behind,
    );
    expect(
      environmentPointRelativeToObjectFootprint(
        const WorldPoint(10, 10),
        asset,
        building,
      ),
      EnvironmentPointFootprintPosition.inside,
    );
    expect(
      environmentPointRelativeToObjectFootprint(
        const WorldPoint(12, 12),
        asset,
        building,
      ),
      EnvironmentPointFootprintPosition.inFront,
    );
    expect(
      environmentPointRelativeToObjectFootprint(
        const WorldPoint(7, 13),
        asset,
        building,
      ),
      EnvironmentPointFootprintPosition.lateral,
    );
  });

  test('point-only assets retain scalar depth fallback', () {
    const asset = EnvironmentObjectAsset(
      id: 'crate',
      name: 'Crate',
      category: 'Props',
      renderScale: 1,
      views: {'south': EnvironmentObjectView(imagePath: 'crate.png')},
    );
    final crate = PlacedEnvironmentObject(
      id: 'crate',
      assetId: asset.id,
      x: 2,
      y: 3,
    );

    expect(environmentObjectFootprintDepthSpan(asset, crate), isNull);
    expect(
      environmentPointRelativeToObjectFootprint(
        const WorldPoint(4, 4),
        asset,
        crate,
      ),
      EnvironmentPointFootprintPosition.noFootprint,
    );
  });

  test(
    'sloped footprint resolves the local front edge instead of global max',
    () {
      const outline = [
        WorldPoint(-1, 1),
        WorldPoint(1, -1),
        WorldPoint(6, 4),
        WorldPoint(0, 2),
      ];
      const actor = WorldPoint(1, 2.5);

      final global = EnvironmentDepthSpan(
        back: outline
            .map((point) => point.x + point.y)
            .reduce((a, b) => a < b ? a : b),
        front: outline
            .map((point) => point.x + point.y)
            .reduce((a, b) => a > b ? a : b),
      );
      expect(actor.x + actor.y, lessThan(global.front));
      expect(
        environmentPointRelativeToFootprintOutline(actor, outline),
        EnvironmentPointFootprintPosition.inFront,
      );
    },
  );

  test(
    'generic depth graph keeps actor, building, and foreground prop ordered',
    () {
      const buildingOutline = [
        WorldPoint(-1, 1),
        WorldPoint(1, -1),
        WorldPoint(6, 4),
        WorldPoint(0, 2),
      ];
      final ordered = sortEnvironmentDepthEntities([
        EnvironmentDepthEntity(
          id: 'rack',
          value: 'rack',
          contact: const WorldPoint(1, 2.5),
          depth: -100,
        ),
        EnvironmentDepthEntity(
          id: 'building',
          value: 'building',
          contact: const WorldPoint(0, 0),
          depth: 0,
          footprintOutlines: [buildingOutline],
        ),
        EnvironmentDepthEntity(
          id: 'actor',
          value: 'actor',
          contact: const WorldPoint(-0.5, 0.5),
          depth: 100,
        ),
      ]);

      expect(ordered.map((entity) => entity.value), [
        'actor',
        'building',
        'rack',
      ]);
    },
  );

  test('dynamic actor insertion reuses the sorted static depth order', () {
    const buildingOutline = [
      WorldPoint(-1, 1),
      WorldPoint(1, -1),
      WorldPoint(6, 4),
      WorldPoint(0, 2),
    ];
    final building = EnvironmentDepthEntity(
      id: 'building',
      value: 'building',
      contact: const WorldPoint(0, 0),
      depth: 0,
      footprintOutlines: [buildingOutline],
    );
    final rack = EnvironmentDepthEntity(
      id: 'rack',
      value: 'rack',
      contact: const WorldPoint(1, 2.5),
      depth: -100,
    );
    final staticOrder = sortEnvironmentDepthEntities([building, rack]);
    final actor = EnvironmentDepthEntity(
      id: 'actor',
      value: 'actor',
      contact: const WorldPoint(-0.5, 0.5),
      depth: 100,
    );

    final insertionIndex = environmentDepthInsertionIndex(staticOrder, actor);
    final ordered = [...staticOrder]..insert(insertionIndex, actor);

    expect(ordered.map((entity) => entity.value), [
      'actor',
      'building',
      'rack',
    ]);
  });

  test('disconnected depth shapes leave the opening between pillars free', () {
    const leftPillar = [
      WorldPoint(-0.2, -0.2),
      WorldPoint(0.2, -0.2),
      WorldPoint(0.2, 0.2),
      WorldPoint(-0.2, 0.2),
    ];
    const rightPillar = [
      WorldPoint(3.8, -0.2),
      WorldPoint(4.2, -0.2),
      WorldPoint(4.2, 0.2),
      WorldPoint(3.8, 0.2),
    ];
    final shelter = EnvironmentDepthEntity(
      id: 'shelter',
      value: 'shelter',
      contact: const WorldPoint(0, 0),
      depth: 0,
      footprintOutlines: [leftPillar, rightPillar],
    );

    final behindLeftPillar = EnvironmentDepthEntity(
      id: 'behind',
      value: 'behind',
      contact: const WorldPoint(-1, -1),
      depth: -2,
    );
    final insideOpening = EnvironmentDepthEntity(
      id: 'opening',
      value: 'opening',
      contact: const WorldPoint(1, -1),
      depth: 0,
    );

    expect(environmentDepthConstraint(behindLeftPillar, shelter), -1);
    expect(environmentDepthConstraint(insideOpening, shelter), isNull);
  });
}
