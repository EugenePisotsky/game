import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_game/native_navigation_adapter.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  test(
    'terrain reset polygons restore base navigation after painted water',
    () {
      final input = buildNativeNavigationWorldInput(
        document: EnvironmentDocument(
          id: 'navigation_reset',
          name: 'Navigation reset',
          width: 20,
          height: 20,
          baseMaterialId: 'ground',
          terrainStrokes: [
            TerrainStroke(
              materialId: 'water',
              radius: 4,
              opacity: 1,
              points: const [WorldPoint(10, 10)],
            ),
            TerrainStroke(
              materialId: 'ground',
              radius: 0,
              opacity: 1,
              resetsToBase: true,
              points: const [
                WorldPoint(8, 8),
                WorldPoint(12, 8),
                WorldPoint(12, 12),
                WorldPoint(8, 12),
              ],
            ),
          ],
        ),
        catalog: EnvironmentCatalog(
          materials: const [
            EnvironmentMaterial(
              id: 'ground',
              name: 'Ground',
              texturePath: 'ground.png',
              decalPath: 'ground_decal.png',
            ),
            EnvironmentMaterial(
              id: 'water',
              name: 'Water',
              texturePath: 'water.png',
              decalPath: 'water_decal.png',
              tags: ['non-walkable'],
            ),
          ],
          objects: const [],
        ),
      );

      expect(input.terrainStrokes.first.blocked, isTrue);
      expect(input.terrainStrokes.skip(1), isNotEmpty);
      expect(
        input.terrainStrokes.skip(1).every((stroke) => !stroke.blocked),
        isTrue,
      );
    },
  );

  test('regional fills participate in navigation before detail paint', () {
    final input = buildNativeNavigationWorldInput(
      document: EnvironmentDocument(
        id: 'navigation_regions',
        name: 'Navigation regions',
        width: 20,
        height: 20,
        baseMaterialId: 'ground',
        terrainRegions: [
          TerrainRegion(
            id: 'water',
            materialId: 'water',
            points: const [
              WorldPoint(2, 2),
              WorldPoint(12, 2),
              WorldPoint(12, 12),
              WorldPoint(2, 12),
            ],
          ),
          TerrainRegion(
            id: 'clearing',
            materialId: 'water',
            resetsToDefault: true,
            order: 1,
            points: const [
              WorldPoint(6, 6),
              WorldPoint(10, 6),
              WorldPoint(10, 10),
              WorldPoint(6, 10),
            ],
          ),
        ],
      ),
      catalog: EnvironmentCatalog(
        materials: const [
          EnvironmentMaterial(
            id: 'ground',
            name: 'Ground',
            texturePath: 'ground.png',
            decalPath: 'ground_decal.png',
          ),
          EnvironmentMaterial(
            id: 'water',
            name: 'Water',
            texturePath: 'water.png',
            decalPath: 'water_decal.png',
            tags: ['non-walkable'],
          ),
        ],
        objects: const [],
      ),
    );

    expect(input.terrainStrokes.any((stroke) => stroke.blocked), isTrue);
    expect(input.terrainStrokes.any((stroke) => !stroke.blocked), isTrue);
  });
}
