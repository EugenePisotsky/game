import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_rendering/neura_rendering.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  test('tree collider blocks only the padded trunk area', () {
    const shape = EnvironmentEllipse(
      center: EnvironmentGeometryPoint(0, 0),
      radius: EnvironmentGeometryPoint(0.24, 0.18),
    );
    final tree = PlacedEnvironmentObject(
      id: 'tree',
      assetId: 'tree',
      x: 4,
      y: 5,
    );

    expect(
      environmentShapeContainsPoint(
        shape,
        tree,
        const WorldPoint(4.3, 5),
        padding: 0.12,
      ),
      isTrue,
    );
    expect(
      environmentShapeContainsPoint(
        shape,
        tree,
        const WorldPoint(5, 5),
        padding: 0.12,
      ),
      isFalse,
    );
  });

  test('direction rotates thin fence collision geometry', () {
    const shape = EnvironmentCapsule(
      start: EnvironmentGeometryPoint(-1, 0),
      end: EnvironmentGeometryPoint(1, 0),
      radius: 0.1,
    );
    final fence = PlacedEnvironmentObject(
      id: 'fence',
      assetId: 'fence',
      x: 3,
      y: 3,
      direction: EnvironmentDirection.west,
    );

    expect(
      environmentShapeContainsPoint(shape, fence, const WorldPoint(3, 3.8)),
      isTrue,
    );
    expect(
      environmentShapeContainsPoint(shape, fence, const WorldPoint(3.8, 3)),
      isFalse,
    );
  });
}
