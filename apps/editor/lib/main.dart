import 'dart:async';
import 'dart:io';

import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

import 'editor_controller.dart';
import 'editor_game.dart';

const _starterAsset =
    'packages/neura_assets/assets/worlds/environment_starter.json';
const _catalogAsset =
    'packages/neura_assets/assets/catalogs/environment_catalog.json';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 160
    ..maximumSizeBytes = 32 << 20;
  runApp(const NeuraEditorApp());
}

class NeuraEditorApp extends StatelessWidget {
  const NeuraEditorApp({super.key});

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
    home: const EditorBootstrap(),
  );
}

class EditorBootstrap extends StatefulWidget {
  const EditorBootstrap({super.key});

  @override
  State<EditorBootstrap> createState() => _EditorBootstrapState();
}

class _EditorBootstrapState extends State<EditorBootstrap> {
  late final Future<List<String>> _sources = Future.wait([
    rootBundle.loadString(_starterAsset),
    rootBundle.loadString(_catalogAsset),
  ]);

  @override
  Widget build(BuildContext context) => FutureBuilder<List<String>>(
    future: _sources,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          body: Center(child: Text('Could not load editor: ${snapshot.error}')),
        );
      }
      final sources = snapshot.data;
      if (sources == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return EditorScreen(
        starterSource: sources[0],
        catalog: EnvironmentCatalog.fromJsonString(sources[1]),
      );
    },
  );
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.starterSource,
    required this.catalog,
    this.renderGame = true,
    super.key,
  });

  final String starterSource;
  final EnvironmentCatalog catalog;
  final bool renderGame;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final EnvironmentDocument _starter = EnvironmentDocument.fromJsonString(
    widget.starterSource,
  );
  late final EditorController controller = EditorController(
    EnvironmentDocument.fromJsonString(widget.starterSource),
    catalog: widget.catalog,
  );
  late final EditorGame game = EditorGame(controller);
  bool _gesturing = false;
  Duration? _lastPanEventTime;
  Timer? _scrollPanEndTimer;

  @override
  void dispose() {
    _scrollPanEndTimer?.cancel();
    controller.dispose();
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
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: Column(
          children: [
            _Toolbar(
              controller: controller,
              onZoomIn: () => game.zoomBy(1.2),
              onZoomOut: () => game.zoomBy(1 / 1.2),
              onExport: _showExport,
              onImport: _showImport,
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
    onExit: (_) => controller.hover(null),
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerHover: (event) => _hoverAt(event.localPosition),
      onPointerDown: (event) {
        if (event.buttons & kPrimaryButton == 0) return;
        _gesturing = true;
        controller.beginGesture();
        _applyAt(event.localPosition);
      },
      onPointerMove: (event) {
        _hoverAt(event.localPosition);
        if (!_gesturing) return;
        final point = _worldAt(event.localPosition);
        if (point == null) return;
        if (controller.mode == EnvironmentEditorMode.select &&
            controller.selectedObject != null) {
          controller.moveSelectedDuringGesture(point);
        } else {
          controller.applyAt(point);
        }
      },
      onPointerUp: (_) => _endGesture(),
      onPointerCancel: (_) => _endGesture(),
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        _beginPan();
        game.panByScreenDelta(
          Vector2(-event.scrollDelta.dx, -event.scrollDelta.dy),
          elapsedSeconds: _panElapsed(event.timeStamp),
        );
        _scrollPanEndTimer?.cancel();
        _scrollPanEndTimer = Timer(
          const Duration(milliseconds: 55),
          game.endPan,
        );
      },
      onPointerPanZoomStart: (event) {
        _lastPanEventTime = event.timeStamp;
        game.beginPan();
      },
      onPointerPanZoomUpdate: (event) => game.panByScreenDelta(
        Vector2(event.panDelta.dx, event.panDelta.dy),
        elapsedSeconds: _panElapsed(event.timeStamp),
      ),
      onPointerPanZoomEnd: (_) => game.endPan(),
      child: Stack(
        children: [
          Positioned.fill(
            child: widget.renderGame
                ? GameWidget(game: game)
                : const ColoredBox(color: Color(0xFF111713)),
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
          const Positioned(
            right: 14,
            bottom: 14,
            child: _StatusChip(text: 'Drag to paint  •  Two-finger pan'),
          ),
        ],
      ),
    ),
  );

  WorldPoint? _worldAt(Offset position) =>
      game.worldAtScreen(Vector2(position.dx, position.dy));

  void _hoverAt(Offset position) => controller.hover(_worldAt(position));

  void _applyAt(Offset position) {
    final point = _worldAt(position);
    if (point != null) controller.applyAt(point);
  }

  void _endGesture() {
    if (!_gesturing) return;
    _gesturing = false;
    controller.endGesture();
  }

  void _beginPan() {
    _lastPanEventTime ??= Duration.zero;
    game.beginPan();
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
    required this.onImport,
    required this.onReset,
  });

  final EditorController controller;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onExport;
  final VoidCallback onImport;
  final VoidCallback onReset;

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
        TextButton(onPressed: onExport, child: const Text('Export')),
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
    padding: const EdgeInsets.only(bottom: 4),
    child: ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      leading: Icon(icon, size: 20),
      title: Text(label),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onTap: onTap,
    ),
  );
}

class _Inspector extends StatelessWidget {
  const _Inspector({required this.controller});

  final EditorController controller;

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
            if (object == null) ...[
              const Text('No object selected'),
              const SizedBox(height: 8),
              const Text('Choose “Select and move”, then drag an object.'),
            ] else ...[
              Text(
                asset?.name ?? object.assetId,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text('x ${object.x.toStringAsFixed(2)}'),
              Text('y ${object.y.toStringAsFixed(2)}'),
              Text('view ${object.direction.name}'),
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
