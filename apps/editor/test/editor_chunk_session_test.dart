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
