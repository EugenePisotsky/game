import 'dart:async';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:neura_world/neura_world.dart';

import 'neura_game.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNeuraWorldRust();
  runApp(NeuraApp(debugSceneName: _debugSceneArgument(args)));
}

String? _debugSceneArgument(List<String> args) {
  for (var index = 0; index < args.length; index++) {
    final argument = args[index];
    if (argument.startsWith('--debug-scene=')) {
      return argument.substring('--debug-scene='.length);
    }
    if (argument == '--debug-scene' && index + 1 < args.length) {
      return args[index + 1];
    }
  }
  return null;
}

class NeuraApp extends StatelessWidget {
  const NeuraApp({this.debugSceneName, super.key});

  final String? debugSceneName;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Neura',
      theme: ThemeData.dark(useMaterial3: true),
      home: GameScreen(debugSceneName: debugSceneName),
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({this.debugSceneName, super.key});

  final String? debugSceneName;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final NeuraGame game = NeuraGame(debugSceneName: widget.debugSceneName);
  bool female = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: GameWidget(game: game)),
          const SafeArea(
            child: Padding(padding: EdgeInsets.all(18), child: _Instructions()),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: _StreamingHud(game: game),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    setState(() => female = !female);
                    game.setCharacter(
                      female ? 'other_worlds.female_1' : 'other_worlds.male_1',
                    );
                  },
                  icon: const Icon(Icons.swap_horiz),
                  label: Text(female ? 'Female' : 'Male'),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => setState(game.toggleChunkDebug),
                      icon: const Icon(Icons.grid_4x4),
                      label: const Text('F4 Chunks'),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: () => setState(game.togglePause),
                      icon: Icon(
                        game.diagnosticsPaused ? Icons.play_arrow : Icons.pause,
                      ),
                      label: Text(game.diagnosticsPaused ? 'Resume' : 'Pause'),
                    ),
                    if (game.diagnosticsPaused) ...[
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () => setState(game.stepDebug),
                        icon: const Icon(Icons.skip_next),
                        label: const Text('Step'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamingHud extends StatefulWidget {
  const _StreamingHud({required this.game});

  final NeuraGame game;

  @override
  State<_StreamingHud> createState() => _StreamingHudState();
}

class _StreamingHudState extends State<_StreamingHud> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.game.isLoaded || !widget.game.showDiagnostics) {
      return const SizedBox.shrink();
    }
    final chunk = widget.game.currentChunk;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC17211C),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          'world ${widget.game.playerPosition.x.toStringAsFixed(2)}, '
          '${widget.game.playerPosition.y.toStringAsFixed(2)}  '
          'chunk ${chunk?.x ?? '-'},${chunk?.y ?? '-'}\n'
          'camera ${widget.game.cameraPosition.x.toStringAsFixed(2)}, '
          '${widget.game.cameraPosition.y.toStringAsFixed(2)}  locked to actor\n'
          'loaded ${widget.game.loadedChunkCount}  '
          'preload ${widget.game.preloadingChunkCount}  '
          'unload ${widget.game.pendingUnloadChunkCount}  '
          'cancel ${widget.game.cancelledChunkRequests}\n'
          'refs ${widget.game.loadedEnvironmentAssetCount}  '
          'decoded ${widget.game.decodedImageCount}  '
          'cache ${widget.game.inactiveAssetCount}  '
          '${(widget.game.decodedImageBytes / (1 << 20)).toStringAsFixed(1)} MiB\n'
          'hits ${widget.game.assetCacheHits}  '
          'misses ${widget.game.assetCacheMisses}  '
          'evict ${widget.game.assetCacheEvictions}  '
          'pending ${widget.game.pendingAssetRequests}\n'
          'path ${widget.game.currentPathLength}  '
          'expanded ${widget.game.navigationExpandedNodes}  '
          'native ${widget.game.lastNavigationMicros} µs  '
          'pending ${widget.game.pendingNavigationRequests}\n'
          'terrain cache ${widget.game.terrainPictureCount}  '
          'depth static ${widget.game.depthSortedObjectCount}  '
          'rebuild ${widget.game.sceneDepthCacheBuildCount}\n'
          'animals active ${widget.game.activeAnimalCount}  '
          'known ${widget.game.knownAnimalCount}\n'
          '${widget.game.diagnosticsFps.toStringAsFixed(1)} fps  '
          '${widget.game.diagnosticsFrameMilliseconds.toStringAsFixed(1)} ms frame  '
          '${widget.game.updateTime} ms update  ${widget.game.renderTime} ms render',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _Instructions extends StatelessWidget {
  const _Instructions();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xCC17211C),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x557BD6A0)),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ENVIRONMENT PROTOTYPE',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.4,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Tap to walk · F1 HUD · F2 depth · F3 geometry · F4 chunks · F5 navigation · P pause',
                  style: TextStyle(color: Color(0xFFB8CBBF)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
