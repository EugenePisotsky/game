import 'dart:math' as math;

import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

const double navigationCellSize = 0.4;
const double playerNavigationRadius = 0.18;

NativeNavigationWorldInput buildNativeNavigationWorldInput({
  required EnvironmentDocument document,
  required EnvironmentCatalog catalog,
}) {
  bool materialBlocks(String id) =>
      catalog.materialById(id)?.blocksMovement ?? false;

  return NativeNavigationWorldInput(
    width: document.width.toDouble(),
    height: document.height.toDouble(),
    cellSize: navigationCellSize,
    actorRadius: playerNavigationRadius,
    baseBlocked: materialBlocks(document.baseMaterialId),
    terrainStrokes: [
      for (final region in document.terrainRegions)
        ..._nativeTerrainRegionOperations(
          region,
          blocked: region.resetsToDefault
              ? materialBlocks(document.baseMaterialId)
              : materialBlocks(region.materialId),
        ),
      for (final stroke in document.terrainStrokes)
        ..._nativeTerrainOperations(
          stroke,
          blocked: materialBlocks(stroke.materialId),
          baseBlockedAt: (point) =>
              materialBlocks(environmentBaseMaterialAtPoint(document, point)),
        ),
    ],
    objectColliders: [
      for (final object in document.objects)
        if (catalog.objectById(object.assetId) case final asset?)
          for (final shape in catalog.geometryForAsset(asset).blocking)
            NativeNavigationPolygon(
              points: [
                for (final point in environmentShapeOutline(shape, object))
                  NativeNavigationPoint(x: point.x, y: point.y),
              ],
            ),
    ],
  );
}

Iterable<NativeNavigationTerrainStroke> _nativeTerrainOperations(
  TerrainStroke stroke, {
  required bool blocked,
  required bool Function(WorldPoint point) baseBlockedAt,
}) sync* {
  if (stroke.opacity <= 0 || stroke.points.isEmpty) return;
  if (!stroke.resetsToBase) {
    yield NativeNavigationTerrainStroke(
      points: [
        for (final point in stroke.points)
          NativeNavigationPoint(x: point.x, y: point.y),
      ],
      // Match environmentMaterialAtPoint's collision coverage.
      radius: stroke.radius * 0.75,
      blocked: blocked,
    );
    return;
  }

  final polygon = stroke.points;
  if (polygon.length < 3) return;
  yield* _nativePolygonOperations(polygon, blockedAt: baseBlockedAt);
}

Iterable<NativeNavigationTerrainStroke> _nativeTerrainRegionOperations(
  TerrainRegion region, {
  required bool blocked,
}) => _nativeConstantPolygonOperations(region.points, blocked: blocked);

Iterable<NativeNavigationTerrainStroke> _nativeConstantPolygonOperations(
  List<WorldPoint> polygon, {
  required bool blocked,
}) sync* {
  if (polygon.length < 3) return;
  final minY = polygon.map((point) => point.y).reduce(math.min);
  final maxY = polygon.map((point) => point.y).reduce(math.max);
  final spacing = navigationCellSize * 0.5;
  final rows = ((maxY - minY) / spacing).ceil().clamp(1, 10000);
  for (var row = 0; row <= rows; row++) {
    final y = minY + (maxY - minY) * ((row + 0.5) / (rows + 1));
    final intersections = _polygonRowIntersections(polygon, y);
    for (var pair = 0; pair + 1 < intersections.length; pair += 2) {
      yield NativeNavigationTerrainStroke(
        points: [
          NativeNavigationPoint(x: intersections[pair], y: y),
          NativeNavigationPoint(x: intersections[pair + 1], y: y),
        ],
        radius: navigationCellSize * 0.55,
        blocked: blocked,
      );
    }
  }
}

Iterable<NativeNavigationTerrainStroke> _nativePolygonOperations(
  List<WorldPoint> polygon, {
  required bool Function(WorldPoint point) blockedAt,
}) sync* {
  if (polygon.length < 3) return;
  final minY = polygon.map((point) => point.y).reduce((a, b) => a < b ? a : b);
  final maxY = polygon.map((point) => point.y).reduce((a, b) => a > b ? a : b);
  final spacing = navigationCellSize * 0.5;
  final rows = ((maxY - minY) / spacing).ceil().clamp(1, 10000);
  for (var row = 0; row <= rows; row++) {
    final y = minY + (maxY - minY) * ((row + 0.5) / (rows + 1));
    final intersections = _polygonRowIntersections(polygon, y);
    for (var pair = 0; pair + 1 < intersections.length; pair += 2) {
      final start = intersections[pair];
      final end = intersections[pair + 1];
      final columns = ((end - start) / spacing).ceil().clamp(1, 10000);
      var runStart = 0;
      bool? runBlocked;
      for (var column = 0; column < columns; column++) {
        final x = start + (end - start) * ((column + 0.5) / columns);
        final blocked = blockedAt(WorldPoint(x, y));
        if (runBlocked == null) {
          runBlocked = blocked;
          runStart = column;
          continue;
        }
        if (runBlocked == blocked) continue;
        yield _nativeNavigationRun(
          start,
          end,
          y,
          columns,
          runStart,
          column - 1,
          runBlocked,
        );
        runStart = column;
        runBlocked = blocked;
      }
      if (runBlocked != null) {
        yield _nativeNavigationRun(
          start,
          end,
          y,
          columns,
          runStart,
          columns - 1,
          runBlocked,
        );
      }
    }
  }
}

List<double> _polygonRowIntersections(List<WorldPoint> polygon, double y) {
  final intersections = <double>[];
  for (var index = 0; index < polygon.length; index++) {
    final a = polygon[index];
    final b = polygon[(index + 1) % polygon.length];
    if (!((a.y <= y && b.y > y) || (b.y <= y && a.y > y))) continue;
    intersections.add(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y));
  }
  intersections.sort();
  return intersections;
}

NativeNavigationTerrainStroke _nativeNavigationRun(
  double start,
  double end,
  double y,
  int columns,
  int first,
  int last,
  bool blocked,
) => NativeNavigationTerrainStroke(
  points: [
    NativeNavigationPoint(
      x: start + (end - start) * ((first + 0.5) / columns),
      y: y,
    ),
    NativeNavigationPoint(
      x: start + (end - start) * ((last + 0.5) / columns),
      y: y,
    ),
  ],
  radius: navigationCellSize * 0.55,
  blocked: blocked,
);
