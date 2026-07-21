import 'package:neura_world/neura_world.dart';
import 'package:test/test.dart';

void main() {
  test('environment document round-trips strokes and generic objects', () {
    final source = EnvironmentDocument(
      id: 'world',
      name: 'World',
      width: 12,
      height: 9,
      baseMaterialId: 'ground.meadow',
      surfaces: [
        EnvironmentSurface(
          id: environmentBaseSurfaceId,
          name: 'Ground',
          materialId: 'ground.meadow',
          points: const [
            WorldPoint(0, 0),
            WorldPoint(12, 0),
            WorldPoint(12, 9),
            WorldPoint(0, 9),
          ],
        ),
        EnvironmentSurface(
          id: 'surface_platform',
          name: 'Platform',
          materialId: 'ground.earth',
          drawsBaseMaterial: false,
          height: const EnvironmentSurfaceHeight.flat(1.5),
          points: const [
            WorldPoint(1, 1),
            WorldPoint(6, 1),
            WorldPoint(6, 6),
            WorldPoint(1, 6),
          ],
        ),
      ],
      liquidVolumes: [
        EnvironmentLiquidVolume(
          id: 'pond',
          name: 'Pond',
          bedSurfaceId: environmentBaseSurfaceId,
          materialId: 'water.blue',
          surfaceElevation: 0.4,
          depth: 0.25,
          endDepth: 1.25,
          depthRampStart: const WorldPoint(7, 1),
          depthRampEnd: const WorldPoint(11, 1),
          points: const [
            WorldPoint(7, 1),
            WorldPoint(11, 1),
            WorldPoint(11, 5),
            WorldPoint(7, 5),
          ],
        ),
      ],
      terrainRegions: [
        TerrainRegion(
          id: 'field_1',
          materialId: 'ground.earth',
          order: 3,
          opacity: 0.72,
          edgeBlend: 0.45,
          surfaceId: 'surface_platform',
          points: const [
            WorldPoint(1, 1),
            WorldPoint(6, 1),
            WorldPoint(6, 6),
            WorldPoint(1, 6),
          ],
        ),
      ],
      terrainStrokes: [
        TerrainStroke(
          materialId: 'ground.earth',
          radius: 2,
          opacity: 0.22,
          seed: 42,
          spacing: 0.72,
          scatter: 0.28,
          sizeJitter: 0.18,
          opacityJitter: 0.16,
          surfaceId: environmentBaseSurfaceId,
          points: const [WorldPoint(1.5, 2), WorldPoint(4, 5.5)],
        ),
      ],
      objects: [
        PlacedEnvironmentObject(
          id: 'tree_1',
          assetId: 'tree.blossom',
          x: 3.25,
          y: 7.5,
          verticalOffset: 1.25,
          sortBias: -0.2,
          direction: EnvironmentDirection.northEast,
          behaviorProfileId: 'cat_household',
          liquidInteraction: EnvironmentLiquidInteraction.float,
          liquidDraft: 0.2,
          supportSurfaceId: 'surface_platform',
          crossSurfaceOcclusion: true,
          occlusionHeight: 5.5,
        ),
      ],
      editorLayers: [
        EditorLayer(id: EnvironmentDocument.rootLayerId, name: 'World'),
        EditorLayer(
          id: 'layer_trees',
          name: 'Trees',
          parentId: EnvironmentDocument.rootLayerId,
        ),
      ],
    );
    source.objects.single.editorLayerId = 'layer_trees';

    final restored = EnvironmentDocument.fromJsonString(source.toJsonString());

    expect(restored.width, 12);
    expect(restored.terrainRegions.single.id, 'field_1');
    expect(restored.terrainRegions.single.opacity, 0.72);
    expect(restored.terrainRegions.single.edgeBlend, 0.45);
    expect(restored.terrainRegions.single.order, 3);
    expect(restored.surfaceById('surface_platform')?.height.elevation, 1.5);
    expect(
      restored.surfaceById('surface_platform')?.drawsBaseMaterial,
      isFalse,
    );
    expect(restored.terrainRegions.single.points.last.y, 6);
    expect(restored.terrainStrokes.single.points.last.y, 5.5);
    expect(restored.terrainStrokes.single.seed, 42);
    expect(restored.terrainStrokes.single.spacing, 0.72);
    expect(restored.terrainStrokes.single.scatter, 0.28);
    expect(restored.terrainStrokes.single.surfaceId, environmentBaseSurfaceId);
    expect(restored.liquidVolumes.single.surfaceElevation, 0.4);
    expect(restored.liquidVolumes.single.depth, 0.25);
    expect(restored.liquidVolumes.single.endDepth, 1.25);
    expect(restored.liquidVolumes.single.depthRampStart?.x, 7);
    expect(restored.liquidVolumes.single.depthRampEnd?.x, 11);
    expect(restored.objects.single.assetId, 'tree.blossom');
    expect(restored.objects.single.direction, EnvironmentDirection.northEast);
    expect(restored.objects.single.verticalOffset, 1.25);
    expect(restored.objects.single.sortBias, -0.2);
    expect(restored.objects.single.behaviorProfileId, 'cat_household');
    expect(
      restored.objects.single.liquidInteraction,
      EnvironmentLiquidInteraction.float,
    );
    expect(restored.objects.single.liquidDraft, 0.2);
    expect(restored.objects.single.supportSurfaceId, 'surface_platform');
    expect(restored.objects.single.crossSurfaceOcclusion, isTrue);
    expect(restored.objects.single.occlusionHeight, 5.5);
    expect(restored.schemaVersion, EnvironmentDocument.currentSchemaVersion);
    expect(restored.objects.single.editorLayerId, 'layer_trees');
    expect(restored.editorLayerById('layer_trees')?.parentId, 'layer_world');
  });

  test('legacy documents are rejected instead of ambiguously migrated', () {
    expect(
      () => EnvironmentDocument.fromJsonString('''
      {
        "schemaVersion": 1,
        "id": "legacy",
        "name": "Legacy",
        "width": 8,
        "height": 8,
        "baseMaterialId": "ground",
        "terrainStrokes": [],
        "objects": [
          {
            "id": "tree_7",
            "assetId": "tree",
            "x": 3.5,
            "y": 4.25,
            "z": 1.5,
            "direction": "south"
          }
        ]
      }
    '''),
      throwsFormatException,
    );
  });

  test('directions rotate clockwise through all eight views', () {
    var direction = EnvironmentDirection.south;
    final seen = <EnvironmentDirection>{};
    for (var index = 0; index < 8; index++) {
      seen.add(direction);
      direction = direction.next;
    }
    expect(seen, EnvironmentDirection.values.toSet());
    expect(direction, EnvironmentDirection.south);
  });

  test('brush stamps are deterministic and independent of pointer density', () {
    TerrainStroke stroke(List<WorldPoint> points) => TerrainStroke(
      materialId: 'earth',
      radius: 2,
      opacity: 0.22,
      seed: 73,
      spacing: 0.72,
      scatter: 0.28,
      sizeJitter: 0.18,
      opacityJitter: 0.16,
      points: points,
    );
    final sparse = terrainStrokeStamps(
      stroke(const [WorldPoint(0, 0), WorldPoint(10, 0)]),
    ).toList();
    final dense = terrainStrokeStamps(
      stroke(const [
        WorldPoint(0, 0),
        WorldPoint(1, 0),
        WorldPoint(2, 0),
        WorldPoint(3, 0),
        WorldPoint(4, 0),
        WorldPoint(5, 0),
        WorldPoint(6, 0),
        WorldPoint(7, 0),
        WorldPoint(8, 0),
        WorldPoint(9, 0),
        WorldPoint(10, 0),
      ]),
    ).toList();

    expect(sparse.length, dense.length);
    for (var index = 0; index < sparse.length; index++) {
      expect(sparse[index].center.x, closeTo(dense[index].center.x, 1e-9));
      expect(sparse[index].center.y, closeTo(dense[index].center.y, 1e-9));
      expect(sparse[index].radius, dense[index].radius);
      expect(sparse[index].opacity, dense[index].opacity);
    }
    expect(sparse.length, lessThan(10));
    expect(sparse.any((stamp) => stamp.center.y != 0), isTrue);
  });

  test('legacy strokes retain their dense centered brush defaults', () {
    final stroke = TerrainStroke.fromJson({
      'materialId': 'earth',
      'radius': 2,
      'opacity': 0.8,
      'surfaceId': environmentBaseSurfaceId,
      'points': [
        {'x': 1, 'y': 2},
      ],
    });

    expect(stroke.spacing, TerrainStroke.legacySpacing);
    expect(stroke.scatter, 0);
    expect(terrainStrokeStamps(stroke).single.center.y, 2);
  });

  test('latest painted stroke determines the terrain material at a point', () {
    final document = EnvironmentDocument(
      id: 'water_test',
      name: 'Water test',
      width: 20,
      height: 20,
      baseMaterialId: 'ground.meadow',
      terrainStrokes: [
        TerrainStroke(
          materialId: 'water.blue',
          radius: 3,
          opacity: 1,
          points: const [WorldPoint(4, 4), WorldPoint(10, 4)],
        ),
        TerrainStroke(
          materialId: 'ground.earth',
          radius: 1,
          opacity: 1,
          points: const [WorldPoint(7, 4)],
        ),
      ],
    );

    expect(
      environmentMaterialAtPoint(document, const WorldPoint(5, 4)),
      'water.blue',
    );
    expect(
      environmentMaterialAtPoint(document, const WorldPoint(7, 4)),
      'ground.earth',
    );
    expect(
      environmentMaterialAtPoint(document, const WorldPoint(18, 18)),
      'ground.meadow',
    );
  });

  test('reset polygons reveal base terrain without producing brush stamps', () {
    final reset = TerrainStroke(
      materialId: 'ground.meadow',
      radius: 0,
      opacity: 1,
      resetsToBase: true,
      points: const [
        WorldPoint(3, 3),
        WorldPoint(7, 3),
        WorldPoint(7, 7),
        WorldPoint(3, 7),
      ],
    );
    final document = EnvironmentDocument(
      id: 'reset_test',
      name: 'Reset test',
      width: 10,
      height: 10,
      baseMaterialId: 'ground.meadow',
      terrainStrokes: [
        TerrainStroke(
          materialId: 'water.blue',
          radius: 5,
          opacity: 1,
          points: const [WorldPoint(5, 5)],
        ),
        reset,
      ],
    );

    expect(terrainStrokeStamps(reset), isEmpty);
    expect(
      environmentMaterialAtPoint(document, const WorldPoint(5, 5)),
      'ground.meadow',
    );
    expect(
      environmentMaterialAtPoint(document, const WorldPoint(2, 5)),
      'water.blue',
    );

    final restored = EnvironmentDocument.fromJsonString(
      document.toJsonString(),
    );
    expect(restored.terrainStrokes.last.resetsToBase, isTrue);
    expect(restored.terrainStrokes.last.points, hasLength(4));
  });

  test('regional fills sit below detail resets and can reveal the default', () {
    final document = EnvironmentDocument(
      id: 'regions',
      name: 'Regions',
      width: 20,
      height: 20,
      baseMaterialId: 'meadow',
      terrainRegions: [
        TerrainRegion(
          id: 'earth',
          materialId: 'earth',
          points: const [
            WorldPoint(2, 2),
            WorldPoint(12, 2),
            WorldPoint(12, 12),
            WorldPoint(2, 12),
          ],
        ),
        TerrainRegion(
          id: 'clear',
          materialId: 'earth',
          resetsToDefault: true,
          order: 1,
          points: const [
            WorldPoint(8, 8),
            WorldPoint(14, 8),
            WorldPoint(14, 14),
            WorldPoint(8, 14),
          ],
        ),
      ],
      terrainStrokes: [
        TerrainStroke(
          materialId: 'water',
          radius: 3,
          opacity: 1,
          points: const [WorldPoint(5, 5)],
        ),
        TerrainStroke(
          materialId: 'meadow',
          radius: 0,
          opacity: 1,
          resetsToBase: true,
          points: const [
            WorldPoint(3, 3),
            WorldPoint(7, 3),
            WorldPoint(7, 7),
            WorldPoint(3, 7),
          ],
        ),
      ],
    );

    expect(
      environmentBaseMaterialAtPoint(document, const WorldPoint(5, 5)),
      'earth',
    );
    expect(
      environmentMaterialAtPoint(document, const WorldPoint(5, 5)),
      'earth',
    );
    expect(
      environmentMaterialAtPoint(document, const WorldPoint(10, 10)),
      'meadow',
    );
    expect(
      environmentMaterialAtPoint(document, const WorldPoint(16, 16)),
      'meadow',
    );
  });

  test('surface sampling resolves raised ground, water surface, and bed', () {
    final document = EnvironmentDocument(
      id: 'surfaces',
      name: 'Surfaces',
      width: 20,
      height: 20,
      baseMaterialId: 'meadow',
      surfaces: [
        EnvironmentSurface(
          id: environmentBaseSurfaceId,
          name: 'Ground',
          materialId: 'meadow',
          points: const [
            WorldPoint(0, 0),
            WorldPoint(20, 0),
            WorldPoint(20, 20),
            WorldPoint(0, 20),
          ],
        ),
        EnvironmentSurface(
          id: 'hill',
          name: 'Hill',
          materialId: 'stone',
          height: const EnvironmentSurfaceHeight.flat(2),
          order: 1,
          points: const [
            WorldPoint(2, 2),
            WorldPoint(10, 2),
            WorldPoint(10, 10),
            WorldPoint(2, 10),
          ],
        ),
      ],
      liquidVolumes: [
        EnvironmentLiquidVolume(
          id: 'pond',
          name: 'Pond',
          bedSurfaceId: environmentBaseSurfaceId,
          materialId: 'water',
          surfaceElevation: 1,
          depth: 0.4,
          order: 1,
          points: const [
            WorldPoint(12, 2),
            WorldPoint(18, 2),
            WorldPoint(18, 8),
            WorldPoint(12, 8),
          ],
        ),
      ],
    );

    EnvironmentSurfaceSample sample(WorldPoint point, {String? surfaceId}) =>
        environmentSurfaceAtPoint(
          document,
          point,
          preferredSurfaceId: surfaceId,
        );

    expect(
      sample(const WorldPoint(6, 6), surfaceId: 'hill').groundElevation,
      2,
    );
    expect(sample(const WorldPoint(2.5, 6)).groundElevation, 2);
    final pond = sample(
      const WorldPoint(15, 5),
      surfaceId: environmentBaseSurfaceId,
    );
    expect(pond.hasLiquid, isTrue);
    expect(pond.liquidSurfaceElevation, 1);
    expect(pond.liquidDepth, 0.4);
    expect(pond.groundElevation, closeTo(0.6, 1e-9));
  });

  test('surface paint does not alter explicit liquid volume semantics', () {
    final document = EnvironmentDocument(
      id: 'shore',
      name: 'Shore',
      width: 10,
      height: 10,
      baseMaterialId: 'meadow',
      liquidVolumes: [
        EnvironmentLiquidVolume(
          id: 'water',
          name: 'Water',
          bedSurfaceId: environmentBaseSurfaceId,
          materialId: 'water',
          surfaceElevation: 0,
          depth: 0.35,
          points: const [
            WorldPoint(0, 0),
            WorldPoint(10, 0),
            WorldPoint(10, 10),
            WorldPoint(0, 10),
          ],
        ),
      ],
      terrainStrokes: [
        TerrainStroke(
          materialId: 'sand',
          radius: 2,
          opacity: 1,
          points: const [WorldPoint(5, 5)],
        ),
      ],
    );

    final sample = environmentSurfaceAtPoint(
      document,
      const WorldPoint(5, 5),
      preferredSurfaceId: environmentBaseSurfaceId,
    );
    expect(sample.hasLiquid, isTrue);
    expect(sample.groundElevation, -0.35);
  });

  test('bathymetry ramp derives local bed elevation from level water', () {
    final document = EnvironmentDocument(
      id: 'shore',
      name: 'Shore',
      width: 12,
      height: 8,
      baseMaterialId: 'sand',
      liquidVolumes: [
        EnvironmentLiquidVolume(
          id: 'sea',
          name: 'Sea',
          bedSurfaceId: environmentBaseSurfaceId,
          materialId: 'water',
          surfaceElevation: 0,
          depth: 0.1,
          endDepth: 2.1,
          depthRampStart: const WorldPoint(1, 4),
          depthRampEnd: const WorldPoint(11, 4),
          points: const [
            WorldPoint(0, 0),
            WorldPoint(12, 0),
            WorldPoint(12, 8),
            WorldPoint(0, 8),
          ],
        ),
      ],
    );

    final shallow = environmentSurfaceAtPoint(
      document,
      const WorldPoint(1, 4),
      preferredSurfaceId: environmentBaseSurfaceId,
    );
    final middle = environmentSurfaceAtPoint(
      document,
      const WorldPoint(6, 4),
      preferredSurfaceId: environmentBaseSurfaceId,
    );
    final deep = environmentSurfaceAtPoint(
      document,
      const WorldPoint(11, 4),
      preferredSurfaceId: environmentBaseSurfaceId,
    );

    expect(shallow.liquidSurfaceElevation, 0);
    expect(shallow.liquidDepth, closeTo(0.1, 1e-9));
    expect(shallow.groundElevation, closeTo(-0.1, 1e-9));
    expect(middle.liquidDepth, closeTo(1.1, 1e-9));
    expect(middle.groundElevation, closeTo(-1.1, 1e-9));
    expect(deep.liquidDepth, closeTo(2.1, 1e-9));
    expect(deep.groundElevation, closeTo(-2.1, 1e-9));
  });
}
