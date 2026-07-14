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
      for (final stroke in document.terrainStrokes)
        if (stroke.opacity > 0 && stroke.points.isNotEmpty)
          NativeNavigationTerrainStroke(
            points: [
              for (final point in stroke.points)
                NativeNavigationPoint(x: point.x, y: point.y),
            ],
            // Match environmentMaterialAtPoint's collision coverage.
            radius: stroke.radius * 0.75,
            blocked: materialBlocks(stroke.materialId),
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
