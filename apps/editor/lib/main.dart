import 'dart:async';
import 'dart:io';

import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  Widget build(BuildContext context) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF83B795),
      brightness: Brightness.dark,
      surface: const Color(0xFF151A17),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Neura Environment Designer',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: colors,
        scaffoldBackgroundColor: colors.surface,
        dividerTheme: DividerThemeData(color: colors.outlineVariant),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          isDense: true,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: colors.inverseSurface,
          contentTextStyle: TextStyle(color: colors.onInverseSurface),
        ),
        tooltipTheme: const TooltipThemeData(waitDuration: Duration.zero),
        iconButtonTheme: const IconButtonThemeData(
          style: ButtonStyle(visualDensity: VisualDensity.compact),
        ),
      ),
      home: EditorBootstrap(debugSceneName: debugSceneName),
    );
  }
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
  final FocusNode _editorFocusNode = FocusNode(debugLabel: 'editor');
  final _EditorFrameTimings _frameTimings = _EditorFrameTimings();
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
    playerSpawn: widget.chunkSession == null
        ? null
        : () => widget.chunkSession!.playerSpawn,
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
  EnvironmentGeometryHandle? _movingGeometryHandle;
  int? _movingTerrainPoint;
  int? _movingLiquidDepthHandle;
  Offset? _gestureScreenStart;
  WorldPoint? _lastGestureWorld;
  Duration? _lastPanEventTime;
  Timer? _scrollPanEndTimer;
  Timer? _chunkStreamTimer;
  Offset? _pendingHoverPosition;
  bool _hoverFrameScheduled = false;
  bool _showAssetPalette = false;
  Future<void>? _pendingClipboardWrite;
  String? _localObjectClipboard;

  @override
  void initState() {
    super.initState();
    _frameTimings.start();
    controller
      ..addListener(_requestGameFrame)
      ..hoverListenable.addListener(_requestGameFrame);
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
    _editorFocusNode.dispose();
    _frameTimings.dispose();
    controller
      ..removeListener(_requestGameFrame)
      ..hoverListenable.removeListener(_requestGameFrame);
    if (widget.controllerOverride == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _editorFocusNode,
    autofocus: true,
    onKeyEvent: _handleEditorKeyEvent,
    child: Scaffold(
      body: Column(
        children: [
          _Toolbar(
            controller: controller,
            onZoomIn: () => _zoomBy(1.2),
            onZoomOut: () => _zoomBy(1 / 1.2),
            onExport: _showExport,
            onBuildRelease: widget.chunkSession == null ? null : _buildRelease,
            onImport: _showImport,
            assetPaletteVisible: _showAssetPalette,
            onToggleAssetPalette: () =>
                setState(() => _showAssetPalette = !_showAssetPalette),
            onManageWorld: widget.chunkSession == null ? null : _showWorldTools,
            onSaveChunks: widget.chunkSession == null ? null : _saveChunks,
            onReset: () => controller.replaceDocument(
              EnvironmentDocument.fromJson(_starter.toJson()),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                if (_showAssetPalette) ...[
                  _Palette(controller: controller),
                  const VerticalDivider(width: 1),
                ],
                Expanded(child: ClipRect(child: _canvas())),
                const VerticalDivider(width: 1),
                _Inspector(controller: controller),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  KeyEventResult _handleEditorKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _isEditingText) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final command = keyboard.isMetaPressed || keyboard.isControlPressed;
    if (command && key == LogicalKeyboardKey.keyZ) {
      keyboard.isShiftPressed ? controller.redo() : controller.undo();
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyC) {
      final operation = _copySelection();
      _pendingClipboardWrite = operation;
      unawaited(operation);
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyP) {
      unawaited(_pasteSelection(preferLocal: true));
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyV) {
      unawaited(_pasteSelection());
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed && key == LogicalKeyboardKey.keyY) {
      controller.redo();
      return KeyEventResult.handled;
    }
    if (!command &&
        {
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
        }.contains(key)) {
      final amount = keyboard.isShiftPressed ? 1.0 : 0.25;
      final (dx, dy) = switch (key) {
        LogicalKeyboardKey.arrowLeft => (-amount, amount),
        LogicalKeyboardKey.arrowRight => (amount, -amount),
        LogicalKeyboardKey.arrowUp => (-amount, -amount),
        _ => (amount, amount),
      };
      controller.nudgeSelection(dx, dy);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      controller.deleteSelected();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (controller.hasSurfacePolygonDraft) {
        controller.cancelSurfacePolygon();
      } else if (controller.connectorStart != null) {
        controller.cancelConnectorDraft();
      } else if (controller.hasPathDraft) {
        controller.cancelPathDraft();
      } else {
        controller.clearSelection();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter &&
        controller.mode == EnvironmentEditorMode.surfacePolygon) {
      controller.finishSurfacePolygon();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f1) {
      setState(() => game.showDiagnostics = !game.showDiagnostics);
    } else if (key == LogicalKeyboardKey.f2) {
      setState(() => game.showRenderDebug = !game.showRenderDebug);
    } else if (key == LogicalKeyboardKey.f3) {
      setState(() => game.showGeometryDebug = !game.showGeometryDebug);
    } else if (key == LogicalKeyboardKey.f4) {
      setState(() => game.showChunkDebug = !game.showChunkDebug);
    } else if (key == LogicalKeyboardKey.f5) {
      setState(() => game.showNavigationDebug = !game.showNavigationDebug);
    } else if (key == LogicalKeyboardKey.f6) {
      setState(game.toggleExperimentalLighting);
    } else if (key == LogicalKeyboardKey.f7) {
      setState(game.cycleExperimentalLightingVisualization);
    } else if (key == LogicalKeyboardKey.bracketLeft) {
      setState(() => game.rotateExperimentalLight(-15));
    } else if (key == LogicalKeyboardKey.bracketRight) {
      setState(() => game.rotateExperimentalLight(15));
    } else if (key == LogicalKeyboardKey.minus) {
      setState(() => game.adjustExperimentalLightIntensity(-0.25));
    } else if (key == LogicalKeyboardKey.equal) {
      setState(() => game.adjustExperimentalLightIntensity(0.25));
    } else if (key == LogicalKeyboardKey.keyP) {
      setState(game.togglePause);
    } else if (key == LogicalKeyboardKey.period) {
      game.stepDebug();
    } else {
      return KeyEventResult.ignored;
    }
    game.requestFrame(frames: 3);
    return KeyEventResult.handled;
  }

  void _requestGameFrame() => game.requestFrame();

  Future<void> _copySelection() async {
    final source = controller.copySelectionToJson();
    if (source == null) return;
    _localObjectClipboard = source;
    await Clipboard.setData(ClipboardData(text: source));
  }

  Future<void> _pasteSelection({bool preferLocal = false}) async {
    String? systemSource;
    if (!preferLocal || _localObjectClipboard == null) {
      await _pendingClipboardWrite;
      systemSource = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    }
    final candidates = preferLocal
        ? [_localObjectClipboard, systemSource]
        : [systemSource, _localObjectClipboard];
    if (!candidates.whereType<String>().any(
      controller.pasteSelectionFromJson,
    )) {
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 900),
        content: Text(
          '${controller.selectedObjectIds.length} object'
          '${controller.selectedObjectIds.length == 1 ? '' : 's'} pasted',
        ),
      ),
    );
  }

  bool get _isEditingText {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  Widget _canvas() => MouseRegion(
    onExit: (_) {
      _pendingHoverPosition = null;
      controller
        ..hover(null)
        ..hoverObjects(const []);
      game.requestFrame();
    },
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerHover: (event) => _scheduleHoverAt(event.localPosition),
      onPointerDown: (event) {
        if (event.buttons & kPrimaryButton == 0) return;
        _editorFocusNode.requestFocus();
        _gesturing = true;
        _gestureScreenStart = event.localPosition;
        _lastGestureWorld = _worldAt(event.localPosition);
        controller.beginGesture();
        if (controller.mode == EnvironmentEditorMode.editGround) {
          final liquidDepthHandle = game.hitTestSelectedLiquidDepthHandle(
            Vector2(event.localPosition.dx, event.localPosition.dy),
          );
          if (liquidDepthHandle != null &&
              controller.beginSelectedLiquidDepthHandleGesture(
                liquidDepthHandle,
              )) {
            _movingLiquidDepthHandle = liquidDepthHandle;
            _movingTerrainPoint = null;
            _movingSelection = false;
            _marqueeSelecting = false;
            return;
          }
          final pointIndex = game.hitTestSelectedTerrainPoint(
            Vector2(event.localPosition.dx, event.localPosition.dy),
          );
          if (pointIndex != null &&
              controller.beginSelectedTerrainPointGesture(pointIndex)) {
            _movingTerrainPoint = pointIndex;
            _movingSelection = false;
            _marqueeSelecting = false;
            return;
          }
        }
        if (controller.mode == EnvironmentEditorMode.collision) {
          final handle = game.hitTestSelectedGeometryHandle(
            Vector2(event.localPosition.dx, event.localPosition.dy),
          );
          if (handle != null &&
              controller.beginSelectedGeometryHandleGesture(handle)) {
            _movingGeometryHandle = handle;
            _movingSelection = false;
            _marqueeSelecting = false;
            return;
          }
        }
        if (controller.isTerrainAreaMode) {
          _marqueeSelecting = true;
          game.setSelectionMarquee(
            Rect.fromPoints(event.localPosition, event.localPosition),
          );
        } else if (controller.isObjectSelectionMode) {
          final candidates = game.hitTestObjectIds(
            Vector2(event.localPosition.dx, event.localPosition.dy),
          );
          final keyboard = HardwareKeyboard.instance;
          final additive =
              keyboard.isShiftPressed ||
              keyboard.isMetaPressed ||
              keyboard.isControlPressed;
          final hitExistingSelection = candidates.any(
            controller.selectedObjectIds.contains,
          );
          if (additive || !hitExistingSelection) {
            controller.selectCandidates(candidates, additive: additive);
          }
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
        if (!_gesturing) {
          _scheduleHoverAt(event.localPosition);
          return;
        }
        controller.hover(_worldAt(event.localPosition));
        if (_marqueeSelecting) {
          game.setSelectionMarquee(
            Rect.fromPoints(_gestureScreenStart!, event.localPosition),
          );
          return;
        }
        final point = _worldAt(event.localPosition);
        if (point == null) return;
        final liquidDepthHandle = _movingLiquidDepthHandle;
        if (liquidDepthHandle != null) {
          controller.moveSelectedLiquidDepthHandleDuringGesture(
            liquidDepthHandle,
            point,
          );
          return;
        }
        final geometryHandle = _movingGeometryHandle;
        if (geometryHandle != null) {
          controller.moveSelectedGeometryHandleDuringGesture(
            geometryHandle,
            point,
          );
          return;
        }
        final terrainPoint = _movingTerrainPoint;
        if (terrainPoint != null) {
          controller.moveSelectedTerrainPointDuringGesture(terrainPoint, point);
          return;
        }
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
              frameTimings: _frameTimings,
            ),
          ),
          Positioned(
            right: 14,
            top: 14,
            child: _LightingExperimentPanel(
              game: game,
              onFocusAsset: () {
                if (game.focusExperimentalLightingAsset()) {
                  _scheduleChunkStreaming();
                }
              },
            ),
          ),
          Positioned(
            left: 14,
            bottom: 14,
            child: ListenableBuilder(
              listenable: controller.hoverListenable,
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
                  : '${widget.chunkSession!.loadedCoordinates.length} chunks loaded  •  ${widget.chunkSession!.dirtyCoordinates.length} dirty${widget.chunkSession!.manifestDirty ? '  •  world changed' : ''}',
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

  void _scheduleHoverAt(Offset position) {
    _pendingHoverPosition = position;
    if (_hoverFrameScheduled) return;
    _hoverFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _hoverFrameScheduled = false;
      final pending = _pendingHoverPosition;
      _pendingHoverPosition = null;
      if (mounted && pending != null) _hoverAt(pending);
    });
  }

  void _applyAt(Offset position) {
    final point = _worldAt(position);
    if (point == null) return;
    final session = widget.chunkSession;
    if (controller.mode == EnvironmentEditorMode.spawn && session != null) {
      session.setPlayerSpawn(point);
      game.requestFrame(frames: 3);
      _gesturing = false;
      controller.endGesture();
      controller.selectMode(EnvironmentEditorMode.select);
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Player spawn set to ${point.x.toStringAsFixed(1)}, ${point.y.toStringAsFixed(1)}.',
          ),
        ),
      );
      return;
    }
    controller.applyAt(point);
  }

  void _endGesture([Offset? position]) {
    if (!_gesturing) return;
    if (controller.mode == EnvironmentEditorMode.path && position != null) {
      final point = _worldAt(position);
      if (point != null) controller.applyAt(point);
    }
    if (_marqueeSelecting && position != null) {
      final rect = Rect.fromPoints(_gestureScreenStart!, position);
      if (controller.isTerrainAreaMode) {
        final polygon = game.worldPolygonForScreenRect(rect);
        switch (controller.mode) {
          case EnvironmentEditorMode.fillGround:
            controller.fillGroundInArea(polygon);
          case EnvironmentEditorMode.resetGround:
            controller.resetGroundInArea(polygon);
          case EnvironmentEditorMode.clearGroundFill:
            controller.clearGroundFillInArea(polygon);
          default:
            break;
        }
      } else {
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
    }
    _gesturing = false;
    _marqueeSelecting = false;
    _movingSelection = false;
    _movingGeometryHandle = null;
    _movingTerrainPoint = null;
    _movingLiquidDepthHandle = null;
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

  Future<void> _showWorldTools() async {
    final session = widget.chunkSession;
    if (session == null) return;
    final action = await showDialog<Object>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('World size and player spawn'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${session.manifest.width.toInt()} × ${session.manifest.height.toInt()} world units  •  '
                '${session.manifest.chunks.length} chunks',
              ),
              const SizedBox(height: 16),
              const Text('Extend one complete 32-unit edge'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.pop(context, EnvironmentWorldEdge.left),
                      child: const Text('Upper-left edge'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.pop(context, EnvironmentWorldEdge.top),
                      child: const Text('Upper-right edge'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.pop(context, EnvironmentWorldEdge.bottom),
                      child: const Text('Lower-left edge'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.pop(context, EnvironmentWorldEdge.right),
                      child: const Text('Lower-right edge'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.pop(context, 'spawn'),
                icon: const Icon(Icons.person_pin_circle_outlined),
                label: const Text('Place player spawn on canvas'),
              ),
              const SizedBox(height: 8),
              Text(
                'Current spawn: ${session.playerSpawn.x.toStringAsFixed(1)}, '
                '${session.playerSpawn.y.toStringAsFixed(1)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'spawn') {
      controller.selectMode(EnvironmentEditorMode.spawn);
      return;
    }
    if (action is! EnvironmentWorldEdge) return;
    final visibleBounds = game.visibleWorldBounds();
    final result = await session.extendWorld(
      controller.document,
      action,
      visibleBounds: visibleBounds,
    );
    if (!mounted) return;
    game.rebaseWorld(result.worldShift);
    controller.replaceDocumentFromStreaming(result.document);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'World extended to ${session.manifest.width.toInt()} × '
          '${session.manifest.height.toInt()}. Save chunks to persist it.',
        ),
      ),
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
    final duplicateIds = await session.findDuplicateObjectIds(
      controller.document,
    );
    if (!mounted) return;
    if (duplicateIds.isNotEmpty) {
      final repair = await _confirmDuplicateObjectIdRepair(
        session,
        duplicateIds,
      );
      if (!repair || !mounted) return;
      final repaired = await session.repairDuplicateObjectIds(
        controller.document,
      );
      controller.replaceDocumentFromStreaming(repaired.document);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Reassigned ${repaired.repairs.length} duplicate object ID${repaired.repairs.length == 1 ? '' : 's'}.',
          ),
        ),
      );
    }
    await controller.saveGeometryOverrides();
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
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Release export failed'),
          content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: SelectableText(result.stderr.toString().trim()),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
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

  Future<bool> _confirmDuplicateObjectIdRepair(
    EditorChunkSession session,
    List<DuplicateObjectIdIssue> issues,
  ) async {
    final repair = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Duplicate object IDs found'),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Each placed object needs one world-wide identity. These are '
                  'different objects that were accidentally given the same ID '
                  'by an older editor version:',
                ),
                const SizedBox(height: 16),
                for (final issue in issues) ...[
                  SelectableText(
                    issue.id,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  for (final occurrence in issue.occurrences)
                    SelectableText(
                      'Chunk ${occurrence.chunk.key} · '
                      '${session.catalog.objectById(occurrence.assetId)?.name ?? occurrence.assetId} · '
                      '(${occurrence.position.x.toStringAsFixed(2)}, '
                      '${occurrence.position.y.toStringAsFixed(2)})',
                    ),
                  const SizedBox(height: 12),
                ],
                const Text(
                  'Repair keeps the first identity, assigns new IDs to the '
                  'other objects, rebuilds chunk overlap references, saves the '
                  'affected chunks, and then continues the release build.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Repair and continue'),
          ),
        ],
      ),
    );
    return repair ?? false;
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
    required this.assetPaletteVisible,
    required this.onToggleAssetPalette,
    this.onManageWorld,
    required this.onReset,
    this.onSaveChunks,
  });

  final EditorController controller;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onExport;
  final VoidCallback? onBuildRelease;
  final VoidCallback onImport;
  final bool assetPaletteVisible;
  final VoidCallback onToggleAssetPalette;
  final VoidCallback? onManageWorld;
  final VoidCallback onReset;
  final VoidCallback? onSaveChunks;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(
              Icons.landscape_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
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
            IconButton.filledTonal(
              tooltip: assetPaletteVisible
                  ? 'Remove asset palette from widget tree'
                  : 'Add asset palette to widget tree',
              onPressed: onToggleAssetPalette,
              icon: Icon(
                Icons.photo_library_outlined,
                color: assetPaletteVisible
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
            ),
            TextButton(onPressed: onImport, child: const Text('Import')),
            if (onManageWorld != null)
              TextButton.icon(
                onPressed: onManageWorld,
                icon: const Icon(Icons.public, size: 18),
                label: const Text('World'),
              ),
            TextButton(onPressed: onExport, child: const Text('Copy JSON')),
            if (onBuildRelease != null)
              FilledButton.tonal(
                onPressed: onBuildRelease,
                child: const Text('Build release'),
              ),
            if (onSaveChunks != null)
              TextButton(
                onPressed: onSaveChunks,
                child: const Text('Save chunks'),
              ),
            TextButton(onPressed: onReset, child: const Text('Reset')),
          ],
        ),
      ),
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
  String _selectedObjectCategory = _allObjectCategories;
  String _selectedSourcePack = _allSourcePacks;
  late final _AssetPaletteIndex _index;

  EditorController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _index = _AssetPaletteIndex(controller.catalog);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final materials = _index.materialsMatching(
      query,
      sourcePack: _selectedSourcePack,
    );
    final categories = _index.categories;
    final objects = _index.objectsMatching(
      query,
      category: _selectedObjectCategory,
      sourcePack: _selectedSourcePack,
    );

    return SizedBox(
      width: 300,
      child: DefaultTabController(
        length: 2,
        child: ListenableBuilder(
          listenable: controller.paletteListenable,
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
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _selectedSourcePack,
                  decoration: const InputDecoration(
                    labelText: 'Asset pack',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: _allSourcePacks,
                      child: Text('All packs'),
                    ),
                    for (final pack in _index.sourcePacks)
                      DropdownMenuItem(value: pack.id, child: Text(pack.name)),
                  ],
                  onChanged: (pack) {
                    if (pack != null) {
                      setState(() => _selectedSourcePack = pack);
                    }
                  },
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
                        Flexible(
                          fit: FlexFit.loose,
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                              child: Column(
                                children: [
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    children: [
                                      ChoiceChip(
                                        label: const Text('Brush'),
                                        selected:
                                            controller.mode ==
                                            EnvironmentEditorMode.paint,
                                        onSelected: (_) =>
                                            controller.selectMode(
                                              EnvironmentEditorMode.paint,
                                            ),
                                      ),
                                      ChoiceChip(
                                        label: const Text('Fill area'),
                                        selected:
                                            controller.mode ==
                                            EnvironmentEditorMode.fillGround,
                                        onSelected: (_) =>
                                            controller.selectMode(
                                              EnvironmentEditorMode.fillGround,
                                            ),
                                      ),
                                      ChoiceChip(
                                        label: const Text('Surface'),
                                        selected:
                                            controller.mode ==
                                            EnvironmentEditorMode
                                                .surfacePolygon,
                                        onSelected: (_) =>
                                            controller.selectMode(
                                              EnvironmentEditorMode
                                                  .surfacePolygon,
                                            ),
                                      ),
                                      ChoiceChip(
                                        label: const Text('Reset'),
                                        selected:
                                            controller.mode ==
                                            EnvironmentEditorMode.resetGround,
                                        onSelected: (_) =>
                                            controller.selectMode(
                                              EnvironmentEditorMode.resetGround,
                                            ),
                                      ),
                                      ChoiceChip(
                                        label: const Text('Clear'),
                                        selected:
                                            controller.mode ==
                                            EnvironmentEditorMode
                                                .clearGroundFill,
                                        onSelected: (_) =>
                                            controller.selectMode(
                                              EnvironmentEditorMode
                                                  .clearGroundFill,
                                            ),
                                      ),
                                      ChoiceChip(
                                        label: const Text('Edit fill'),
                                        selected:
                                            controller.mode ==
                                            EnvironmentEditorMode.editGround,
                                        onSelected: (_) =>
                                            controller.selectMode(
                                              EnvironmentEditorMode.editGround,
                                            ),
                                      ),
                                      ChoiceChip(
                                        label: const Text('Link'),
                                        selected:
                                            controller.mode ==
                                            EnvironmentEditorMode.connector,
                                        onSelected: (_) =>
                                            controller.selectMode(
                                              EnvironmentEditorMode.connector,
                                            ),
                                      ),
                                    ],
                                  ),
                                  if (controller.mode ==
                                      EnvironmentEditorMode.paint) ...[
                                    _BrushSlider(
                                      label:
                                          'Size ${controller.brushRadius.toStringAsFixed(1)}',
                                      value: controller.brushRadius,
                                      min: 0.5,
                                      max: 5,
                                      divisions: 18,
                                      onChanged: controller.setBrushRadius,
                                    ),
                                    _BrushSlider(
                                      label:
                                          'Flow ${(controller.brushFlow * 100).round()}%',
                                      value: controller.brushFlow,
                                      min: 0.05,
                                      max: 0.6,
                                      divisions: 22,
                                      onChanged: controller.setBrushFlow,
                                    ),
                                    _BrushSlider(
                                      label:
                                          'Scatter ${(controller.brushScatter * 100).round()}%',
                                      value: controller.brushScatter,
                                      min: 0,
                                      max: 0.65,
                                      divisions: 13,
                                      onChanged: controller.setBrushScatter,
                                    ),
                                  ],
                                  if (controller.mode ==
                                      EnvironmentEditorMode.surfacePolygon) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      'Click polygon corners, then press Enter or Finish. Escape cancels.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        TextButton(
                                          onPressed:
                                              controller.hasSurfacePolygonDraft
                                              ? controller.cancelSurfacePolygon
                                              : null,
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed:
                                              controller
                                                      .surfacePolygonDraft
                                                      .length >=
                                                  3
                                              ? controller.finishSurfacePolygon
                                              : null,
                                          child: Text(
                                            'Finish (${controller.surfacePolygonDraft.length})',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  if (controller.mode ==
                                      EnvironmentEditorMode.connector) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      controller.connectorStart == null
                                          ? 'Click the landing on the active surface, then click the landing on the destination surface.'
                                          : 'First landing recorded. Click the destination landing or cancel.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                    const SizedBox(height: 6),
                                    DropdownButtonFormField<String>(
                                      initialValue:
                                          controller.connectorTargetSurface?.id,
                                      decoration: const InputDecoration(
                                        labelText: 'Destination surface',
                                        isDense: true,
                                      ),
                                      items: [
                                        for (final surface
                                            in controller.document.surfaces)
                                          if (surface.id !=
                                              controller
                                                  .document
                                                  .activeSurfaceId)
                                            DropdownMenuItem(
                                              value: surface.id,
                                              child: Text(surface.name),
                                            ),
                                      ],
                                      onChanged: (id) {
                                        if (id != null) {
                                          controller.setConnectorTargetSurface(
                                            id,
                                          );
                                        }
                                      },
                                    ),
                                    const SizedBox(height: 6),
                                    DropdownButtonFormField<
                                      EnvironmentSurfaceConnectorKind
                                    >(
                                      initialValue: controller.connectorKind,
                                      decoration: const InputDecoration(
                                        labelText: 'Traversal',
                                        isDense: true,
                                      ),
                                      items: [
                                        for (final kind
                                            in EnvironmentSurfaceConnectorKind
                                                .values)
                                          DropdownMenuItem(
                                            value: kind,
                                            child: Text(kind.name),
                                          ),
                                      ],
                                      onChanged: (kind) {
                                        if (kind != null) {
                                          controller.setConnectorKind(kind);
                                        }
                                      },
                                    ),
                                    _BrushSlider(
                                      label:
                                          'Landing width ${controller.connectorWidth.toStringAsFixed(2)}',
                                      value: controller.connectorWidth,
                                      min: 0.25,
                                      max: 4,
                                      divisions: 15,
                                      onChanged: controller.setConnectorWidth,
                                    ),
                                    SwitchListTile.adaptive(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text('Bidirectional'),
                                      value: controller.connectorBidirectional,
                                      onChanged:
                                          controller.setConnectorBidirectional,
                                    ),
                                    if (controller.connectorStart != null)
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton(
                                          onPressed:
                                              controller.cancelConnectorDraft,
                                          child: const Text(
                                            'Cancel first landing',
                                          ),
                                        ),
                                      ),
                                    if (controller
                                        .document
                                        .surfaceConnectors
                                        .isNotEmpty)
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '${controller.document.surfaceConnectors.length} authored ${controller.document.surfaceConnectors.length == 1 ? 'connector' : 'connectors'}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            tooltip: 'Delete a connector',
                                            icon: const Icon(
                                              Icons.link_off,
                                              size: 18,
                                            ),
                                            onSelected: controller
                                                .deleteSurfaceConnector,
                                            itemBuilder: (context) => [
                                              for (final connector
                                                  in controller
                                                      .document
                                                      .surfaceConnectors
                                                      .reversed)
                                                PopupMenuItem(
                                                  value: connector.id,
                                                  child: Text(
                                                    '${connector.kind.name}: ${controller.document.surfaceById(connector.fromSurfaceId)?.name ?? connector.fromSurfaceId} → ${controller.document.surfaceById(connector.toSurfaceId)?.name ?? connector.toSurfaceId}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                  ],
                                  const SizedBox(height: 4),
                                  DropdownButtonFormField<String>(
                                    initialValue:
                                        controller.document.activeSurfaceId,
                                    decoration: const InputDecoration(
                                      labelText: 'Target surface',
                                      isDense: true,
                                    ),
                                    items: [
                                      for (final surface
                                          in controller.document.surfaces)
                                        DropdownMenuItem(
                                          value: surface.id,
                                          child: Text(
                                            '${surface.name} · z ${surface.height.elevation.toStringAsFixed(2)}',
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                    ],
                                    onChanged: (id) {
                                      if (id != null) {
                                        controller.setActiveSurface(id);
                                      }
                                    },
                                  ),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'Default: ${controller.catalog.materialById(controller.activeSurface.materialId)?.name ?? controller.activeSurface.materialId}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      ),
                                      TextButton(
                                        onPressed:
                                            controller
                                                    .activeSurface
                                                    .materialId ==
                                                controller.selectedMaterialId
                                            ? null
                                            : () {
                                                final material = controller
                                                    .catalog
                                                    .materialById(
                                                      controller
                                                          .selectedMaterialId,
                                                    );
                                                if (material != null) {
                                                  controller
                                                      .setDefaultGroundMaterial(
                                                        material,
                                                      );
                                                }
                                              },
                                        child: const Text('Use selected'),
                                      ),
                                    ],
                                  ),
                                  if (controller.mode ==
                                          EnvironmentEditorMode.fillGround ||
                                      controller.mode ==
                                          EnvironmentEditorMode
                                              .surfacePolygon ||
                                      controller.mode ==
                                          EnvironmentEditorMode.editGround ||
                                      controller.hasSelectedEnvironmentArea)
                                    Builder(
                                      builder: (context) {
                                        final region =
                                            controller.selectedTerrainRegion;
                                        final liquid =
                                            controller.selectedLiquidVolume;
                                        final material = controller.catalog
                                            .materialById(
                                              liquid?.materialId ??
                                                  (region != null &&
                                                          !region
                                                              .resetsToDefault
                                                      ? region.materialId
                                                      : controller
                                                            .selectedMaterialId),
                                            );
                                        if (material == null) {
                                          return const SizedBox.shrink();
                                        }
                                        final scale =
                                            controller.activeFillTextureScale;
                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text(
                                              'Material repeat ${material.effectiveRepeatWorldWidth.toStringAsFixed(1)} × ${material.effectiveRepeatWorldHeight.toStringAsFixed(1)} world units',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                            if (region?.resetsToDefault ??
                                                false)
                                              Text(
                                                'This clear-fill region reveals the default ground and has no texture size.',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall,
                                              )
                                            else ...[
                                              _BrushSlider(
                                                label:
                                                    region == null &&
                                                        liquid == null
                                                    ? 'New size ${(scale * 100).round()}%'
                                                    : 'Fill size ${(scale * 100).round()}%',
                                                value: scale,
                                                min: 0.25,
                                                max: 4,
                                                divisions: 15,
                                                onChangeStart: (_) => controller
                                                    .beginTerrainTextureScaleEdit(),
                                                onChanged: controller
                                                    .setActiveFillTextureScale,
                                                onChangeEnd: (_) => controller
                                                    .endTerrainTextureScaleEdit(),
                                              ),
                                              _BrushSlider(
                                                label:
                                                    'Opacity ${(controller.activeFillOpacity * 100).round()}%',
                                                value: controller
                                                    .activeFillOpacity,
                                                min: 0.05,
                                                max: 1,
                                                divisions: 19,
                                                onChangeStart: (_) => controller
                                                    .beginTerrainTextureScaleEdit(),
                                                onChanged: controller
                                                    .setActiveFillOpacity,
                                                onChangeEnd: (_) => controller
                                                    .endTerrainTextureScaleEdit(),
                                              ),
                                              _BrushSlider(
                                                label:
                                                    'Edge ${controller.activeFillEdgeBlend.toStringAsFixed(2)}',
                                                value: controller
                                                    .activeFillEdgeBlend,
                                                min: 0,
                                                max: 3,
                                                divisions: 30,
                                                onChangeStart: (_) => controller
                                                    .beginTerrainTextureScaleEdit(),
                                                onChanged: controller
                                                    .setActiveFillEdgeBlend,
                                                onChangeEnd: (_) => controller
                                                    .endTerrainTextureScaleEdit(),
                                              ),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      region == null &&
                                                              liquid == null
                                                          ? 'Used by the next fill. Smaller values create finer detail.'
                                                          : 'Editing ${material.name}. Changes preview live.',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodySmall,
                                                    ),
                                                  ),
                                                  TextButton(
                                                    onPressed: scale == 1
                                                        ? null
                                                        : controller
                                                              .resetActiveFillTextureScale,
                                                    child: const Text('Reset'),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ],
                                        );
                                      },
                                    ),
                                  if (!controller.hasSelectedEnvironmentArea &&
                                      (controller.mode ==
                                              EnvironmentEditorMode
                                                  .surfacePolygon ||
                                          controller
                                              .selectedMaterialIsWater)) ...[
                                    _BrushSlider(
                                      label:
                                          'Surface elevation ${controller.newSurfaceElevation.toStringAsFixed(2)}',
                                      value: controller.newSurfaceElevation,
                                      min: -4,
                                      max: 4,
                                      divisions: 32,
                                      onChanged:
                                          controller.setNewSurfaceElevation,
                                    ),
                                    if (controller.selectedMaterialIsWater)
                                      _BrushSlider(
                                        label:
                                            'Water depth ${controller.newWaterDepth.toStringAsFixed(2)}',
                                        value: controller.newWaterDepth,
                                        min: 0.05,
                                        max: 3,
                                        divisions: 59,
                                        onChanged: controller.setNewWaterDepth,
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: _AssetGrid(
                            itemCount: materials.length,
                            itemBuilder: (index) {
                              final material = materials[index];
                              return _AssetCard(
                                name: material.name,
                                badge: _index.packShortName(
                                  material.sourcePack,
                                ),
                                thumbnailPath: material.thumbnailPath,
                                fallbackIcon: Icons.brush_outlined,
                                selected:
                                    (controller.mode ==
                                            EnvironmentEditorMode.paint ||
                                        controller.mode ==
                                            EnvironmentEditorMode.fillGround ||
                                        controller.mode ==
                                            EnvironmentEditorMode
                                                .surfacePolygon) &&
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
                    Column(
                      children: [
                        if (controller.mode == EnvironmentEditorMode.path)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            child: Column(
                              children: [
                                _BrushSlider(
                                  label:
                                      'Piece ${controller.pathPieceLength.toStringAsFixed(1)}',
                                  value: controller.pathPieceLength,
                                  min: 0.25,
                                  max: 8,
                                  divisions: 31,
                                  onChanged: controller.setPathPieceLength,
                                ),
                                _BrushSlider(
                                  label:
                                      'Gap ${controller.pathGap.toStringAsFixed(1)}',
                                  value: controller.pathGap,
                                  min: -1.5,
                                  max: 6,
                                  divisions: 30,
                                  onChanged: controller.setPathGap,
                                ),
                                _BrushSlider(
                                  label:
                                      'Opening ${controller.pathOpening.toStringAsFixed(1)}',
                                  value: controller.pathOpening,
                                  min: 0,
                                  max: 12,
                                  divisions: 24,
                                  onChanged: controller.setPathOpening,
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton.icon(
                                    onPressed: controller.rotatePathOrientation,
                                    icon: const Icon(Icons.rotate_right),
                                    label: Text(
                                      'Rotate orientation ${controller.pathDirectionOffset + 1}/8',
                                    ),
                                  ),
                                ),
                                const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Drag either endpoint to correct the line. Changes preview live until applied.',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed: controller.hasPathDraft
                                            ? controller.cancelPathDraft
                                            : null,
                                        child: const Text('Cancel'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: FilledButton.icon(
                                        onPressed: controller.hasPathDraft
                                            ? controller.applyPathDraft
                                            : null,
                                        icon: const Icon(Icons.check),
                                        label: const Text('Apply'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: _selectedObjectCategory,
                            decoration: const InputDecoration(
                              labelText: 'Category',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              DropdownMenuItem<String>(
                                value: _allObjectCategories,
                                child: Text(
                                  'All (${controller.catalog.objects.length})',
                                ),
                              ),
                              for (final category in categories)
                                DropdownMenuItem<String>(
                                  value: category,
                                  child: Text(
                                    '${_categoryLabel(category)} '
                                    '(${_index.categoryCounts[category]})',
                                  ),
                                ),
                            ],
                            onChanged: (category) {
                              if (category != null) {
                                setState(
                                  () => _selectedObjectCategory = category,
                                );
                              }
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${objects.length} assets',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                        Expanded(
                          child: _AssetGrid(
                            itemCount: objects.length,
                            itemBuilder: (index) {
                              final object = objects[index];
                              return _AssetCard(
                                name: object.name,
                                subtitle:
                                    '${_index.packName(object.sourcePack)} · ${object.categoryBreadcrumb}',
                                badge:
                                    '${_index.packShortName(object.sourcePack)} · ${switch (object.viewMode) {
                                      EnvironmentAssetViewMode.fixed => 'FIXED',
                                      EnvironmentAssetViewMode.fourWay => '4-WAY',
                                      EnvironmentAssetViewMode.eightWay => '8-WAY',
                                    }}',
                                thumbnailPath: object.thumbnailPath,
                                fallbackIcon: switch (object.topLevelCategory) {
                                  'Environment' => Icons.park_outlined,
                                  'Structures' => Icons.fence_outlined,
                                  'Buildings' => Icons.cottage_outlined,
                                  'Furniture' => Icons.chair_outlined,
                                  'Small Items' => Icons.inventory_2_outlined,
                                  'Animals' => Icons.pets_outlined,
                                  _ => Icons.nature_outlined,
                                },
                                selected:
                                    (controller.mode ==
                                            EnvironmentEditorMode.place ||
                                        controller.mode ==
                                            EnvironmentEditorMode.path) &&
                                    controller.selectedObjectAssetId ==
                                        object.id,
                                onTap: () =>
                                    controller.mode ==
                                        EnvironmentEditorMode.path
                                    ? controller.selectPathObjectAsset(object)
                                    : controller.selectObjectAsset(object),
                              );
                            },
                          ),
                        ),
                      ],
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
                        label: 'Path',
                        icon: Icons.timeline,
                        selected: controller.mode == EnvironmentEditorMode.path,
                        onTap: () =>
                            controller.selectMode(EnvironmentEditorMode.path),
                      ),
                    ),
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
                        label: 'Geometry',
                        icon: Icons.polyline_outlined,
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

class _BrushSlider extends StatelessWidget {
  const _BrushSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 78,
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChangeStart: onChangeStart,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ),
    ],
  );
}

String _categoryLabel(String category) {
  final segments = category.split(' / ');
  return '${List.filled(segments.length - 1, '  ').join()}${segments.last}';
}

const _allObjectCategories = '__all__';
const _allSourcePacks = '__all_packs__';

class _AssetPaletteIndex {
  _AssetPaletteIndex(EnvironmentCatalog catalog)
    : _materials = List.of(catalog.materials),
      _objects = List.of(catalog.objects),
      sourcePacks = List.of(catalog.sourcePacks) {
    _sourcePackNames.addEntries(
      sourcePacks.map((pack) => MapEntry(pack.id, pack.name)),
    );
    for (final material in _materials) {
      _materialSearch[material.id] = [
        material.name,
        material.sourcePack,
        packName(material.sourcePack),
        ...material.tags,
      ].join('\n').toLowerCase();
    }
    for (final object in _objects) {
      _objectSearch[object.id] = [
        object.id,
        object.name,
        object.family,
        object.categoryBreadcrumb,
        object.sourcePack,
        packName(object.sourcePack),
        ...object.tags,
      ].join('\n').toLowerCase();
      final segments = object.categoryPath.isEmpty
          ? [object.category]
          : object.categoryPath;
      for (var length = 1; length <= segments.length; length++) {
        final category = segments.take(length).join(' / ');
        categoryCounts[category] = (categoryCounts[category] ?? 0) + 1;
      }
    }
    categories = categoryCounts.keys.toList()..sort();
  }

  final List<EnvironmentMaterial> _materials;
  final List<EnvironmentObjectAsset> _objects;
  final List<EnvironmentSourcePack> sourcePacks;
  final Map<String, String> _sourcePackNames = {};
  final Map<String, String> _materialSearch = {};
  final Map<String, String> _objectSearch = {};
  final Map<String, int> categoryCounts = {};
  late final List<String> categories;

  String packName(String id) => _sourcePackNames[id] ?? id;

  String packShortName(String id) => switch (id) {
    'ow1' => 'CORE 1',
    'ow2' => 'CORE 2',
    'ow3' => 'CORE 3',
    'nf' => 'NORTHFOLK',
    'owdt' => 'DARK TOWN',
    'animals' => 'ANIMALS',
    _ => id.toUpperCase(),
  };

  List<EnvironmentMaterial> materialsMatching(
    String query, {
    required String sourcePack,
  }) {
    final terms = _terms(query);
    return [
      for (final material in _materials)
        if ((sourcePack == _allSourcePacks ||
                material.sourcePack == sourcePack) &&
            _matches(_materialSearch[material.id]!, terms))
          material,
    ];
  }

  List<EnvironmentObjectAsset> objectsMatching(
    String query, {
    required String category,
    required String sourcePack,
  }) {
    final terms = _terms(query);
    return [
      for (final object in _objects)
        if ((sourcePack == _allSourcePacks ||
                object.sourcePack == sourcePack) &&
            (category == _allObjectCategories ||
                object.categoryBreadcrumb == category ||
                object.categoryBreadcrumb.startsWith('$category /')) &&
            _matches(_objectSearch[object.id]!, terms))
          object,
    ];
  }

  static List<String> _terms(String query) =>
      query.split(RegExp(r'\s+')).where((term) => term.isNotEmpty).toList();

  static bool _matches(String source, List<String> terms) =>
      terms.every(source.contains);
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
    this.badge,
  });

  final String name;
  final String? subtitle;
  final String? badge;
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
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _AssetThumbnail(
                        path: thumbnailPath,
                        icon: fallbackIcon,
                      ),
                    ),
                    if (badge != null)
                      Positioned(
                        top: 5,
                        right: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest.withValues(
                              alpha: 0.92,
                            ),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            child: Text(
                              badge!,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
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

class _LightingExperimentPanel extends StatefulWidget {
  const _LightingExperimentPanel({
    required this.game,
    required this.onFocusAsset,
  });

  final EditorGame game;
  final VoidCallback onFocusAsset;

  @override
  State<_LightingExperimentPanel> createState() =>
      _LightingExperimentPanelState();
}

class _LightingExperimentPanelState extends State<_LightingExperimentPanel> {
  Timer? _timer;
  EditorGame get game => widget.game;

  void _change(VoidCallback action) => setState(action);

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
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      width: 300,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xE617211C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x667BD6A0)),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 12)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'LIGHTING EXPERIMENT',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              Switch(
                value: game.experimentalLightingEnabled,
                onChanged: (_) => _change(game.toggleExperimentalLighting),
              ),
            ],
          ),
          Text(
            game.experimentalLightingReady
                ? 'custom.asset · surface lighting + 3D proxy shadow'
                : 'Shader unavailable: ${game.experimentalLightingError ?? 'loading'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          _ExperimentSlider(
            label: 'Light angle',
            valueLabel:
                '${game.experimentalLightAzimuthDegrees.toStringAsFixed(0)}°',
            value: game.experimentalLightAzimuthDegrees,
            max: 360,
            divisions: 72,
            onChanged: (value) =>
                _change(() => game.setExperimentalLightAzimuth(value)),
          ),
          _ExperimentSlider(
            label: 'Light intensity',
            valueLabel: game.experimentalLightIntensity.toStringAsFixed(2),
            value: game.experimentalLightIntensity,
            max: 8,
            divisions: 64,
            onChanged: (value) =>
                _change(() => game.setExperimentalLightIntensity(value)),
          ),
          _ExperimentSlider(
            label: 'Self-shadow',
            valueLabel: '${(game.experimentalShadowStrength * 100).round()}%',
            value: game.experimentalShadowStrength,
            max: 1,
            divisions: 20,
            onChanged: (value) =>
                _change(() => game.setExperimentalShadowStrength(value)),
          ),
          _ExperimentSlider(
            label: 'Cast shadow',
            valueLabel:
                '${(game.experimentalCastShadowStrength * 100).round()}%',
            value: game.experimentalCastShadowStrength,
            max: 1,
            divisions: 20,
            onChanged: (value) =>
                _change(() => game.setExperimentalCastShadowStrength(value)),
          ),
          const SizedBox(height: 4),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Lit')),
              ButtonSegment(value: 1, label: Text('Normals')),
              ButtonSegment(value: 2, label: Text('Height')),
            ],
            selected: {game.experimentalLightingVisualization},
            onSelectionChanged: (selection) {
              final desired = selection.first;
              _change(() {
                while (game.experimentalLightingVisualization != desired) {
                  game.cycleExperimentalLightingVisualization();
                }
              });
            },
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.onFocusAsset,
              icon: const Icon(Icons.center_focus_strong, size: 16),
              label: const Text('Focus custom.asset'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ExperimentSlider extends StatelessWidget {
  const _ExperimentSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 86, child: Text(label)),
      Expanded(
        child: Slider(
          value: value,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ),
      SizedBox(width: 42, child: Text(valueLabel, textAlign: TextAlign.right)),
    ],
  );
}

class _EditorDiagnosticsHud extends StatefulWidget {
  const _EditorDiagnosticsHud({
    required this.game,
    required this.controller,
    required this.session,
    required this.frameTimings,
  });

  final EditorGame game;
  final EditorController controller;
  final EditorChunkSession? session;
  final _EditorFrameTimings frameTimings;

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
    final hoveredId = widget.controller.hoveredObjectId;
    final hovered = hoveredId == null
        ? null
        : widget.controller.objectById(hoveredId);
    final asset = hovered == null
        ? null
        : widget.controller.catalog.objectById(hovered.assetId);
    final layer = hovered == null
        ? null
        : widget.controller.editorLayerById(hovered.editorLayerId);
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
            'F6 lighting · F7 lit/normals/height · [ ] light angle · - = intensity\n'
            'lighting ${widget.game.experimentalLightingEnabled ? 'on' : 'off'}  '
            '${widget.game.experimentalLightingReady ? widget.game.experimentalLightingVisualizationName : 'shader unavailable'}  '
            '${widget.game.experimentalLightAzimuthDegrees.toStringAsFixed(0)}°  '
            'self ${(widget.game.experimentalShadowStrength * 100).round()}%  '
            'cast ${(widget.game.experimentalCastShadowStrength * 100).round()}%\n'
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
            'terrain cache ${widget.game.terrainPictureCount}  '
            'rasters ${widget.game.terrainRasterCount}  '
            'hi-res ${widget.game.highResolutionTerrainRasterCount}  '
            '${widget.game.usesDirectTerrainRendering ? 'direct  ' : ''}'
            '${(widget.game.terrainRasterBytes / (1 << 20)).toStringAsFixed(1)} MiB  '
            'baking ${widget.game.pendingTerrainBakeCount}\n'
            '${widget.game.isAutoIdle ? 'idle' : '${widget.game.diagnosticsFps.toStringAsFixed(1)} fps'}  '
            '${widget.game.isAutoIdle ? '-' : widget.game.diagnosticsFrameMilliseconds.toStringAsFixed(1)} ms frame  '
            '${widget.game.updateMilliseconds.toStringAsFixed(2)} ms update  '
            '${widget.game.renderMilliseconds.toStringAsFixed(2)} ms canvas\n'
            '${widget.frameTimings.buildMilliseconds.toStringAsFixed(2)} ms build  '
            '${widget.frameTimings.rasterMilliseconds.toStringAsFixed(2)} ms raster  '
            '${widget.game.visibleSpriteCount}/${widget.game.renderCandidateCount} sprites  '
            '${widget.game.culledSpriteCount} culled  '
            'index ${widget.game.renderIndexFullRebuildCount} full/'
            '${widget.game.renderIndexIncrementalUpdateCount} delta\n'
            'hit ${widget.game.lastHitTestCandidateCount} candidates  '
            '${widget.game.lastHitTestMilliseconds.toStringAsFixed(3)} ms',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

class _EditorFrameTimings {
  double buildMilliseconds = 0;
  double rasterMilliseconds = 0;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addTimingsCallback(_record);
  }

  void _record(List<FrameTiming> timings) {
    for (final timing in timings) {
      final build = timing.buildDuration.inMicroseconds / 1000;
      final raster = timing.rasterDuration.inMicroseconds / 1000;
      buildMilliseconds = buildMilliseconds == 0
          ? build
          : buildMilliseconds * 0.8 + build * 0.2;
      rasterMilliseconds = rasterMilliseconds == 0
          ? raster
          : rasterMilliseconds * 0.8 + raster * 0.2;
    }
  }

  void dispose() {
    if (!_started) return;
    WidgetsBinding.instance.removeTimingsCallback(_record);
    _started = false;
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
        final selectedObjects = controller.selectedObjects;
        final terrainRegion = controller.selectedTerrainRegion;
        final surface = controller.selectedSurface;
        final liquid = controller.selectedLiquidVolume;
        final terrainMaterial = terrainRegion == null
            ? null
            : controller.catalog.materialById(terrainRegion.materialId);
        final asset = object == null
            ? null
            : controller.catalog.objectById(object.assetId);
        final selectedByLayer = <String, List<PlacedEnvironmentObject>>{};
        if (selectedObjects.length > 1) {
          for (final selected in selectedObjects.take(100)) {
            selectedByLayer
                .putIfAbsent(selected.editorLayerId, () => [])
                .add(selected);
          }
        }
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
              '${controller.document.terrainRegions.length} ground fills · '
              '${controller.document.terrainStrokes.length} paint strokes',
            ),
            Text(
              '${controller.document.surfaces.length} surfaces · '
              '${controller.document.liquidVolumes.length} liquid volumes · '
              '${controller.document.surfaceConnectors.length} connectors',
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
            if (object == null && !controller.hasSelectedEnvironmentArea) ...[
              const Text('No object selected'),
              const SizedBox(height: 8),
              const Text(
                'Choose Select for objects or Edit fill for ground regions.',
              ),
            ] else if (object == null && surface != null) ...[
              Text(
                surface.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text('${surface.points.length} polygon points'),
              Text('kind ${surface.kind.name}'),
              Text('support id ${surface.id}'),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Geometry only'),
                subtitle: Text(
                  surface.id == environmentBaseSurfaceId
                      ? 'The base world surface must draw its material.'
                      : 'Keep elevation, navigation, and object support without drawing the default material.',
                ),
                value: !surface.drawsBaseMaterial,
                onChanged: surface.id == environmentBaseSurfaceId
                    ? null
                    : controller.setSelectedSurfaceGeometryOnly,
              ),
              const SizedBox(height: 8),
              _NumberStepper(
                label: 'Surface elevation',
                value: surface.height.elevation,
                step: 0.25,
                onDecrease: () =>
                    controller.adjustSelectedTerrainElevation(-0.25),
                onIncrease: () =>
                    controller.adjustSelectedTerrainElevation(0.25),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: controller.document.activeSurfaceId == surface.id
                    ? null
                    : () => controller.setActiveSurface(surface.id),
                icon: const Icon(Icons.layers_outlined),
                label: const Text('Use as target surface'),
              ),
              const SizedBox(height: 8),
              Text(
                'Objects and paint placed while this surface is active are bound to it. Other floors at the same x/y remain independent.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: controller.deleteSelected,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete surface'),
              ),
            ] else if (object == null && liquid != null) ...[
              Text(liquid.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('${liquid.points.length} polygon points'),
              Text('bed surface ${liquid.bedSurfaceId}'),
              const SizedBox(height: 8),
              _NumberStepper(
                label: 'Liquid surface elevation',
                value: liquid.surfaceElevation,
                step: 0.25,
                onDecrease: () =>
                    controller.adjustSelectedTerrainElevation(-0.25),
                onIncrease: () =>
                    controller.adjustSelectedTerrainElevation(0.25),
              ),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Variable depth'),
                subtitle: const Text(
                  'Interpolate from one authored depth endpoint to another',
                ),
                value: liquid.hasDepthRamp,
                onChanged: controller.setSelectedVariableWaterDepth,
              ),
              if (liquid.hasDepthRamp) ...[
                _NumberStepper(
                  label: 'Start depth',
                  value: liquid.depth,
                  step: 0.1,
                  onDecrease: () => controller.adjustSelectedWaterDepth(-0.1),
                  onIncrease: () => controller.adjustSelectedWaterDepth(0.1),
                ),
                const SizedBox(height: 8),
                _NumberStepper(
                  label: 'End depth',
                  value: liquid.endDepth!,
                  step: 0.1,
                  onDecrease: () =>
                      controller.adjustSelectedWaterEndDepth(-0.1),
                  onIncrease: () => controller.adjustSelectedWaterEndDepth(0.1),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: controller.swapSelectedWaterDepthRamp,
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Swap depth ends'),
                ),
                const SizedBox(height: 4),
                Text(
                  'In Edit fill mode, drag cyan (start) and purple (end) to aim the depth ramp.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ] else
                _NumberStepper(
                  label: 'Depth',
                  value: liquid.depth,
                  step: 0.1,
                  onDecrease: () => controller.adjustSelectedWaterDepth(-0.1),
                  onIncrease: () => controller.adjustSelectedWaterDepth(0.1),
                ),
              const SizedBox(height: 8),
              _NumberStepper(
                label: 'Opacity',
                value: liquid.opacity,
                step: 0.05,
                onDecrease: () => controller.adjustSelectedFillOpacity(-0.05),
                onIncrease: () => controller.adjustSelectedFillOpacity(0.05),
              ),
              const SizedBox(height: 8),
              _NumberStepper(
                label: 'Edge softness',
                value: liquid.edgeBlend,
                step: 0.1,
                onDecrease: () => controller.adjustSelectedFillEdgeBlend(-0.1),
                onIncrease: () => controller.adjustSelectedFillEdgeBlend(0.1),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: controller.deleteSelected,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete liquid'),
              ),
            ] else if (object == null) ...[
              Text(
                terrainRegion!.resetsToDefault
                    ? 'Clear-fill region'
                    : terrainMaterial?.name ?? terrainRegion.materialId,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text('${terrainRegion.points.length} polygon points'),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          controller.moveSelectedTerrainRegionOrder(-1),
                      icon: const Icon(Icons.arrow_downward, size: 18),
                      label: const Text('Behind'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          controller.moveSelectedTerrainRegionOrder(1),
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      label: const Text('In front'),
                    ),
                  ),
                ],
              ),
              if (!terrainRegion.resetsToDefault) ...[
                Text(
                  'texture size ${(terrainRegion.textureScale * 100).round()}%',
                ),
                Text(
                  'repeat ${(terrainMaterial!.effectiveRepeatWorldWidth * terrainRegion.textureScale).toStringAsFixed(1)} × ${(terrainMaterial.effectiveRepeatWorldHeight * terrainRegion.textureScale).toStringAsFixed(1)} world units',
                ),
                const SizedBox(height: 8),
                _NumberStepper(
                  label: 'Opacity',
                  value: terrainRegion.opacity,
                  step: 0.05,
                  onDecrease: () => controller.adjustSelectedFillOpacity(-0.05),
                  onIncrease: () => controller.adjustSelectedFillOpacity(0.05),
                ),
                const SizedBox(height: 8),
                _NumberStepper(
                  label: 'Edge softness',
                  value: terrainRegion.edgeBlend,
                  step: 0.1,
                  onDecrease: () =>
                      controller.adjustSelectedFillEdgeBlend(-0.1),
                  onIncrease: () => controller.adjustSelectedFillEdgeBlend(0.1),
                ),
                Text(
                  'Opacity and edge softness are visual; the polygon remains the exact gameplay boundary.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  'Paint on ${controller.document.surfaceById(terrainRegion.surfaceId)?.name ?? terrainRegion.surfaceId}. Height belongs to that surface, not this paint.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Adjust texture size in the Ground palette. Click another region with Edit fill.',
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: controller.deleteSelected,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete fill'),
              ),
            ] else ...[
              Text(
                selectedObjects.length == 1
                    ? asset?.name ?? object.assetId
                    : '${selectedObjects.length} objects selected',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text('x ${object.x.toStringAsFixed(2)}'),
              Text('y ${object.y.toStringAsFixed(2)}'),
              Text('view ${object.direction.name}'),
              Text('render band ${asset?.renderBand.name ?? 'unknown'}'),
              if (asset?.animalAnimation case final animation?) ...[
                const SizedBox(height: 8),
                Text('ANIMAL', style: Theme.of(context).textTheme.labelMedium),
                if (controller.animalBehaviorProfileFor(object)
                    case final profile?) ...[
                  DropdownButtonFormField<String>(
                    initialValue: profile.id,
                    decoration: const InputDecoration(
                      labelText: 'Behavior profile',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final candidate
                          in controller.catalog.animalBehaviorProfiles)
                        DropdownMenuItem(
                          value: candidate.id,
                          child: Text(candidate.name),
                        ),
                    ],
                    onChanged: (id) {
                      if (id != null) {
                        controller.setSelectedAnimalBehaviorProfile(id);
                      }
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    profile.roamingRadius <= 0
                        ? 'stays at its home point'
                        : 'home radius ${profile.roamingRadius.toStringAsFixed(1)} world units',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (object.behaviorProfileId == null)
                    Text(
                      'Using ${animation.behaviorProfileId} default',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ],
              if (controller.mode == EnvironmentEditorMode.collision) ...[
                const SizedBox(height: 10),
                _GeometryEditor(controller: controller),
              ],
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue:
                    selectedObjects.every(
                      (selected) =>
                          selected.supportSurfaceId == object.supportSurfaceId,
                    )
                    ? object.supportSurfaceId
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Support surface',
                  helperText: 'The floor this selection stands on',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final candidate in controller.document.surfaces)
                    DropdownMenuItem(
                      value: candidate.id,
                      child: Text(candidate.name),
                    ),
                ],
                onChanged: (surfaceId) {
                  if (surfaceId != null) {
                    controller.setSelectedSupportSurface(surfaceId);
                  }
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Occlude upper surfaces'),
                subtitle: const Text(
                  'Depth-sort this object with overlapping surfaces above its support floor',
                ),
                value: object.crossSurfaceOcclusion,
                onChanged: controller.setSelectedCrossSurfaceOcclusion,
              ),
              if (object.crossSurfaceOcclusion) ...[
                _NumberStepper(
                  label: 'Occlusion height',
                  value: object.occlusionHeight,
                  step: 0.5,
                  onDecrease: () =>
                      controller.adjustSelectedOcclusionHeight(-0.5),
                  onIncrease: () =>
                      controller.adjustSelectedOcclusionHeight(0.5),
                ),
                const SizedBox(height: 4),
                Text(
                  'Maximum vertical distance to an overlapping surface',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
              if (selectedObjects.length > 1) ...[
                const SizedBox(height: 12),
                for (final layer in controller.document.editorLayers)
                  if (selectedByLayer[layer.id]
                      case final selectedInLayer?) ...[
                    Text(
                      '${layer.name} (${selectedInLayer.length}${selectedObjects.length > 100 ? '+' : ''})',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    for (final selected in selectedInLayer)
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
                if (selectedObjects.length > 100) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Showing the first 100 selected objects.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<EnvironmentLiquidInteraction>(
                initialValue: object.liquidInteraction,
                decoration: const InputDecoration(
                  labelText: 'Liquid interaction',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final interaction in EnvironmentLiquidInteraction.values)
                    DropdownMenuItem(
                      value: interaction,
                      child: Text(interaction.name),
                    ),
                ],
                onChanged: (interaction) {
                  if (interaction != null) {
                    controller.setSelectedLiquidInteraction(interaction);
                  }
                },
              ),
              const SizedBox(height: 8),
              _NumberStepper(
                label: 'Liquid draft',
                value: object.liquidDraft,
                step: 0.05,
                onDecrease: () => controller.adjustSelectedLiquidDraft(-0.05),
                onIncrease: () => controller.adjustSelectedLiquidDraft(0.05),
              ),
              const SizedBox(height: 8),
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
    final geometry = controller.catalog.geometryForAsset(
      asset,
      direction: object.direction.name,
    );
    final shapes = switch (controller.geometryRole) {
      GeometryRole.footprint => geometry.footprints,
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
          asset.views.length == 1
              ? 'Geometry: shared fixed view'
              : controller.selectedGeometryHasViewOverride
              ? 'Geometry: ${object.direction.name} view override'
              : 'Geometry: shared fallback for ${object.direction.name}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          'Purple cross pivot · yellow ring sort anchor\n'
          'Blue sort footprint · red independent blocker\n'
          'Green walkable · purple selection\n'
          'Polygon vertices can be dragged directly on the canvas.',
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
            if (shapes.isNotEmpty)
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
            if (shapes.isNotEmpty) const SizedBox(width: 6),
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
            if (geometry.footprints.isNotEmpty)
              OutlinedButton(
                onPressed: controller.addFootprintToBlocking,
                child: const Text('Add footprint blockers'),
              ),
            if (geometry.footprints.isNotEmpty)
              OutlinedButton(
                onPressed: controller.replaceBlockingWithFootprint,
                child: const Text('Replace blockers'),
              ),
            if (controller.geometryRole == GeometryRole.blocking &&
                shape != null)
              OutlinedButton(
                onPressed: controller.copySelectedBlockingToFootprint,
                child: const Text('Blocker → footprint'),
              ),
            FilledButton.tonal(
              onPressed: controller.markSelectedGeometryReviewed,
              child: const Text('Mark reviewed'),
            ),
            if (controller.selectedGeometryHasViewOverride)
              OutlinedButton(
                onPressed: controller.resetSelectedGeometryViewOverride,
                child: Text('Reset ${object.direction.name} view'),
              ),
            OutlinedButton(
              onPressed:
                  controller.catalog.geometryOverrides.containsKey(asset.id)
                  ? controller.resetSelectedGeometryOverride
                  : null,
              child: const Text('Reset all geometry'),
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
