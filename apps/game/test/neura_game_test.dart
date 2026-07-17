import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  test('maps world movement onto all documented character directions', () {
    expect(
      directionForWorldDelta(Vector2(1, 0)),
      EnvironmentDirection.southEast,
    );
    expect(
      directionForWorldDelta(Vector2(0, 1)),
      EnvironmentDirection.southWest,
    );
    expect(
      directionForWorldDelta(Vector2(-1, 0)),
      EnvironmentDirection.northWest,
    );
    expect(
      directionForWorldDelta(Vector2(0, -1)),
      EnvironmentDirection.northEast,
    );
    expect(directionForWorldDelta(Vector2(1, 1)), EnvironmentDirection.south);
    expect(directionForWorldDelta(Vector2(-1, -1)), EnvironmentDirection.north);
  });

  test('navigation passes under a tree canopy but routes around its trunk', () {
    final tree = _asset(
      const EnvironmentAssetGeometry(
        footprints: [
          EnvironmentEllipse(
            center: EnvironmentGeometryPoint(0, 0),
            radius: EnvironmentGeometryPoint(1.8, 1.4),
          ),
        ],
        blocking: [
          EnvironmentEllipse(
            center: EnvironmentGeometryPoint(0, 0),
            radius: EnvironmentGeometryPoint(0.25, 0.18),
          ),
        ],
      ),
    );
    final placed = PlacedEnvironmentObject(
      id: 'tree',
      assetId: tree.id,
      x: 5,
      y: 5,
    );
    bool blocked(WorldPoint point) =>
        environmentObjectBlocksPoint(tree, placed, point, actorRadius: 0.18);
    final path = NavigationGrid(
      width: 10,
      height: 10,
      cellSize: 0.25,
      isBlocked: blocked,
    ).findPath(const WorldPoint(3, 5), const WorldPoint(7, 5));

    expect(path, isNotEmpty);
    expect(path.every((point) => !blocked(point)), isTrue);
    expect(path.any((point) => (point.y - 5).abs() > 0.18), isTrue);
    expect(
      path.every((point) => (point.y - 5).abs() < 1.4),
      isTrue,
      reason: 'The route should stay below the canopy footprint.',
    );
  });

  test(
    'fence capsule blocks crossing while bridge rails leave deck walkable',
    () {
      final fence = _asset(
        const EnvironmentAssetGeometry(
          blocking: [
            EnvironmentCapsule(
              start: EnvironmentGeometryPoint(-3, 0),
              end: EnvironmentGeometryPoint(3, 0),
              radius: 0.1,
            ),
          ],
        ),
      );
      final placedFence = PlacedEnvironmentObject(
        id: 'fence',
        assetId: fence.id,
        x: 5,
        y: 5,
        direction: EnvironmentDirection.west,
      );
      bool fenceBlocked(WorldPoint point) => environmentObjectBlocksPoint(
        fence,
        placedFence,
        point,
        actorRadius: 0.18,
      );
      final aroundFence = NavigationGrid(
        width: 10,
        height: 10,
        cellSize: 0.25,
        isBlocked: fenceBlocked,
      ).findPath(const WorldPoint(3, 5), const WorldPoint(7, 5));
      expect(aroundFence, isNotEmpty);
      expect(aroundFence.every((point) => !fenceBlocked(point)), isTrue);
      expect(
        aroundFence.any((point) => point.y < 1.8 || point.y > 8.2),
        isTrue,
      );

      final bridge = _asset(
        const EnvironmentAssetGeometry(
          blocking: [
            EnvironmentCapsule(
              start: EnvironmentGeometryPoint(-1, -0.45),
              end: EnvironmentGeometryPoint(1, -0.45),
              radius: 0.08,
            ),
            EnvironmentCapsule(
              start: EnvironmentGeometryPoint(-1, 0.45),
              end: EnvironmentGeometryPoint(1, 0.45),
              radius: 0.08,
            ),
          ],
          walkable: [
            EnvironmentRectangle(
              center: EnvironmentGeometryPoint(0, 0),
              size: EnvironmentGeometryPoint(2, 0.7),
            ),
          ],
        ),
      );
      final placedBridge = PlacedEnvironmentObject(
        id: 'bridge',
        assetId: bridge.id,
        x: 5,
        y: 5,
      );
      bool bridgeBlocked(WorldPoint point) => environmentObjectBlocksPoint(
        bridge,
        placedBridge,
        point,
        actorRadius: 0.12,
      );
      final acrossBridge = NavigationGrid(
        width: 10,
        height: 10,
        cellSize: 0.2,
        isBlocked: bridgeBlocked,
      ).findPath(const WorldPoint(4.1, 5), const WorldPoint(5.9, 5));
      expect(acrossBridge, isNotEmpty);
      expect(acrossBridge.every((point) => !bridgeBlocked(point)), isTrue);
      expect(acrossBridge.every((point) => (point.y - 5).abs() < 0.3), isTrue);
    },
  );
}

EnvironmentObjectAsset _asset(EnvironmentAssetGeometry geometry) =>
    EnvironmentObjectAsset(
      id: 'asset',
      name: 'Asset',
      category: 'Test',
      renderScale: 1,
      geometry: geometry,
      views: const {'south': EnvironmentObjectView(imagePath: 'unused.png')},
    );
