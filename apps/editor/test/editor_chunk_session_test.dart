import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_editor/editor_chunk_session.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  test(
    'viewport streaming preserves edited chunks across unload and reload',
    () async {
      final manifest = EnvironmentWorldManifest(
        id: 'world',
        name: 'World',
        chunkSize: 32,
        width: 96,
        height: 32,
        baseMaterialId: 'ground',
        chunks: const [
          EnvironmentChunkCoordinate(0, 0),
          EnvironmentChunkCoordinate(1, 0),
          EnvironmentChunkCoordinate(2, 0),
        ],
        playerSpawn: const ChunkLocalPosition(
          chunk: EnvironmentChunkCoordinate(0, 0),
          localX: 4,
          localY: 4,
        ),
      );
      final chunks = {
        for (final coordinate in manifest.chunks)
          coordinate: EnvironmentChunkDocument(
            worldId: manifest.id,
            coordinate: coordinate,
            size: 32,
            baseMaterialId: 'ground',
            objects: coordinate.x == 0
                ? [
                    ChunkPlacedEnvironmentObject(
                      id: 'tree',
                      assetId: 'tree',
                      localX: 5,
                      localY: 5,
                      editorLayerId: EnvironmentDocument.rootLayerId,
                      bounds: const EnvironmentObjectBounds(
                        minX: 4.5,
                        minY: 4.5,
                        maxX: 5.5,
                        maxY: 5.5,
                      ),
                    ),
                  ]
                : null,
          ),
      };
      final bundle = _StringAssetBundle({
        for (final entry in chunks.entries)
          '$environmentWorldChunksAssetPrefix/${entry.key.key}.json': entry
              .value
              .toJsonString(),
      });
      final catalog = EnvironmentCatalog(
        materials: const [],
        objects: const [
          EnvironmentObjectAsset(
            id: 'tree',
            name: 'Tree',
            category: 'Trees',
            renderScale: 1,
            views: {'south': EnvironmentObjectView(imagePath: 'tree.png')},
          ),
        ],
      );
      final session = EditorChunkSession(
        manifest: manifest,
        catalog: catalog,
        bundle: bundle,
      );
      var document = await session.initialize();
      final tree = document.objects.singleWhere(
        (object) => object.id == 'tree',
      );
      tree.x = 8;

      session.capture(document);
      expect(session.dirtyCoordinates, {
        const EnvironmentChunkCoordinate(0, 0),
      });

      document =
          await session.streamForBounds(
            document,
            minX: 150,
            minY: 0,
            maxX: 160,
            maxY: 10,
          ) ??
          document;
      document =
          await session.streamForBounds(
            document,
            minX: 0,
            minY: 0,
            maxX: 10,
            maxY: 10,
          ) ??
          document;

      expect(
        document.objects.singleWhere((object) => object.id == 'tree').x,
        8,
      );
      expect(
        session.dirtyCoordinates,
        contains(const EnvironmentChunkCoordinate(0, 0)),
      );
    },
  );

  test(
    'streaming preserves the live bathymetry ramp across chunk replicas',
    () async {
      const chunkSize = 32.0;
      final coordinates = [
        for (var x = 0; x < 5; x++) EnvironmentChunkCoordinate(x, 0),
      ];
      final manifest = EnvironmentWorldManifest(
        id: 'world',
        name: 'World',
        chunkSize: chunkSize,
        width: chunkSize * coordinates.length,
        height: chunkSize,
        baseMaterialId: 'ground',
        chunks: coordinates,
        playerSpawn: const ChunkLocalPosition(
          chunk: EnvironmentChunkCoordinate(0, 0),
          localX: 4,
          localY: 4,
        ),
      );
      final chunks = {
        for (final coordinate in coordinates)
          coordinate: EnvironmentChunkDocument(
            worldId: manifest.id,
            coordinate: coordinate,
            size: chunkSize,
            baseMaterialId: 'ground',
            liquidVolumes: [
              EnvironmentLiquidVolume(
                id: 'harbor',
                name: 'Harbor',
                bedSurfaceId: environmentBaseSurfaceId,
                materialId: 'water',
                points: [
                  WorldPoint(1 - coordinate.x * chunkSize, 1),
                  WorldPoint(159 - coordinate.x * chunkSize, 1),
                  WorldPoint(159 - coordinate.x * chunkSize, 31),
                  WorldPoint(1 - coordinate.x * chunkSize, 31),
                ],
                surfaceElevation: 0,
                depth: 0.25,
                endDepth: 3,
                depthRampStart: WorldPoint(8 - coordinate.x * chunkSize, 16),
                depthRampEnd: WorldPoint(152 - coordinate.x * chunkSize, 16),
              ),
            ],
          ),
      };
      final session = EditorChunkSession(
        manifest: manifest,
        catalog: EnvironmentCatalog(materials: const [], objects: const []),
        bundle: _StringAssetBundle({
          for (final entry in chunks.entries)
            '$environmentWorldChunksAssetPrefix/${entry.key.key}.json': entry
                .value
                .toJsonString(),
        }),
      );
      var document = await session.initialize();
      final liquid = document.liquidVolumes.single;
      liquid.depthRampStart = const WorldPoint(18, 12);
      liquid.depthRampEnd = const WorldPoint(143, 23);

      document =
          await session.streamForBounds(
            document,
            minX: 140,
            minY: 4,
            maxX: 156,
            maxY: 28,
          ) ??
          document;

      final streamedLiquid = document.liquidVolumes.single;
      expect(
        (streamedLiquid.depthRampStart!.x, streamedLiquid.depthRampStart!.y),
        (18, 12),
      );
      expect(
        (streamedLiquid.depthRampEnd!.x, streamedLiquid.depthRampEnd!.y),
        (143, 23),
      );
    },
  );

  test('world extension and player spawn update the live manifest', () async {
    final manifest = EnvironmentWorldManifest(
      id: 'world',
      name: 'World',
      chunkSize: 32,
      width: 32,
      height: 32,
      baseMaterialId: 'ground',
      chunks: const [EnvironmentChunkCoordinate(0, 0)],
      playerSpawn: const ChunkLocalPosition(
        chunk: EnvironmentChunkCoordinate(0, 0),
        localX: 4,
        localY: 5,
      ),
    );
    final chunk = EnvironmentChunkDocument(
      worldId: 'world',
      coordinate: const EnvironmentChunkCoordinate(0, 0),
      size: 32,
      baseMaterialId: 'ground',
    );
    final session = EditorChunkSession(
      manifest: manifest,
      catalog: EnvironmentCatalog(materials: const [], objects: const []),
      bundle: _StringAssetBundle({
        '$environmentWorldChunksAssetPrefix/0_0.json': chunk.toJsonString(),
      }),
    );
    final document = await session.initialize();

    document.baseMaterialId = 'mud';
    session.capture(document);
    expect(session.manifest.baseMaterialId, 'mud');
    expect(session.manifestDirty, isTrue);

    final result = await session.extendWorld(
      document,
      EnvironmentWorldEdge.left,
      visibleBounds: const EnvironmentObjectBounds(
        minX: 0,
        minY: 0,
        maxX: 32,
        maxY: 32,
      ),
    );

    expect(session.manifest.width, 64);
    expect(session.manifest.chunks, hasLength(2));
    expect((result.worldShift.x, result.worldShift.y), (32, 0));
    expect(session.dirtyCoordinates, hasLength(2));
    expect(session.manifestDirty, isTrue);
    expect((session.playerSpawn.x, session.playerSpawn.y), (36, 5));

    session.setPlayerSpawn(const WorldPoint(10, 12));
    expect((session.playerSpawn.x, session.playerSpawn.y), (10, 12));
  });

  test(
    'finds and safely repairs duplicate IDs across distant chunks',
    () async {
      final manifest = EnvironmentWorldManifest(
        id: 'world',
        name: 'World',
        chunkSize: 32,
        width: 96,
        height: 32,
        baseMaterialId: 'ground',
        chunks: const [
          EnvironmentChunkCoordinate(0, 0),
          EnvironmentChunkCoordinate(1, 0),
          EnvironmentChunkCoordinate(2, 0),
        ],
        playerSpawn: const ChunkLocalPosition(
          chunk: EnvironmentChunkCoordinate(0, 0),
          localX: 4,
          localY: 4,
        ),
      );
      EnvironmentChunkDocument chunk(EnvironmentChunkCoordinate coordinate) {
        final hasObject = coordinate.x != 1;
        final worldX = coordinate.x * 32 + 5.0;
        return EnvironmentChunkDocument(
          worldId: manifest.id,
          coordinate: coordinate,
          size: 32,
          baseMaterialId: 'ground',
          objects: hasObject
              ? [
                  ChunkPlacedEnvironmentObject(
                    id: 'object_105',
                    assetId: coordinate.x == 0 ? 'tree' : 'grass',
                    localX: 5,
                    localY: 5,
                    editorLayerId: EnvironmentDocument.rootLayerId,
                    bounds: EnvironmentObjectBounds(
                      minX: worldX - 0.5,
                      minY: 4.5,
                      maxX: worldX + 0.5,
                      maxY: 5.5,
                    ),
                  ),
                ]
              : null,
          overlapObjectIds: hasObject ? {'object_105'} : null,
        );
      }

      final chunks = {
        for (final coordinate in manifest.chunks) coordinate: chunk(coordinate),
      };
      final session = EditorChunkSession(
        manifest: manifest,
        catalog: EnvironmentCatalog(materials: const [], objects: const []),
        bundle: _StringAssetBundle({
          for (final entry in chunks.entries)
            '$environmentWorldChunksAssetPrefix/${entry.key.key}.json': entry
                .value
                .toJsonString(),
        }),
      );
      final document = await session.initialize();

      final issues = await session.findDuplicateObjectIds(document);
      expect(issues, hasLength(1));
      expect(issues.single.id, 'object_105');
      expect(
        issues.single.occurrences.map((occurrence) => occurrence.chunk),
        const [
          EnvironmentChunkCoordinate(0, 0),
          EnvironmentChunkCoordinate(2, 0),
        ],
      );

      final repaired = await session.repairDuplicateObjectIds(document);
      expect(repaired.repairs, hasLength(1));
      expect(
        repaired.repairs.single.chunk,
        const EnvironmentChunkCoordinate(2, 0),
      );
      expect(
        repaired.repairs.single.replacementId,
        startsWith('object_105_repair_2_0_'),
      );
      expect(await session.findDuplicateObjectIds(repaired.document), isEmpty);
      expect(
        session.dirtyCoordinates,
        contains(const EnvironmentChunkCoordinate(2, 0)),
      );
    },
  );
}

class _StringAssetBundle extends CachingAssetBundle {
  _StringAssetBundle(this.sources);

  final Map<String, String> sources;

  @override
  Future<ByteData> load(String key) async {
    final bytes = Uint8List.fromList(utf8.encode(sources[key]!));
    return ByteData.sublistView(bytes);
  }
}
