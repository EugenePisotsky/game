import 'dart:async';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

import 'editor_controller.dart';
import 'editor_game.dart';

const _starterWorldAsset =
    'packages/neura_assets/assets/worlds/starter_world.json';
const _groundCatalogAsset =
    'packages/neura_assets/assets/catalogs/ground_catalog.json';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NeuraEditorApp());
}

class NeuraEditorApp extends StatelessWidget {
  const NeuraEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Neura Editor',
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
      home: const EditorBootstrap(),
    );
  }
}

class EditorBootstrap extends StatefulWidget {
  const EditorBootstrap({super.key});

  @override
  State<EditorBootstrap> createState() => _EditorBootstrapState();
}

class _EditorBootstrapState extends State<EditorBootstrap> {
  late final Future<List<String>> _sources = Future.wait([
    rootBundle.loadString(_starterWorldAsset),
    rootBundle.loadString(_groundCatalogAsset),
  ]);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _sources,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Text('Could not load starter map: ${snapshot.error}'),
            ),
          );
        }
        final sources = snapshot.data;
        if (sources == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return EditorScreen(
          starterSource: sources[0],
          groundCatalog: GroundCatalog.fromJsonString(sources[1]),
        );
      },
    );
  }
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.starterSource,
    required this.groundCatalog,
    super.key,
  });

  final String starterSource;
  final GroundCatalog groundCatalog;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EditorController controller = EditorController(
    WorldDocument.fromJsonString(widget.starterSource),
    groundCatalog: widget.groundCatalog,
  );
  late final EditorGame game = EditorGame(controller);
  bool _painting = false;
  Duration? _lastPanEventTime;
  Timer? _scrollPanEndTimer;

  @override
  void dispose() {
    _scrollPanEndTimer?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
            controller.undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            controller.redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            controller.undo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): controller.redo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true):
            controller.redo,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              _Toolbar(
                controller: controller,
                onExport: _showExport,
                onImport: _showImport,
                onReset: _reset,
              ),
              Expanded(
                child: Row(
                  children: [
                    _Palette(controller: controller),
                    const VerticalDivider(width: 1),
                    Expanded(child: ClipRect(child: _buildCanvas())),
                    const VerticalDivider(width: 1),
                    _CellInspector(controller: controller),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    return MouseRegion(
      onExit: (_) => controller.hover(null),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerHover: (event) => _hoverAt(event.localPosition),
        onPointerDown: (event) {
          if (event.buttons & kPrimaryButton == 0) return;
          _painting = true;
          controller.beginStroke();
          _paintAt(event.localPosition);
        },
        onPointerMove: (event) {
          _hoverAt(event.localPosition);
          final keyboard = HardwareKeyboard.instance;
          if (_painting &&
              (keyboard.isControlPressed || keyboard.isMetaPressed)) {
            _paintAt(event.localPosition);
          }
        },
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            _beginPanIfNeeded();
            game.panByScreenDelta(
              Vector2(-event.scrollDelta.dx, -event.scrollDelta.dy),
              elapsedSeconds: _panElapsedSeconds(event.timeStamp),
            );
            _scrollPanEndTimer?.cancel();
            _scrollPanEndTimer = Timer(
              const Duration(milliseconds: 55),
              _endPan,
            );
            _hoverAt(event.localPosition);
          }
        },
        onPointerPanZoomStart: (event) {
          _scrollPanEndTimer?.cancel();
          _lastPanEventTime = event.timeStamp;
          game.beginPan();
        },
        onPointerPanZoomUpdate: (event) {
          game.panByScreenDelta(
            Vector2(event.panDelta.dx, event.panDelta.dy),
            elapsedSeconds: _panElapsedSeconds(event.timeStamp),
          );
          _hoverAt(event.localPosition);
        },
        onPointerPanZoomEnd: (_) => _endPan(),
        onPointerUp: (_) => _endStroke(),
        onPointerCancel: (_) => _endStroke(),
        child: Stack(
          children: [
            Positioned.fill(child: GameWidget(game: game)),
            Positioned(
              left: 16,
              bottom: 16,
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final cell = controller.hoveredCell;
                  return _StatusChip(
                    text: cell == null
                        ? 'Move over the map'
                        : 'Cell ${cell.x}, ${cell.y}  •  ${controller.selectedTool.label}',
                  );
                },
              ),
            ),
            const Positioned(
              right: 16,
              bottom: 16,
              child: _StatusChip(
                text: '⌘/Ctrl + drag to paint  •  Two-finger swipe to pan',
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _hoverAt(Offset position) =>
      controller.hover(game.cellAtScreen(Vector2(position.dx, position.dy)));

  void _paintAt(Offset position) {
    final cell = game.cellAtScreen(Vector2(position.dx, position.dy));
    if (cell != null) controller.paint(cell);
  }

  void _endStroke() {
    if (!_painting) return;
    _painting = false;
    controller.endStroke();
  }

  void _beginPanIfNeeded() {
    if (_lastPanEventTime != null) return;
    game.beginPan();
  }

  double _panElapsedSeconds(Duration timestamp) {
    final previous = _lastPanEventTime;
    _lastPanEventTime = timestamp;
    if (previous == null) return 1 / 60;
    return (timestamp - previous).inMicroseconds /
        Duration.microsecondsPerSecond;
  }

  void _endPan() {
    _lastPanEventTime = null;
    game.endPan();
  }

  void _reset() {
    controller.replaceDocument(
      WorldDocument.fromJsonString(widget.starterSource),
    );
    _message('Starter Meadow restored');
  }

  Future<void> _showExport() async {
    final source = controller.document.toJsonString();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export world JSON'),
        content: SizedBox(
          width: 680,
          height: 440,
          child: TextField(
            controller: TextEditingController(text: source),
            readOnly: true,
            expands: true,
            maxLines: null,
            minLines: null,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: source));
              if (context.mounted) Navigator.pop(context);
              _message('World JSON copied');
            },
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy JSON'),
          ),
        ],
      ),
    );
  }

  Future<void> _showImport() async {
    final input = TextEditingController();
    final imported = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import world JSON'),
        content: SizedBox(
          width: 680,
          height: 440,
          child: TextField(
            controller: input,
            expands: true,
            maxLines: null,
            minLines: null,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Paste an exported world document here',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    input.dispose();
    if (imported == null || imported.trim().isEmpty) return;
    try {
      controller.replaceDocument(WorldDocument.fromJsonString(imported));
      _message('World imported');
    } on Object catch (error) {
      _message('Invalid world JSON: $error');
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.onExport,
    required this.onImport,
    required this.onReset,
  });

  final EditorController controller;
  final VoidCallback onExport;
  final VoidCallback onImport;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: Color(0xFF171D19),
        border: Border(bottom: BorderSide(color: Color(0xFF303833))),
      ),
      child: Row(
        children: [
          const Icon(Icons.grid_view_rounded, color: Color(0xFF8FC19F)),
          const SizedBox(width: 10),
          const Text(
            'NEURA WORLD EDITOR',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5),
          ),
          const SizedBox(width: 18),
          const Text(
            'Starter Meadow',
            style: TextStyle(color: Color(0xFFAEBBB2)),
          ),
          const Spacer(),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Row(
              children: [
                IconButton(
                  tooltip: 'Undo',
                  onPressed: controller.canUndo ? controller.undo : null,
                  icon: const Icon(Icons.undo_rounded),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: controller.canRedo ? controller.redo : null,
                  icon: const Icon(Icons.redo_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Reset'),
          ),
          TextButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Import'),
          ),
          FilledButton.tonalIcon(
            onPressed: onExport,
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Export'),
          ),
        ],
      ),
    );
  }
}

class _Palette extends StatelessWidget {
  const _Palette({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 344,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 24),
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'PALETTE',
                style: TextStyle(
                  color: Color(0xFF8E9B92),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _ToolTile(
              tool: EditorTool.inspect,
              selected:
                  controller.selectedGroundItem == null &&
                  controller.selectedTool == EditorTool.inspect,
              onPressed: controller.selectTool,
            ),
            const SizedBox(height: 16),
            _group('ELEVATION', const [
              EditorTool.raiseElevation,
              EditorTool.lowerElevation,
            ]),
            if (controller.selectedTool.layer == EditorLayer.elevation &&
                controller.selectedGroundItem == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
                child: Text(
                  controller.elevationBrushTarget == null
                      ? 'Select the first cell to choose the level.'
                      : 'Painting level ${controller.elevationBrushTarget}. Reselect or switch tools to start another level.',
                  style: const TextStyle(
                    color: Color(0xFF849088),
                    height: 1.35,
                    fontSize: 11.5,
                  ),
                ),
              ),
            _group('TERRAIN', const [
              EditorTool.grass,
              EditorTool.rockySoil,
              EditorTool.darkEarth,
              EditorTool.cobblestone,
              EditorTool.woodPlanks,
              EditorTool.stonePavers,
              EditorTool.dryGrass,
            ]),
            _group('ROADS', const [EditorTool.road]),
            for (final collection in controller.groundCatalog.collections)
              if (_catalogItems(collection.id).isNotEmpty)
                _groundGroup(collection),
            _group('NATURE', const [
              EditorTool.roundTree,
              EditorTool.wideTree,
              EditorTool.ruralTreeA1,
              EditorTool.ruralTreeA2,
              EditorTool.ruralTreeA3,
              EditorTool.ruralTreeA4,
              EditorTool.ruralTreeA5,
              EditorTool.ruralTreeA6,
              EditorTool.ruralTreeA7,
              EditorTool.ruralTreeA8,
              EditorTool.ruralTreeA9,
              EditorTool.ruralTreeA10,
              EditorTool.ruralTreeA11,
              EditorTool.ruralTreeA12,
              EditorTool.ruralTreeB1,
              EditorTool.ruralTreeB2,
              EditorTool.ruralTreeB3,
              EditorTool.ruralTreeC1,
              EditorTool.ruralTreeC2,
              EditorTool.ruralTreeC3,
              EditorTool.bush,
              EditorTool.lowFlora,
              EditorTool.leafyGroundcover,
            ]),
            _group('PROPS', const [
              EditorTool.clayPots,
              EditorTool.woodenCrate,
              EditorTool.stoneWell,
              EditorTool.woodenSign,
              EditorTool.fallenLog,
              EditorTool.firewoodPile,
              EditorTool.stonePile,
              EditorTool.hayBale,
              EditorTool.closedChest,
            ]),
            _group('ANIMALS', const [EditorTool.sheep]),
            const Divider(height: 28),
            _ToolTile(
              tool: EditorTool.erase,
              selected:
                  controller.selectedGroundItem == null &&
                  controller.selectedTool == EditorTool.erase,
              onPressed: controller.selectTool,
            ),
            const SizedBox(height: 20),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Terrain always exists. Objects and animals are separate layers, so they can be edited independently.',
                style: TextStyle(
                  color: Color(0xFF849088),
                  height: 1.45,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _group(String label, List<EditorTool> tools) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF748078),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1.08,
          children: [
            for (final tool in tools)
              _CatalogTile(
                tool: tool,
                selected:
                    controller.selectedGroundItem == null &&
                    controller.selectedTool == tool,
                onPressed: controller.selectTool,
              ),
          ],
        ),
      ],
    ),
  );

  Widget _groundGroup(GroundCatalogCollection collection) {
    final items = _catalogItems(collection.id);
    return _GroundCollectionSection(
      collection: collection,
      items: items,
      controller: controller,
    );
  }

  List<GroundCatalogItem> _catalogItems(String collectionId) => controller
      .groundCatalog
      .itemsIn(collectionId)
      .where((item) => !earthElevationAssetIds.contains(item.id))
      .toList();
}

class _GroundCollectionSection extends StatefulWidget {
  const _GroundCollectionSection({
    required this.collection,
    required this.items,
    required this.controller,
  });

  final GroundCatalogCollection collection;
  final List<GroundCatalogItem> items;
  final EditorController controller;

  @override
  State<_GroundCollectionSection> createState() =>
      _GroundCollectionSectionState();
}

class _GroundCollectionSectionState extends State<_GroundCollectionSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.collection.name.toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xFF8A978E),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.items.length}',
                    style: const TextStyle(
                      color: Color(0xFF667169),
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: const Color(0xFF748078),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1.08,
              children: [
                for (final item in widget.items)
                  _GroundCatalogTile(
                    item: item,
                    selected: widget.controller.selectedGroundItem == item,
                    onPressed: widget.controller.selectGroundItem,
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _GroundCatalogTile extends StatelessWidget {
  const _GroundCatalogTile({
    required this.item,
    required this.selected,
    required this.onPressed,
  });

  final GroundCatalogItem item;
  final bool selected;
  final ValueChanged<GroundCatalogItem> onPressed;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? const Color(0xFF8FC19F)
        : const Color(0xFF303833);
    return Material(
      color: selected ? const Color(0xFF294034) : const Color(0xFF1A201C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: borderColor, width: selected ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onPressed(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ColoredBox(
                color: const Color(0xFF121713),
                child: Transform.scale(
                  scale: 1.45,
                  alignment: Alignment.bottomCenter,
                  child: Image.asset(
                    '$neuraAssetPrefix${item.assetForKey(TileRotation.north.name[0])}',
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomCenter,
                    filterQuality: FilterQuality.none,
                    errorBuilder: (_, _, _) => const Center(
                      child: Icon(Icons.broken_image_outlined, size: 24),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(7, 5, 7, 6),
              color: const Color(0xB8141916),
              child: Column(
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? const Color(0xFFC3E2CD)
                          : const Color(0xFFC0C9C3),
                    ),
                  ),
                  Text(
                    item.role,
                    style: const TextStyle(
                      color: Color(0xFF77847B),
                      fontSize: 9.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.tool,
    required this.selected,
    required this.onPressed,
  });

  final EditorTool tool;
  final bool selected;
  final ValueChanged<EditorTool> onPressed;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? const Color(0xFF8FC19F)
        : const Color(0xFF303833);
    return Material(
      color: selected ? const Color(0xFF294034) : const Color(0xFF1A201C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: borderColor, width: selected ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onPressed(tool),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _ToolPreview(tool: tool)),
                Container(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
                  color: const Color(0xB8141916),
                  child: Text(
                    tool.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? const Color(0xFFC3E2CD)
                          : const Color(0xFFC0C9C3),
                    ),
                  ),
                ),
              ],
            ),
            if (selected)
              const Positioned(
                right: 6,
                top: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xDD294034),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(
                      Icons.check_rounded,
                      size: 15,
                      color: Color(0xFFBCE0C8),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolPreview extends StatelessWidget {
  const _ToolPreview({required this.tool});

  final EditorTool tool;

  @override
  Widget build(BuildContext context) {
    if (tool == EditorTool.raiseElevation ||
        tool == EditorTool.lowerElevation) {
      return ColoredBox(
        color: const Color(0xFF121713),
        child: Center(
          child: Icon(
            tool == EditorTool.raiseElevation
                ? Icons.arrow_upward_rounded
                : Icons.arrow_downward_rounded,
            size: 34,
            color: const Color(0xFF9BC8A9),
          ),
        ),
      );
    }
    if (tool == EditorTool.sheep) {
      return const ColoredBox(
        color: Color(0xFF121713),
        child: _SheepFramePreview(),
      );
    }
    final paths = _assetsFor(tool);
    return ColoredBox(
      color: const Color(0xFF121713),
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final path in paths)
              Transform.scale(
                scale: _scaleFor(tool),
                alignment: Alignment.bottomCenter,
                child: Image.asset(
                  '$neuraAssetPrefix$path',
                  fit: BoxFit.contain,
                  alignment: Alignment.bottomCenter,
                  filterQuality: FilterQuality.none,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image_outlined, size: 24),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static List<String> _assetsFor(EditorTool tool) => switch (tool) {
    EditorTool.grass => ['ground/dirt_n.png', 'ground/grass_n.png'],
    EditorTool.road => ['ground/road_straight_x.png'],
    EditorTool.rockySoil => ['ground/rocky_soil_n.png'],
    EditorTool.darkEarth => ['ground/dark_earth_n.png'],
    EditorTool.cobblestone => ['ground/dirt_n.png', 'ground/cobblestone_n.png'],
    EditorTool.woodPlanks => ['ground/dirt_n.png', 'ground/wood_planks_n.png'],
    EditorTool.stonePavers => [
      'ground/dirt_n.png',
      'ground/stone_pavers_n.png',
    ],
    EditorTool.dryGrass => ['ground/dirt_n.png', 'ground/dry_grass_n.png'],
    EditorTool.roundTree => ['environment/tree_round.png'],
    EditorTool.wideTree => ['environment/tree_wide.png'],
    EditorTool.ruralTreeA1 => ['environment/rural_tree_A1_N.png'],
    EditorTool.ruralTreeA2 => ['environment/rural_tree_A2_N.png'],
    EditorTool.ruralTreeA3 => ['environment/rural_tree_A3_N.png'],
    EditorTool.ruralTreeA4 => ['environment/rural_tree_A4_N.png'],
    EditorTool.ruralTreeA5 => ['environment/rural_tree_A5_N.png'],
    EditorTool.ruralTreeA6 => ['environment/rural_tree_A6_N.png'],
    EditorTool.ruralTreeA7 => ['environment/rural_tree_A7_N.png'],
    EditorTool.ruralTreeA8 => ['environment/rural_tree_A8_N.png'],
    EditorTool.ruralTreeA9 => ['environment/rural_tree_A9_N.png'],
    EditorTool.ruralTreeA10 => ['environment/rural_tree_A10_N.png'],
    EditorTool.ruralTreeA11 => ['environment/rural_tree_A11_N.png'],
    EditorTool.ruralTreeA12 => ['environment/rural_tree_A12_N.png'],
    EditorTool.ruralTreeB1 => ['environment/rural_tree_B1_N.png'],
    EditorTool.ruralTreeB2 => ['environment/rural_tree_B2_N.png'],
    EditorTool.ruralTreeB3 => ['environment/rural_tree_B3_N.png'],
    EditorTool.ruralTreeC1 => ['environment/rural_tree_C1_N.png'],
    EditorTool.ruralTreeC2 => ['environment/rural_tree_C2_N.png'],
    EditorTool.ruralTreeC3 => ['environment/rural_tree_C3_N.png'],
    EditorTool.bush => ['environment/bush.png'],
    EditorTool.lowFlora => ['environment/low_flora.png'],
    EditorTool.leafyGroundcover => ['environment/leafy_groundcover.png'],
    EditorTool.clayPots => ['environment/clay_pots.png'],
    EditorTool.woodenCrate => ['environment/wooden_crate.png'],
    EditorTool.stoneWell => ['environment/stone_well.png'],
    EditorTool.woodenSign => ['environment/wooden_sign.png'],
    EditorTool.fallenLog => ['environment/fallen_log.png'],
    EditorTool.firewoodPile => ['environment/firewood_pile.png'],
    EditorTool.stonePile => ['environment/stone_pile.png'],
    EditorTool.hayBale => ['environment/hay_bale.png'],
    EditorTool.closedChest => ['environment/closed_chest.png'],
    EditorTool.sheep => const [],
    EditorTool.inspect ||
    EditorTool.raiseElevation ||
    EditorTool.lowerElevation ||
    EditorTool.erase => const [],
  };

  static double _scaleFor(EditorTool tool) => switch (tool) {
    EditorTool.ruralTreeA1 ||
    EditorTool.ruralTreeA2 ||
    EditorTool.ruralTreeA3 ||
    EditorTool.ruralTreeA4 ||
    EditorTool.ruralTreeA5 ||
    EditorTool.ruralTreeA6 ||
    EditorTool.ruralTreeA7 ||
    EditorTool.ruralTreeA8 ||
    EditorTool.ruralTreeA9 ||
    EditorTool.ruralTreeA10 ||
    EditorTool.ruralTreeA11 ||
    EditorTool.ruralTreeA12 ||
    EditorTool.ruralTreeB1 ||
    EditorTool.ruralTreeB2 ||
    EditorTool.ruralTreeB3 ||
    EditorTool.ruralTreeC1 ||
    EditorTool.ruralTreeC2 ||
    EditorTool.ruralTreeC3 => 0.82,
    EditorTool.roundTree ||
    EditorTool.wideTree ||
    EditorTool.stoneWell ||
    EditorTool.woodenSign => 1.15,
    EditorTool.clayPots ||
    EditorTool.woodenCrate ||
    EditorTool.firewoodPile ||
    EditorTool.stonePile ||
    EditorTool.hayBale ||
    EditorTool.closedChest => 1.65,
    EditorTool.sheep => 1,
    _ => 1.45,
  };
}

class _SheepFramePreview extends StatefulWidget {
  const _SheepFramePreview();

  @override
  State<_SheepFramePreview> createState() => _SheepFramePreviewState();
}

class _SheepFramePreviewState extends State<_SheepFramePreview> {
  late final Future<ui.Image> _image = _loadImage();

  Future<ui.Image> _loadImage() async {
    final data = await rootBundle.load(
      '${neuraAssetPrefix}animals/sheep/idle.png',
    );
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    return (await codec.getNextFrame()).image;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image>(
      future: _image,
      builder: (context, snapshot) {
        final image = snapshot.data;
        if (image == null) return const SizedBox.expand();
        return CustomPaint(painter: _SpriteFramePainter(image));
      },
    );
  }
}

class _SpriteFramePainter extends CustomPainter {
  const _SpriteFramePainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    const frameSize = 64.0;
    final renderSize = size.shortestSide * 0.82;
    final destination = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: renderSize,
      height: renderSize,
    );
    canvas.drawImageRect(
      image,
      const Rect.fromLTWH(0, 0, frameSize, frameSize),
      destination,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_SpriteFramePainter oldDelegate) =>
      oldDelegate.image != image;
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.tool,
    required this.selected,
    required this.onPressed,
  });

  final EditorTool tool;
  final bool selected;
  final ValueChanged<EditorTool> onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected ? const Color(0xFF294034) : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: () => onPressed(tool),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Icon(
                  _iconFor(tool),
                  size: 20,
                  color: selected ? const Color(0xFFAAD8B8) : null,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(tool.label)),
                if (selected)
                  const Icon(
                    Icons.check_rounded,
                    size: 17,
                    color: Color(0xFFAAD8B8),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(EditorTool tool) => switch (tool) {
    EditorTool.inspect => Icons.ads_click_rounded,
    EditorTool.raiseElevation => Icons.arrow_upward_rounded,
    EditorTool.lowerElevation => Icons.arrow_downward_rounded,
    EditorTool.grass => Icons.grass_rounded,
    EditorTool.road => Icons.route_rounded,
    EditorTool.rockySoil => Icons.landscape_rounded,
    EditorTool.darkEarth => Icons.texture_rounded,
    EditorTool.cobblestone => Icons.grid_4x4_rounded,
    EditorTool.woodPlanks => Icons.table_rows_rounded,
    EditorTool.stonePavers => Icons.grid_on_rounded,
    EditorTool.dryGrass => Icons.energy_savings_leaf_rounded,
    EditorTool.roundTree => Icons.park_rounded,
    EditorTool.wideTree => Icons.nature_rounded,
    EditorTool.ruralTreeA1 ||
    EditorTool.ruralTreeA2 ||
    EditorTool.ruralTreeA3 ||
    EditorTool.ruralTreeA4 ||
    EditorTool.ruralTreeA5 ||
    EditorTool.ruralTreeA6 ||
    EditorTool.ruralTreeA7 ||
    EditorTool.ruralTreeA8 ||
    EditorTool.ruralTreeA9 ||
    EditorTool.ruralTreeA10 ||
    EditorTool.ruralTreeA11 ||
    EditorTool.ruralTreeA12 ||
    EditorTool.ruralTreeB1 ||
    EditorTool.ruralTreeB2 ||
    EditorTool.ruralTreeB3 ||
    EditorTool.ruralTreeC1 ||
    EditorTool.ruralTreeC2 ||
    EditorTool.ruralTreeC3 => Icons.forest_rounded,
    EditorTool.bush => Icons.eco_rounded,
    EditorTool.lowFlora => Icons.local_florist_rounded,
    EditorTool.leafyGroundcover => Icons.spa_rounded,
    EditorTool.clayPots => Icons.emoji_food_beverage_rounded,
    EditorTool.woodenCrate => Icons.inventory_2_rounded,
    EditorTool.stoneWell => Icons.water_drop_rounded,
    EditorTool.woodenSign => Icons.signpost_rounded,
    EditorTool.fallenLog => Icons.forest_rounded,
    EditorTool.firewoodPile => Icons.local_fire_department_outlined,
    EditorTool.stonePile => Icons.terrain_rounded,
    EditorTool.hayBale => Icons.agriculture_rounded,
    EditorTool.closedChest => Icons.all_inbox_rounded,
    EditorTool.sheep => Icons.pets_rounded,
    EditorTool.erase => Icons.auto_fix_off_rounded,
  };
}

class _CellInspector extends StatelessWidget {
  const _CellInspector({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final cell = controller.selectedCell;
          if (cell == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.layers_outlined,
                      size: 36,
                      color: Color(0xFF69756D),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Select or paint a cell to inspect its layers',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF8E9B92)),
                    ),
                  ],
                ),
              ),
            );
          }
          final document = controller.document;
          final layers = controller.selectedTileLayers;
          final selectedLayer = controller.selectedTileLayer;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
            children: [
              const Text(
                'CELL INSPECTOR',
                style: TextStyle(
                  color: Color(0xFF8E9B92),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${cell.x}, ${cell.y}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 18),
              _InspectorRow(
                icon: Icons.landscape_outlined,
                title: 'Base terrain',
                value: _groundLabel(document.groundAt(cell.x, cell.y)),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    Icons.height_rounded,
                    size: 19,
                    color: Color(0xFF91A297),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Elevation')),
                  IconButton.filledTonal(
                    tooltip: 'Lower elevation',
                    onPressed: document.elevationAt(cell.x, cell.y) == 0
                        ? null
                        : () => controller.changeSelectedElevation(-1),
                    icon: const Icon(Icons.remove_rounded, size: 18),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '${document.elevationAt(cell.x, cell.y)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Raise elevation',
                    onPressed: () => controller.changeSelectedElevation(1),
                    icon: const Icon(Icons.add_rounded, size: 18),
                  ),
                ],
              ),
              if (document.roadAt(cell.x, cell.y) != null)
                const _InspectorRow(
                  icon: Icons.route_rounded,
                  title: 'Road',
                  value: 'Dirt road',
                ),
              const Divider(height: 28),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'STACKED TILE LAYERS',
                      style: TextStyle(
                        color: Color(0xFF8E9B92),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  Text(
                    '${layers.length}',
                    style: const TextStyle(color: Color(0xFF748078)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (layers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'No stacked surface layers',
                    style: TextStyle(color: Color(0xFF748078)),
                  ),
                )
              else
                for (var index = 0; index < layers.length; index++)
                  _LayerRow(
                    layer: layers[index],
                    label:
                        controller.groundCatalog
                            .itemById(layers[index].assetId)
                            ?.name ??
                        layers[index].assetId,
                    index: index,
                    count: layers.length,
                    selected: controller.selectedTileLayerIndex == index,
                    onTap: () => controller.selectTileLayer(index),
                  ),
              if (selectedLayer != null) ...[
                const Divider(height: 28),
                Text(
                  controller.groundCatalog
                          .itemById(selectedLayer.assetId)
                          ?.name ??
                      selectedLayer.assetId,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text(
                  'ROTATION',
                  style: TextStyle(
                    color: Color(0xFF8E9B92),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<TileRotation>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: TileRotation.north, label: Text('N')),
                    ButtonSegment(value: TileRotation.east, label: Text('E')),
                    ButtonSegment(value: TileRotation.south, label: Text('S')),
                    ButtonSegment(value: TileRotation.west, label: Text('W')),
                  ],
                  selected: {selectedLayer.rotation},
                  onSelectionChanged: (selection) =>
                      controller.rotateSelectedTileLayer(selection.single),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Move layer down',
                      onPressed: controller.selectedTileLayerIndex == 0
                          ? null
                          : () => controller.moveSelectedTileLayer(-1),
                      icon: const Icon(Icons.arrow_downward_rounded),
                    ),
                    const SizedBox(width: 6),
                    IconButton.filledTonal(
                      tooltip: 'Move layer up',
                      onPressed:
                          controller.selectedTileLayerIndex == layers.length - 1
                          ? null
                          : () => controller.moveSelectedTileLayer(1),
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
                    const Spacer(),
                    IconButton.filledTonal(
                      tooltip: 'Delete layer',
                      onPressed: controller.removeSelectedTileLayer,
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ],
              if (document.decorationAt(cell.x, cell.y)
                  case final decoration?) ...[
                _InspectorRow(
                  icon: Icons.park_outlined,
                  title: 'Object',
                  value: decoration.type.name,
                ),
                if (decorationSupportsRotation(decoration.type)) ...[
                  const SizedBox(height: 8),
                  SegmentedButton<TileRotation>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: TileRotation.north,
                        label: Text('N'),
                      ),
                      ButtonSegment(value: TileRotation.east, label: Text('E')),
                      ButtonSegment(
                        value: TileRotation.south,
                        label: Text('S'),
                      ),
                      ButtonSegment(value: TileRotation.west, label: Text('W')),
                    ],
                    selected: {decoration.rotation},
                    onSelectionChanged: (selection) =>
                        controller.rotateSelectedDecoration(selection.single),
                  ),
                ],
              ],
              if (document.actorAt(cell.x, cell.y) case final actor?)
                _InspectorRow(
                  icon: Icons.pets_outlined,
                  title: 'Actor',
                  value: actor.type.name,
                ),
            ],
          );
        },
      ),
    );
  }

  static String _groundLabel(GroundType ground) => switch (ground) {
    GroundType.grass => 'Grass',
    GroundType.rockySoil => 'Rocky soil',
    GroundType.darkEarth => 'Dark earth',
    GroundType.cobblestone => 'Cobblestone',
    GroundType.woodPlanks => 'Wood planks',
    GroundType.stonePavers => 'Stone pavers',
    GroundType.dryGrass => 'Dry grass',
  };
}

class _LayerRow extends StatelessWidget {
  const _LayerRow({
    required this.layer,
    required this.label,
    required this.index,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final PlacedTileLayer layer;
  final String label;
  final int index;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final position = index == count - 1
        ? 'Top'
        : index == 0
        ? 'Bottom'
        : '${index + 1}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? const Color(0xFF294034) : const Color(0xFF1A201C),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                const Icon(Icons.layers_rounded, size: 18),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label),
                      Text(
                        '${layer.rotation.name} · $position',
                        style: const TextStyle(
                          color: Color(0xFF849088),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InspectorRow extends StatelessWidget {
  const _InspectorRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, size: 19, color: const Color(0xFF91A297)),
          const SizedBox(width: 10),
          Expanded(child: Text(title)),
          Text(value, style: const TextStyle(color: Color(0xFFB8C5BC))),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xDD171D19),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF38433B)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Text(
            text,
            style: const TextStyle(fontSize: 12, color: Color(0xFFB9C6BD)),
          ),
        ),
      ),
    );
  }
}
