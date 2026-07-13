import 'environment_chunks.dart';
import 'environment_document.dart';

class EnvironmentDebugScene {
  const EnvironmentDebugScene({
    required this.id,
    required this.description,
    required this.camera,
    required this.player,
    required this.facing,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.clockSeconds,
    required this.randomSeed,
    this.relevantObjectIds = const [],
    this.expectedLoadedChunks = const [],
  });

  final String id;
  final String description;
  final WorldPoint camera;
  final WorldPoint player;
  final String facing;
  final double viewportWidth;
  final double viewportHeight;
  final double clockSeconds;
  final int randomSeed;
  final List<String> relevantObjectIds;
  final List<EnvironmentChunkCoordinate> expectedLoadedChunks;

  factory EnvironmentDebugScene.fromJson(Map<String, Object?> json) {
    WorldPoint point(String key) {
      final value = json[key] as Map<String, Object?>;
      return WorldPoint(
        (value['x'] as num).toDouble(),
        (value['y'] as num).toDouble(),
      );
    }

    return EnvironmentDebugScene(
      id: json['id'] as String,
      description: json['description'] as String,
      camera: point('camera'),
      player: point('player'),
      facing: json['facing'] as String? ?? 'south',
      viewportWidth: (json['viewportWidth'] as num? ?? 800).toDouble(),
      viewportHeight: (json['viewportHeight'] as num? ?? 600).toDouble(),
      clockSeconds: (json['clockSeconds'] as num? ?? 0).toDouble(),
      randomSeed: json['randomSeed'] as int? ?? 1,
      relevantObjectIds: [
        for (final value
            in json['relevantObjectIds'] as List<Object?>? ?? const [])
          value as String,
      ],
      expectedLoadedChunks: [
        for (final value
            in json['expectedLoadedChunks'] as List<Object?>? ?? const [])
          EnvironmentChunkCoordinate.fromJson(value as Map<String, Object?>),
      ],
    );
  }
}
