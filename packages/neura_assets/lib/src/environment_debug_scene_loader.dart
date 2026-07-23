import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:neura_world/neura_world.dart';

const environmentDebugSceneAssetPrefix =
    'packages/neura_assets/assets/debug_scenes';
const environmentDebugSceneNames = <String>[
  'grass_below_actor',
  'tree_actor_depth',
  'overlapping_selection',
  'marquee_selection',
  'tree_trunk_collision',
  'chunk_boundary',
  'chunk_streaming_reversal',
  'lighting_experiment',
];

Future<EnvironmentDebugScene> loadEnvironmentDebugScene(
  AssetBundle bundle,
  String name,
) async {
  if (!environmentDebugSceneNames.contains(name)) {
    throw ArgumentError.value(name, 'name', 'Unknown environment debug scene');
  }
  return EnvironmentDebugScene.fromJson(
    jsonDecode(
      await bundle.loadString('$environmentDebugSceneAssetPrefix/$name.json'),
    ) as Map<String, Object?>,
  );
}
