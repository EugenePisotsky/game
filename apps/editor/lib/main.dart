import 'dart:async';
import 'dart:io';

import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

import 'editor_chunk_session.dart';
import 'editor_controller.dart';
import 'editor_game.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 160
    ..maximumSizeBytes = 32 << 20;
  runApp(NeuraEditorApp(debugSceneName: _debugSceneArgument(args)));
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

class NeuraEditorApp extends StatelessWidget {
  const NeuraEditorApp({this.debugSceneName, super.key});

  final String? debugSceneName;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Neura Environment Designer',
    theme: ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF83B795),
        brightness: Brightness.dark,
        surface: const Color(0xFF171D19),
      ),
      scaffoldBackgroundColor: const Color(0xFF101411),
      useMaterial3: true,
    ),
    home: EditorBootstrap(debugSceneName: debugSceneName),
  );
}

class EditorBootstrap extends StatefulWidget {
  const EditorBootstrap({this.debugSceneName, super.key});

  final String? debugSceneName;

  @override
  State<EditorBootstrap> createState() => _EditorBootstrapState();
}

class _EditorBootstrapState extends State<EditorBootstrap> {
  late final Future<_EditorBootstrapData> _data = _load();

  Future<_EditorBootstrapData> _load() async {
    final sources = await Future.wait([
      environmentCatalogFile().readAsString(),
      environmentGeometryOverridesFile().readAsString(),
    ]);
    final catalog = EnvironmentCatalog.fromJsonString(sources[0])
      ..applyGeometryOverridesFromJsonString(sources[1]);
    final manifest = await loadWorkspaceEnvironmentWorldManifest();
    final debugSceneName = widget.debugSceneName;
    final debugScene = debugSceneName == null
        ? null
        : await loadEnvironmentDebugScene(rootBundle, debugSceneName);
    final session = EditorChunkSession(
      manifest: manifest,
      catalog: catalog,
      repository: const WorkspaceEnvironmentChunkRepository(),
    );
    var document = await session.initialize();
    if (debugScene != null) {
      document =
          await session.streamForBounds(
            document,
            minX: debugScene.camera.x - 16,
            minY: debugScene.camera.y - 16,
            maxX: debugScene.camera.x + 16,
            maxY: debugScene.camera.y + 16,
          ) ??
          document;
    }
    return _EditorBootstrapData(
      source: document.toJsonString(),
      catalog: catalog,
      chunkSession: session,
      initialWorldCenter: debugScene?.camera,
      debugRelevantObjectIds: debugScene?.relevantObjectIds ?? const [],
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_EditorBootstrapData>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          body: Center(child: Text('Could not load editor: ${snapshot.error}')),
        );
      }
      final data = snapshot.data;
      if (data == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return EditorScreen(
        starterSource: data.source,
        catalog: data.catalog,
        chunkSession: data.chunkSession,
        initialWorldCenter: data.initialWorldCenter,
        debugRelevantObjectIds: data.debugRelevantObjectIds,
      );
    },
  );
}

class _EditorBootstrapData {
  const _EditorBootstrapData({
    required this.source,
    required this.catalog,
    required this.chunkSession,
    required this.initialWorldCenter,
    required this.debugRelevantObjectIds,
  });

  final String source;
  final EnvironmentCatalog catalog;
  final EditorChunkSession chunkSession;
  final WorldPoint? initialWorldCenter;
  final List<String> debugRelevantObjectIds;
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.starterSource,
    required this.catalog,
    this.renderGame = true,
    this.controllerOverride,
    this.chunkSession,
    this.initialWorldCenter,
    this.debugRelevantObjectIds = const [],
    super.key,
  });

  final String starterSource;
  final EnvironmentCatalog catalog;
  final bool renderGame;
  final EditorController? controllerOverride;
  final EditorChunkSession? chunkSession;
  final WorldPoint? initialWorldCenter;
  final List<String> debugRelevantObjectIds;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EnvironmentDocument _starter = EnvironmentDocument.fromJsonString(
    widget.starterSource,
  );
  late final EditorController controller =
      widget.controllerOverride ??
      EditorController(
        EnvironmentDocument.fromJsonString(widget.starterSource),
        catalog: widget.catalog,
      );
  late final EditorGame game = EditorGame(
    controller,
    loadedChunks: widget.chunkSession == null
        ? null
        : () => widget.chunkSession!.loadedCoordinates,
    initialWorldCenter:
        widget.initialWorldCenter ??
        widget.chunkSession?.manifest.playerSpawn.toWorld(
          widget.chunkSession!.manifest.chunkSize,
        ),
    chunkSize: widget.chunkSession?.manifest.chunkSize ?? 32,
  );
  bool _gesturing = false;
  bool _marqueeSelecting = false;
  bool _movingSelection = false;
  Offset? _gestureScreenStart;
  WorldPoint? _lastGestureWorld;
  Duration? _lastPanEventTime;
  Timer? _scrollPanEndTimer;
  Timer? _chunkStreamTimer;

  @override
  void initState() {
    super.initState();
    final available = controller.document.objects
        .map((object) => object.id)
        .toSet();
    final relevant = widget.debugRelevantObjectIds
        .where(available.contains)
        .toList();
    if (relevant.isNotEmpty) {
      controller
        ..selectMode(EnvironmentEditorMode.select)
        ..selectObjectIds(relevant);
    }
  }

  @override
  void dispose() {
    _scrollPanEndTimer?.cancel();
    _chunkStreamTimer?.cancel();
    if (widget.controllerOverride == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
          controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
          controller.redo,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
          controller.undo,
      const SingleActivator(LogicalKeyboardKey.keyY, control: true):
          controller.redo,
      const SingleActivator(LogicalKeyboardKey.escape):
          controller.clearSelection,
      const SingleActivator(LogicalKeyboardKey.delete):
          controller.deleteSelected,
      const SingleActivator(LogicalKeyboardKey.backspace):
          controller.deleteSelected,
      const SingleActivator(LogicalKeyboardKey.f1): () =>
          setState(() => game.showDiagnostics = !game.showDiagnostics),
      const SingleActivator(LogicalKeyboardKey.f2): () =>
          setState(() => game.showRenderDebug = !game.showRenderDebug),
      const SingleActivator(LogicalKeyboardKey.f3): () =>
          setState(() => game.showGeometryDebug = !game.showGeometryDebug),
      const SingleActivator(LogicalKeyboardKey.f4): () =>
          setState(() => game.showChunkDebug = !game.showChunkDebug),
      const SingleActivator(LogicalKeyboardKey.f5): () =>
          setState(() => game.showNavigationDebug = !game.showNavigationDebug),
      const SingleActivator(LogicalKeyboardKey.keyP): () =>
          setState(game.togglePause),
      const SingleActivator(LogicalKeyboardKey.period): game.stepDebug,
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: Column(
          children: [
            _Toolbar(
              controller: controller,
              onZoomIn: () => _zoomBy(1.2),
              onZoomOut: () => _zoomBy(1 / 1.2),
              onExport: _showExport,
              onBuildRelease: widget.chunkSession == null
                  ? null
                  : _buildRelease,
              onImport: _showImport,
              onSaveChunks: widget.chunkSession == null ? null : _saveChunks,
              onReset: () => controller.replaceDocument(
                EnvironmentDocument.fromJson(_starter.toJson()),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  _Palette(controller: controller),
                  const VerticalDivider(width: 1),
                  Expanded(child: ClipRect(child: _canvas())),
                  const VerticalDivider(width: 1),
                  _Inspector(controller: controller),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _canvas() => MouseRegion(
    onExit: (_) {
      controller
        ..hover(null)
        ..hoverObjects(const []);
    },
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerHover: (event) => _hoverAt(event.localPosition),
      onPointerDown: (event) {
        if (event.buttons & kPrimaryButton == 0) return;
        _gesturing = true;
        _gestureScreenStart = event.localPosition;
        _lastGestureWorld = _worldAt(event.localPosition);
        controller.beginGesture();
        if (controller.isObjectSelectionMode) {
          final candidates = game.hitTestObjectIds(
            Vector2(event.localPosition.dx, event.localPosition.dy),
          );
          controller.selectCandidates(
            candidates,
            additive: HardwareKeyboard.instance.isShiftPressed,
          );
          _movingSelection = candidates.isNotEmpty;
          _marqueeSelecting = candidates.isEmpty;
          if (_marqueeSelecting) {
            game.setSelectionMarquee(
              Rect.fromPoints(event.localPosition, event.localPosition),
            );
          }
        } else {
          _applyAt(event.localPosition);
        }
      },
      onPointerMove: (event) {
        _hoverAt(event.localPosition);
        if (!_gesturing) return;
        if (controller.isObjectSelectionMode && _marqueeSelecting) {
          game.setSelectionMarquee(
            Rect.fromPoints(_gestureScreenStart!, event.localPosition),
          );
          return;
        }
        final point = _worldAt(event.localPosition);
        if (point == null) return;
        if (controller.isObjectSelectionMode && _movingSelection) {
          final previous = _lastGestureWorld;
          if (previous != null) {
            controller.moveSelectionDuringGesture(previous, point);
          }
          _lastGestureWorld = point;
        } else {
          controller.applyAt(point);
        }
      },
      onPointerUp: (event) => _endGesture(event.localPosition),
      onPointerCancel: (_) => _endGesture(),
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        _beginPan();
        game.panByScreenDelta(
          Vector2(-event.scrollDelta.dx, -event.scrollDelta.dy),
          elapsedSeconds: _panElapsed(event.timeStamp),
        );
        _scrollPanEndTimer?.cancel();
        _scrollPanEndTimer = Timer(const Duration(milliseconds: 55), () {
          game.endPan();
          _scheduleChunkStreaming();
        });
      },
      onPointerPanZoomStart: (event) {
        _lastPanEventTime = event.timeStamp;
        game.beginPan();
      },
      onPointerPanZoomUpdate: (event) {
        game.panByScreenDelta(
          Vector2(event.panDelta.dx, event.panDelta.dy),
          elapsedSeconds: _panElapsed(event.timeStamp),
        );
        _scheduleChunkStreaming();
      },
      onPointerPanZoomEnd: (_) {
        game.endPan();
        _scheduleChunkStreaming();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: widget.renderGame
                ? GameWidget(game: game)
                : const ColoredBox(color: Color(0xFF111713)),
          ),
          Positioned(
            left: 14,
            top: 14,
            child: _EditorDiagnosticsHud(
              game: game,
              controller: controller,
              session: widget.chunkSession,
            ),
          ),
          Positioned(
            left: 14,
            bottom: 14,
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final point = controller.hoveredPoint;
                return _StatusChip(
                  text: point == null
                      ? 'Move over the environment'
                      : 'x ${point.x.toStringAsFixed(2)}  y ${point.y.toStringAsFixed(2)}',
                );
              },
            ),
          ),
          Positioned(
            right: 14,
            bottom: 14,
            child: _StatusChip(
              text: widget.chunkSession == null
                  ? 'Drag to paint  •  Two-finger pan'
                  : '${widget.chunkSession!.loadedCoordinates.length} chunks loaded  •  ${widget.chunkSession!.dirtyCoordinates.length} dirty',
            ),
          ),
        ],
      ),
    ),
  );

  WorldPoint? _worldAt(Offset position) =>
      game.worldAtScreen(Vector2(position.dx, position.dy));

  void _hoverAt(Offset position) {
    controller.hover(_worldAt(position));
    if (controller.isObjectSelectionMode) {
      controller.hoverObjects(
        game.hitTestObjectIds(Vector2(position.dx, position.dy)),
      );
    } else {
      controller.hoverObjects(const []);
    }
  }

  void _applyAt(Offset position) {
    final point = _worldAt(position);
    if (point != null) controller.applyAt(point);
  }

  void _endGesture([Offset? position]) {
    if (!_gesturing) return;
    if (_marqueeSelecting && position != null) {
      final rect = Rect.fromPoints(_gestureScreenStart!, position);
      final keyboard = HardwareKeyboard.instance;
      controller.selectObjectIds(
        game.objectIdsInMarquee(
          rect,
          requireContainment: keyboard.isAltPressed,
        ),
        additive: keyboard.isShiftPressed,
        toggle: keyboard.isMetaPressed || keyboard.isControlPressed,
      );
    }
    _gesturing = false;
    _marqueeSelecting = false;
    _movingSelection = false;
    _gestureScreenStart = null;
    _lastGestureWorld = null;
    game.setSelectionMarquee(null);
    controller.endGesture();
  }

  void _beginPan() {
    _lastPanEventTime ??= Duration.zero;
    game.beginPan();
  }

  void _zoomBy(double factor) {
    game.zoomBy(factor);
    _scheduleChunkStreaming();
  }

  void _scheduleChunkStreaming() {
    final session = widget.chunkSession;
    if (session == null || !game.isLoaded) return;
    _chunkStreamTimer?.cancel();
    _chunkStreamTimer = Timer(const Duration(milliseconds: 80), () async {
      final bounds = game.visibleWorldBounds();
      final streamed = await session.streamForBounds(
        controller.document,
        minX: bounds.minX,
        minY: bounds.minY,
        maxX: bounds.maxX,
        maxY: bounds.maxY,
      );
      if (streamed != null && mounted) {
        controller.replaceDocumentFromStreaming(streamed);
        setState(() {});
      }
    });
  }

  Future<void> _saveChunks() async {
    final session = widget.chunkSession;
    if (session == null) return;
    await session.saveDirty(controller.document);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Dirty chunks saved independently.')),
    );
  }

  double _panElapsed(Duration now) {
    final previous = _lastPanEventTime;
    _lastPanEventTime = now;
    if (previous == null) return 1 / 60;
    return mathMax((now - previous).inMicroseconds / 1000000, 1 / 240);
  }

  Future<void> _showExport() async {
    final source = controller.document.toJsonString();
    await Clipboard.setData(ClipboardData(text: source));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('World JSON copied'),
        content: SizedBox(
          width: 620,
          child: SelectableText(source, maxLines: 18),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _buildRelease() async {
    final session = widget.chunkSession;
    if (session == null) return;
    await session.saveDirty(controller.document);
    if (mounted) setState(() {});
    final root = repositoryRootForNeuraAssets();
    final result = await Process.run('cargo', const [
      'run',
      '--quiet',
      '--manifest-path',
      'tool/environment_importer/Cargo.toml',
      '--',
      'export-world',
    ], workingDirectory: root.path);
    if (!mounted) return;
    if (result.exitCode != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Release export failed: ${result.stderr}')),
      );
      return;
    }
    final report = await environmentReleaseAssetReportFile().readAsString();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Release assets exported'),
        content: SizedBox(
          width: 620,
          child: SelectableText(report, maxLines: 20),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showImport() async {
    final field = TextEditingController();
    final source = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import world JSON'),
        content: SizedBox(
          width: 620,
          child: TextField(
            controller: field,
            minLines: 12,
            maxLines: 18,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    field.dispose();
    if (source == null || source.trim().isEmpty) return;
    try {
      controller.replaceDocument(EnvironmentDocument.fromJsonString(source));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $error')));
    }
  }
}

double mathMax(double a, double b) => a > b ? a : b;

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onExport,
    this.onBuildRelease,
    required this.onImport,
    required this.onReset,
    this.onSaveChunks,
  });

  final EditorController controller;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onExport;
  final VoidCallback? onBuildRelease;
  final VoidCallback onImport;
  final VoidCallback onReset;
  final VoidCallback? onSaveChunks;

  @override
  Widget build(BuildContext context) => Container(
    height: 58,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        const Icon(Icons.landscape_outlined),
        const SizedBox(width: 10),
        const Text(
          'NEURA ENVIRONMENT DESIGNER',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 1.2),
        ),
        const Spacer(),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Row(
            children: [
              IconButton(
                tooltip: 'Undo',
                onPressed: controller.canUndo ? controller.undo : null,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'Redo',
                onPressed: controller.canRedo ? controller.redo : null,
                icon: const Icon(Icons.redo),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Zoom out',
          onPressed: onZoomOut,
          icon: const Icon(Icons.zoom_out),
        ),
        IconButton(
          tooltip: 'Zoom in',
          onPressed: onZoomIn,
          icon: const Icon(Icons.zoom_in),
        ),
        TextButton(onPressed: onImport, child: const Text('Import')),
        TextButton(onPressed: onExport, child: const Text('Copy JSON')),
        if (onBuildRelease != null)
          FilledButton.tonal(
            onPressed: onBuildRelease,
            child: const Text('Build release'),
          ),
        if (onSaveChunks != null)
          TextButton(onPressed: onSaveChunks, child: const Text('Save chunks')),
        TextButton(onPressed: onReset, child: const Text('Reset')),
      ],
    ),
  );
}

class _Palette extends StatefulWidget {
  const _Palette({required this.controller});

  final EditorController controller;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final TextEditingController _search = TextEditingController();

  EditorController get controller => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final materials = controller.catalog.materials
        .where(
          (material) =>
              query.isEmpty ||
              material.name.toLowerCase().contains(query) ||
              material.tags.any((tag) => tag.toLowerCase().contains(query)),
        )
        .toList();
    final objects = controller.catalog.objects
        .where(
          (object) =>
              query.isEmpty ||
              object.name.toLowerCase().contains(query) ||
              object.category.toLowerCase().contains(query) ||
              object.tags.any((tag) => tag.toLowerCase().contains(query)),
        )
        .toList();

    return SizedBox(
      width: 300,
      child: DefaultTabController(
        length: 2,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Search assets',
                    prefixIcon: Icon(Icons.search, size: 19),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'GROUND'),
                  Tab(text: 'OBJECTS'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: Row(
                            children: [
                              Text(
                                'Brush ${controller.brushRadius.toStringAsFixed(1)}',
                              ),
                              Expanded(
                                child: Slider(
                                  value: controller.brushRadius,
                                  min: 0.5,
                                  max: 5,
                                  divisions: 18,
                                  onChanged: controller.setBrushRadius,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _AssetGrid(
                            itemCount: materials.length,
                            itemBuilder: (index) {
                              final material = materials[index];
                              return _AssetCard(
                                name: material.name,
                                thumbnailPath: material.thumbnailPath,
                                fallbackIcon: Icons.brush_outlined,
                                selected:
                                    controller.mode ==
                                        EnvironmentEditorMode.paint &&
                                    controller.selectedMaterialId ==
                                        material.id,
                                onTap: () =>
                                    controller.selectPaintMaterial(material),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    _AssetGrid(
                      itemCount: objects.length,
                      itemBuilder: (index) {
                        final object = objects[index];
                        return _AssetCard(
                          name: object.name,
                          subtitle: object.category,
                          thumbnailPath: object.thumbnailPath,
                          fallbackIcon: switch (object.category) {
                            'Trees' => Icons.park_outlined,
                            'Ground cover' => Icons.grass,
                            'Structures' => Icons.fence_outlined,
                            'Buildings' => Icons.cottage_outlined,
                            _ => Icons.nature_outlined,
                          },
                          selected:
                              controller.mode == EnvironmentEditorMode.place &&
                              controller.selectedObjectAssetId == object.id,
                          onTap: () => controller.selectObjectAsset(object),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: _PaletteButton(
                        label: 'Select',
                        icon: Icons.open_with,
                        selected:
                            controller.mode == EnvironmentEditorMode.select,
                        onTap: () =>
                            controller.selectMode(EnvironmentEditorMode.select),
                      ),
                    ),
                    Expanded(
                      child: _PaletteButton(
                        label: 'Collision',
                        icon: Icons.border_outer,
                        selected:
                            controller.mode == EnvironmentEditorMode.collision,
                        onTap: () => controller.selectMode(
                          EnvironmentEditorMode.collision,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _PaletteButton(
                        label: 'Erase',
                        icon: Icons.auto_fix_off,
                        selected:
                            controller.mode == EnvironmentEditorMode.erase,
                        onTap: () =>
                            controller.selectMode(EnvironmentEditorMode.erase),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetGrid extends StatelessWidget {
  const _AssetGrid({required this.itemCount, required this.itemBuilder});

  final int itemCount;
  final Widget Function(int index) itemBuilder;

  @override
  Widget build(BuildContext context) => GridView.builder(
    padding: const EdgeInsets.all(10),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 0.9,
    ),
    itemCount: itemCount,
    itemBuilder: (context, index) => itemBuilder(index),
  );
}

class _AssetCard extends StatelessWidget {
  const _AssetCard({
    required this.name,
    required this.thumbnailPath,
    required this.fallbackIcon,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final String name;
  final String? subtitle;
  final String? thumbnailPath;
  final IconData fallbackIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: subtitle == null ? name : '$name · $subtitle',
      child: Material(
        color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _AssetThumbnail(path: thumbnailPath, icon: fallbackIcon),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 5, 8, 7),
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetThumbnail extends StatelessWidget {
  const _AssetThumbnail({required this.path, required this.icon});

  final String? path;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    if (path == null || !path.startsWith('environment_generated/')) {
      return Icon(icon, size: 44, color: Theme.of(context).colorScheme.outline);
    }
    try {
      return Padding(
        padding: const EdgeInsets.all(5),
        child: Image.file(
          generatedEnvironmentFile(path),
          fit: BoxFit.contain,
          cacheWidth: 160,
          cacheHeight: 160,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, _, _) => Icon(icon, size: 44),
        ),
      );
    } on FileSystemException {
      return Icon(icon, size: 44, color: Theme.of(context).colorScheme.error);
    }
  }
}

class _EditorDiagnosticsHud extends StatefulWidget {
  const _EditorDiagnosticsHud({
    required this.game,
    required this.controller,
    required this.session,
  });

  final EditorGame game;
  final EditorController controller;
  final EditorChunkSession? session;

  @override
  State<_EditorDiagnosticsHud> createState() => _EditorDiagnosticsHudState();
}

class _EditorDiagnosticsHudState extends State<_EditorDiagnosticsHud> {
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
    if (!widget.game.showDiagnostics) return const SizedBox.shrink();
    PlacedEnvironmentObject? hovered;
    final hoveredId = widget.controller.hoveredObjectId;
    for (final object in widget.controller.document.objects) {
      if (object.id == hoveredId) {
        hovered = object;
        break;
      }
    }
    final asset = hovered == null
        ? null
        : widget.controller.catalog.objectById(hovered.assetId);
    EditorLayer? layer;
    if (hovered != null) {
      for (final candidate in widget.controller.document.editorLayers) {
        if (candidate.id == hovered.editorLayerId) {
          layer = candidate;
          break;
        }
      }
    }
    final session = widget.session;
    final streamer = session?.streamer;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xD917211C),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x557BD6A0)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            'F1 HUD · F2 depth · F3 geometry · F4 chunks · F5 navigation · P pause\n'
            'hover ${hovered?.id ?? '-'}  selected ${widget.controller.selectedObjectIds.length}  '
            'layer ${layer?.name ?? '-'}\n'
            'band ${asset?.renderBand.name ?? '-'}  '
            'depth ${asset == null || hovered == null ? '-' : asset.depthAt(hovered.x, hovered.y, instanceSortBias: hovered.sortBias).toStringAsFixed(2)}\n'
            'loaded ${session?.loadedCoordinates.length ?? '-'}  '
            'preload ${streamer?.preloadingChunks.length ?? '-'}  '
            'unload ${streamer?.pendingUnloadChunks.length ?? '-'}  '
            'cancel ${streamer?.cancelledRequestCount ?? '-'}\n'
            'decoded ${widget.game.decodedImageCount}  '
            '${(widget.game.decodedImageBytes / (1 << 20)).toStringAsFixed(1)} MiB  '
            'pending ${widget.game.pendingImageCount}  '
            'terrain cache ${widget.game.terrainPictureCount}\n'
            '${widget.game.diagnosticsFps.toStringAsFixed(1)} fps  '
            '${widget.game.diagnosticsFrameMilliseconds.toStringAsFixed(1)} ms frame  '
            '${widget.game.updateTime} ms update  ${widget.game.renderTime} ms render',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

class _PaletteButton extends StatelessWidget {
  const _PaletteButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Material(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Inspector extends StatefulWidget {
  const _Inspector({required this.controller});

  final EditorController controller;

  @override
  State<_Inspector> createState() => _InspectorState();
}

class _InspectorState extends State<_Inspector> {
  final Set<String> _collapsedLayerIds = {};
  EditorController get controller => widget.controller;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 260,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final object = controller.selectedObject;
        final asset = object == null
            ? null
            : controller.catalog.objectById(object.assetId);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'ENVIRONMENT',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(controller.document.name),
            Text(
              '${controller.document.width} × ${controller.document.height} world units',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(
              '${controller.document.terrainStrokes.length} terrain strokes',
            ),
            Text('${controller.document.objects.length} placed objects'),
            const Divider(height: 32),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'LAYERS',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Add child layer',
                  onPressed: controller.addLayer,
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
              ],
            ),
            for (final layer in _orderedLayers(
              controller.document,
              _collapsedLayerIds,
            ))
              _EditorLayerRow(
                controller: controller,
                layer: layer,
                depth: _layerDepth(controller.document, layer),
                hasChildren: controller.document.editorLayers.any(
                  (candidate) => candidate.parentId == layer.id,
                ),
                collapsed: _collapsedLayerIds.contains(layer.id),
                onToggleCollapsed: () => setState(() {
                  if (!_collapsedLayerIds.add(layer.id)) {
                    _collapsedLayerIds.remove(layer.id);
                  }
                }),
              ),
            const Divider(height: 32),
            if (object == null) ...[
              const Text('No object selected'),
              const SizedBox(height: 8),
              const Text('Choose Select, click an object, or drag a marquee.'),
            ] else ...[
              Text(
                controller.selectedObjects.length == 1
                    ? asset?.name ?? object.assetId
                    : '${controller.selectedObjects.length} objects selected',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text('x ${object.x.toStringAsFixed(2)}'),
              Text('y ${object.y.toStringAsFixed(2)}'),
              Text('view ${object.direction.name}'),
              Text('render band ${asset?.renderBand.name ?? 'unknown'}'),
              if (controller.mode == EnvironmentEditorMode.collision) ...[
                const SizedBox(height: 10),
                _GeometryEditor(controller: controller),
              ],
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: object.editorLayerId,
                decoration: const InputDecoration(
                  labelText: 'Move selection to layer',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final layer in controller.document.editorLayers)
                    DropdownMenuItem(value: layer.id, child: Text(layer.name)),
                ],
                onChanged: (id) {
                  if (id != null) controller.moveSelectionToLayer(id);
                },
              ),
              if (controller.selectedObjects.length > 1) ...[
                const SizedBox(height: 12),
                for (final layer in controller.document.editorLayers)
                  if (controller.selectedObjects.any(
                    (selected) => selected.editorLayerId == layer.id,
                  )) ...[
                    Text(
                      layer.name,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    for (final selected in controller.selectedObjects.where(
                      (selected) => selected.editorLayerId == layer.id,
                    ))
                      Padding(
                        padding: const EdgeInsets.only(left: 8, top: 2),
                        child: Text(
                          controller.catalog
                                  .objectById(selected.assetId)
                                  ?.name ??
                              selected.assetId,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
              ],
              const SizedBox(height: 12),
              _NumberStepper(
                label: 'Vertical offset',
                value: object.verticalOffset,
                step: 0.25,
                onDecrease: () =>
                    controller.adjustSelectedVerticalOffset(-0.25),
                onIncrease: () => controller.adjustSelectedVerticalOffset(0.25),
              ),
              const SizedBox(height: 8),
              _NumberStepper(
                label: 'Sort bias',
                value: object.sortBias,
                step: 0.1,
                warning: object.sortBias != 0,
                onDecrease: () => controller.adjustSelectedSortBias(-0.1),
                onIncrease: () => controller.adjustSelectedSortBias(0.1),
              ),
              if (object.sortBias != 0) ...[
                const SizedBox(height: 4),
                Text(
                  'Manual ordering correction',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (controller.overlapCandidateIds.length > 1) ...[
                const SizedBox(height: 10),
                Text(
                  '${controller.overlapCandidateIds.length} overlapping objects',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final id in controller.overlapCandidateIds)
                  TextButton(
                    onPressed: () => controller.selectCandidates([id]),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        controller.catalog
                                .objectById(
                                  controller.document.objects
                                      .firstWhere((object) => object.id == id)
                                      .assetId,
                                )
                                ?.name ??
                            id,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: controller.rotateSelected,
                icon: const Icon(Icons.rotate_right),
                label: const Text('Rotate 45°'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: controller.deleteSelected,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ],
          ],
        );
      },
    ),
  );

  static int _layerDepth(EnvironmentDocument document, EditorLayer layer) {
    var depth = 0;
    var parentId = layer.parentId;
    final visited = <String>{layer.id};
    while (parentId != null && visited.add(parentId)) {
      depth++;
      parentId = document.editorLayerById(parentId)?.parentId;
    }
    return depth;
  }

  static List<EditorLayer> _orderedLayers(
    EnvironmentDocument document,
    Set<String> collapsed,
  ) {
    final result = <EditorLayer>[];
    final visited = <String>{};
    void appendChildren(String? parentId) {
      for (final layer in document.editorLayers.where(
        (candidate) => candidate.parentId == parentId,
      )) {
        if (!visited.add(layer.id)) continue;
        result.add(layer);
        if (!collapsed.contains(layer.id)) appendChildren(layer.id);
      }
    }

    appendChildren(null);
    for (final layer in document.editorLayers) {
      if (visited.add(layer.id)) result.add(layer);
    }
    return result;
  }
}

class _EditorLayerRow extends StatelessWidget {
  const _EditorLayerRow({
    required this.controller,
    required this.layer,
    required this.depth,
    required this.hasChildren,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final EditorController controller;
  final EditorLayer layer;
  final int depth;
  final bool hasChildren;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final active = controller.document.activeLayerId == layer.id;
    final row = Material(
      color: active
          ? Theme.of(context).colorScheme.primaryContainer
                .withValues(alpha: 0.4)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => controller.setActiveLayer(layer.id),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: EdgeInsets.only(left: 4 + depth * 14, top: 2, bottom: 2),
          child: Row(
            children: [
              if (layer.id != EnvironmentDocument.rootLayerId) ...[
                const Icon(Icons.drag_indicator, size: 14),
                const SizedBox(width: 2),
              ],
              if (hasChildren)
                InkWell(
                  onTap: onToggleCollapsed,
                  child: Icon(
                    collapsed ? Icons.chevron_right : Icons.keyboard_arrow_down,
                    size: 16,
                  ),
                )
              else
                const SizedBox(width: 16),
              Icon(depth == 0 ? Icons.public : Icons.folder_outlined, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  layer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!layer.exported)
                const Tooltip(
                  message: 'Excluded from release export',
                  child: Icon(Icons.block, size: 16),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: layer.visible ? 'Hide layer' : 'Show layer',
                onPressed: () => controller.toggleLayerVisibility(layer.id),
                iconSize: 17,
                icon: Icon(
                  layer.visible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: layer.locked ? 'Unlock layer' : 'Lock layer',
                onPressed: () => controller.toggleLayerLocked(layer.id),
                iconSize: 17,
                icon: Icon(
                  layer.locked ? Icons.lock_outline : Icons.lock_open_outlined,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Layer actions',
                iconSize: 17,
                onSelected: (action) {
                  if (action == 'rename') {
                    _rename(context);
                  } else if (action == 'toggle_export') {
                    controller.toggleLayerExported(layer.id);
                  } else if (action == 'delete' &&
                      !controller.deleteLayer(layer.id)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Move contents and child layers before deleting this layer.',
                        ),
                      ),
                    );
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  if (layer.id != EnvironmentDocument.rootLayerId)
                    PopupMenuItem(
                      value: 'toggle_export',
                      child: Text(
                        layer.exported
                            ? 'Exclude from release'
                            : 'Include in release',
                      ),
                    ),
                  if (layer.id != EnvironmentDocument.rootLayerId)
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    final target = DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          controller.canReparentLayer(details.data, layer.id),
      onAcceptWithDetails: (details) =>
          controller.reparentLayer(details.data, layer.id),
      builder: (context, candidates, rejected) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: candidates.isEmpty
              ? null
              : Border.all(color: Theme.of(context).colorScheme.primary),
        ),
        child: row,
      ),
    );
    if (layer.id == EnvironmentDocument.rootLayerId) return target;
    return LongPressDraggable<String>(
      data: layer.id,
      feedback: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(layer.name),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: target),
      child: target,
    );
  }

  Future<void> _rename(BuildContext context) async {
    final field = TextEditingController(text: layer.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename layer'),
        content: TextField(controller: field, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    field.dispose();
    if (name != null) controller.renameLayer(layer.id, name);
  }
}

class _GeometryEditor extends StatelessWidget {
  const _GeometryEditor({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final object = controller.selectedObject!;
    final asset = controller.catalog.objectById(object.assetId)!;
    final geometry = controller.catalog.geometryForAsset(asset);
    final shapes = switch (controller.geometryRole) {
      GeometryRole.footprint => [
        if (geometry.footprint != null) geometry.footprint!,
      ],
      GeometryRole.blocking => geometry.blocking,
      GeometryRole.walkable => geometry.walkable,
      GeometryRole.selection => geometry.selection,
    };
    final shape = controller.selectedGeometryShape;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ASSET GEOMETRY', style: Theme.of(context).textTheme.labelMedium),
        Text('profile ${asset.collisionProfile ?? 'none'}'),
        Text(
          'Purple cross pivot · yellow ring sort anchor\n'
          'Blue footprint · red blocker · green walkable · purple selection',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<EnvironmentDirection>(
          isExpanded: true,
          initialValue: object.direction,
          decoration: const InputDecoration(
            labelText: 'Direction preview',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final direction in EnvironmentDirection.values)
              if (asset.views.containsKey(direction.name))
                DropdownMenuItem(value: direction, child: Text(direction.name)),
          ],
          onChanged: (direction) {
            if (direction != null) controller.setSelectedDirection(direction);
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<GeometryRole>(
          isExpanded: true,
          initialValue: controller.geometryRole,
          decoration: const InputDecoration(
            labelText: 'Geometry role',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: GeometryRole.footprint,
              child: Text('Footprint'),
            ),
            DropdownMenuItem(
              value: GeometryRole.blocking,
              child: Text('Blocking'),
            ),
            DropdownMenuItem(
              value: GeometryRole.walkable,
              child: Text('Walkable'),
            ),
            DropdownMenuItem(
              value: GeometryRole.selection,
              child: Text('Selection'),
            ),
          ],
          onChanged: (role) {
            if (role != null) controller.selectGeometryRole(role);
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (controller.geometryRole != GeometryRole.footprint &&
                shapes.isNotEmpty)
              Expanded(
                child: DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: controller.geometryShapeIndex.clamp(
                    0,
                    shapes.length - 1,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Shape',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (var index = 0; index < shapes.length; index++)
                      DropdownMenuItem(
                        value: index,
                        child: Text(
                          '${index + 1}: ${_shapeName(shapes[index])}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (index) {
                    if (index != null) {
                      controller.selectGeometryShapeIndex(index);
                    }
                  },
                ),
              ),
            if (controller.geometryRole != GeometryRole.footprint &&
                shapes.isNotEmpty)
              const SizedBox(width: 6),
            PopupMenuButton<GeometryShapeType>(
              tooltip: 'Add geometry shape',
              onSelected: controller.addGeometryShape,
              itemBuilder: (context) => [
                for (final type in GeometryShapeType.values)
                  PopupMenuItem(value: type, child: Text(type.name)),
              ],
              icon: const Icon(Icons.add_box_outlined),
            ),
            if (shape != null)
              IconButton(
                tooltip: 'Delete shape',
                onPressed: controller.deleteSelectedGeometryShape,
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
        if (shape == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No shape for this role. Add one to begin.'),
          )
        else ...[
          const SizedBox(height: 6),
          ..._shapeControls(shape),
        ],
        const SizedBox(height: 8),
        if (!geometry.reviewed)
          Text(
            'Unreviewed geometry',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            FilledButton.tonal(
              onPressed: controller.markSelectedGeometryReviewed,
              child: const Text('Mark reviewed'),
            ),
            OutlinedButton(
              onPressed:
                  controller.catalog.geometryOverrides.containsKey(asset.id)
                  ? controller.resetSelectedGeometryOverride
                  : null,
              child: const Text('Reset'),
            ),
            FilledButton(
              onPressed: () async {
                await controller.saveGeometryOverrides();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Geometry catalog saved.')),
                );
              },
              child: const Text('Save catalog'),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _shapeControls(EnvironmentGeometryShape shape) {
    if (shape is EnvironmentCircle) {
      return [
        _control('Center X', shape.center.x, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentCircle(
              center: EnvironmentGeometryPoint(value, shape.center.y),
              radius: shape.radius,
            ),
          );
        }),
        _control('Center Y', shape.center.y, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentCircle(
              center: EnvironmentGeometryPoint(shape.center.x, value),
              radius: shape.radius,
            ),
          );
        }),
        _control('Radius', shape.radius, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentCircle(
              center: shape.center,
              radius: value.clamp(0.02, 20),
            ),
          );
        }),
      ];
    }
    if (shape is EnvironmentEllipse) {
      return [
        _control('Center X', shape.center.x, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentEllipse(
              center: EnvironmentGeometryPoint(value, shape.center.y),
              radius: shape.radius,
            ),
          );
        }),
        _control('Center Y', shape.center.y, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentEllipse(
              center: EnvironmentGeometryPoint(shape.center.x, value),
              radius: shape.radius,
            ),
          );
        }),
        _control('Radius X', shape.radius.x, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentEllipse(
              center: shape.center,
              radius: EnvironmentGeometryPoint(
                value.clamp(0.02, 20),
                shape.radius.y,
              ),
            ),
          );
        }),
        _control('Radius Y', shape.radius.y, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentEllipse(
              center: shape.center,
              radius: EnvironmentGeometryPoint(
                shape.radius.x,
                value.clamp(0.02, 20),
              ),
            ),
          );
        }),
      ];
    }
    if (shape is EnvironmentRectangle) {
      return [
        _control('Center X', shape.center.x, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentRectangle(
              center: EnvironmentGeometryPoint(value, shape.center.y),
              size: shape.size,
              rotationDegrees: shape.rotationDegrees,
            ),
          );
        }),
        _control('Center Y', shape.center.y, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentRectangle(
              center: EnvironmentGeometryPoint(shape.center.x, value),
              size: shape.size,
              rotationDegrees: shape.rotationDegrees,
            ),
          );
        }),
        _control('Width', shape.size.x, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentRectangle(
              center: shape.center,
              size: EnvironmentGeometryPoint(
                value.clamp(0.02, 40),
                shape.size.y,
              ),
              rotationDegrees: shape.rotationDegrees,
            ),
          );
        }),
        _control('Height', shape.size.y, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentRectangle(
              center: shape.center,
              size: EnvironmentGeometryPoint(
                shape.size.x,
                value.clamp(0.02, 40),
              ),
              rotationDegrees: shape.rotationDegrees,
            ),
          );
        }),
        _control('Rotation', shape.rotationDegrees, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentRectangle(
              center: shape.center,
              size: shape.size,
              rotationDegrees: value,
            ),
          );
        }, step: 5),
      ];
    }
    if (shape is EnvironmentCapsule) {
      return [
        _control('Start X', shape.start.x, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentCapsule(
              start: EnvironmentGeometryPoint(value, shape.start.y),
              end: shape.end,
              radius: shape.radius,
            ),
          );
        }),
        _control('Start Y', shape.start.y, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentCapsule(
              start: EnvironmentGeometryPoint(shape.start.x, value),
              end: shape.end,
              radius: shape.radius,
            ),
          );
        }),
        _control('End X', shape.end.x, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentCapsule(
              start: shape.start,
              end: EnvironmentGeometryPoint(value, shape.end.y),
              radius: shape.radius,
            ),
          );
        }),
        _control('End Y', shape.end.y, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentCapsule(
              start: shape.start,
              end: EnvironmentGeometryPoint(shape.end.x, value),
              radius: shape.radius,
            ),
          );
        }),
        _control('Radius', shape.radius, (value) {
          controller.replaceSelectedGeometryShape(
            EnvironmentCapsule(
              start: shape.start,
              end: shape.end,
              radius: value.clamp(0.02, 20),
            ),
          );
        }),
      ];
    }
    final polygon = shape as EnvironmentPolygon;
    return [
      for (var index = 0; index < polygon.points.length; index++) ...[
        Text('Vertex ${index + 1}'),
        _control('X', polygon.points[index].x, (value) {
          final points = [...polygon.points];
          points[index] = EnvironmentGeometryPoint(value, points[index].y);
          controller.replaceSelectedGeometryShape(
            EnvironmentPolygon(points: points),
          );
        }),
        _control('Y', polygon.points[index].y, (value) {
          final points = [...polygon.points];
          points[index] = EnvironmentGeometryPoint(points[index].x, value);
          controller.replaceSelectedGeometryShape(
            EnvironmentPolygon(points: points),
          );
        }),
      ],
    ];
  }

  Widget _control(
    String label,
    double value,
    ValueChanged<double> onChanged, {
    double step = 0.05,
  }) => _NumberStepper(
    label: label,
    value: value,
    step: step,
    onDecrease: () => onChanged(value - step),
    onIncrease: () => onChanged(value + step),
  );

  static String _shapeName(EnvironmentGeometryShape shape) => switch (shape) {
    EnvironmentCircle() => 'Circle',
    EnvironmentEllipse() => 'Ellipse',
    EnvironmentRectangle() => 'Rectangle',
    EnvironmentCapsule() => 'Capsule',
    EnvironmentPolygon() => 'Polygon',
  };
}

class _NumberStepper extends StatelessWidget {
  const _NumberStepper({
    required this.label,
    required this.value,
    required this.step,
    required this.onDecrease,
    required this.onIncrease,
    this.warning = false,
  });

  final String label;
  final double value;
  final double step;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final bool warning;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(
              value.toStringAsFixed(step < 0.2 ? 2 : 2),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: warning ? Theme.of(context).colorScheme.error : null,
              ),
            ),
          ],
        ),
      ),
      IconButton(
        tooltip: 'Decrease by $step',
        onPressed: onDecrease,
        icon: const Icon(Icons.remove),
      ),
      IconButton(
        tooltip: 'Increase by $step',
        onPressed: onIncrease,
        icon: const Icon(Icons.add),
      ),
    ],
  );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    ),
  );
}
