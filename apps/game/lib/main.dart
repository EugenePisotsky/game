import 'dart:async';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'neura_game.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NeuraApp());
}

class NeuraApp extends StatelessWidget {
  const NeuraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Neura',
      theme: ThemeData.dark(useMaterial3: true),
      home: const GameScreen(),
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final NeuraGame game = NeuraGame();
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
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    setState(game.toggleChunkDebug);
                  },
                  icon: const Icon(Icons.grid_4x4),
                  label: const Text('Chunks'),
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
    if (!widget.game.isLoaded) return const SizedBox.shrink();
    final chunk = widget.game.currentChunk;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC17211C),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          'chunk ${chunk?.x ?? '-'},${chunk?.y ?? '-'}  '
          'loaded ${widget.game.loadedChunkCount}  '
          'assets ${widget.game.loadedEnvironmentAssetCount}  '
          'loading ${widget.game.preloadingChunkCount}  '
          'pending ${widget.game.pendingUnloadChunkCount}',
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
                  'Tap anywhere to walk · paths avoid authored obstacles',
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
