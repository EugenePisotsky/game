import 'dart:math' as math;

import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

double environmentDirectionAngle(EnvironmentDirection direction) =>
    switch (direction) {
      EnvironmentDirection.south => 0,
      EnvironmentDirection.southWest => math.pi / 4,
      EnvironmentDirection.west => math.pi / 2,
      EnvironmentDirection.northWest => 3 * math.pi / 4,
      EnvironmentDirection.north => math.pi,
      EnvironmentDirection.northEast => -3 * math.pi / 4,
      EnvironmentDirection.east => -math.pi / 2,
      EnvironmentDirection.southEast => -math.pi / 4,
    };

WorldPoint transformEnvironmentGeometryPoint(
  EnvironmentGeometryPoint point,
  PlacedEnvironmentObject object,
) {
  final angle = environmentDirectionAngle(object.direction);
  final cosine = math.cos(angle);
  final sine = math.sin(angle);
  return WorldPoint(
    object.x + point.x * cosine - point.y * sine,
    object.y + point.x * sine + point.y * cosine,
  );
}

bool environmentShapeContainsPoint(
  EnvironmentGeometryShape shape,
  PlacedEnvironmentObject object,
  WorldPoint point, {
  double padding = 0,
}) {
  final local = _inversePoint(point, object);
  return switch (shape) {
    EnvironmentCircle() => _circleContains(shape, local, padding),
    EnvironmentEllipse() => _ellipseContains(shape, local, padding),
    EnvironmentRectangle() => _rectangleContains(shape, local, padding),
    EnvironmentPolygon() => _polygonContains(shape, local, padding),
    EnvironmentCapsule() => _capsuleContains(shape, local, padding),
  };
}

bool environmentObjectBlocksPoint(
  EnvironmentObjectAsset asset,
  PlacedEnvironmentObject object,
  WorldPoint point, {
  double actorRadius = 0,
  EnvironmentAssetGeometry? geometry,
}) => (geometry ?? asset.geometry).blocking.any(
  (shape) =>
      environmentShapeContainsPoint(shape, object, point, padding: actorRadius),
);

List<WorldPoint> environmentShapeOutline(
  EnvironmentGeometryShape shape,
  PlacedEnvironmentObject object, {
  int curvedSegments = 24,
}) {
  final localPoints = switch (shape) {
    EnvironmentCircle() => [
      for (var index = 0; index < curvedSegments; index++)
        EnvironmentGeometryPoint(
          shape.center.x +
              math.cos(index * 2 * math.pi / curvedSegments) * shape.radius,
          shape.center.y +
              math.sin(index * 2 * math.pi / curvedSegments) * shape.radius,
        ),
    ],
    EnvironmentEllipse() => [
      for (var index = 0; index < curvedSegments; index++)
        EnvironmentGeometryPoint(
          shape.center.x +
              math.cos(index * 2 * math.pi / curvedSegments) * shape.radius.x,
          shape.center.y +
              math.sin(index * 2 * math.pi / curvedSegments) * shape.radius.y,
        ),
    ],
    EnvironmentRectangle() => _rectangleCorners(shape),
    EnvironmentPolygon() => shape.points,
    EnvironmentCapsule() => _capsuleOutline(shape, curvedSegments),
  };
  return [
    for (final point in localPoints)
      transformEnvironmentGeometryPoint(point, object),
  ];
}

EnvironmentGeometryPoint _inversePoint(
  WorldPoint point,
  PlacedEnvironmentObject object,
) {
  final angle = -environmentDirectionAngle(object.direction);
  final dx = point.x - object.x;
  final dy = point.y - object.y;
  return EnvironmentGeometryPoint(
    dx * math.cos(angle) - dy * math.sin(angle),
    dx * math.sin(angle) + dy * math.cos(angle),
  );
}

bool _circleContains(
  EnvironmentCircle circle,
  EnvironmentGeometryPoint point,
  double padding,
) {
  final dx = point.x - circle.center.x;
  final dy = point.y - circle.center.y;
  final radius = circle.radius + padding;
  return dx * dx + dy * dy <= radius * radius;
}

bool _ellipseContains(
  EnvironmentEllipse ellipse,
  EnvironmentGeometryPoint point,
  double padding,
) {
  final dx = (point.x - ellipse.center.x) / (ellipse.radius.x + padding);
  final dy = (point.y - ellipse.center.y) / (ellipse.radius.y + padding);
  return dx * dx + dy * dy <= 1;
}

bool _rectangleContains(
  EnvironmentRectangle rectangle,
  EnvironmentGeometryPoint point,
  double padding,
) {
  final angle = -rectangle.rotationDegrees * math.pi / 180;
  final dx = point.x - rectangle.center.x;
  final dy = point.y - rectangle.center.y;
  final x = dx * math.cos(angle) - dy * math.sin(angle);
  final y = dx * math.sin(angle) + dy * math.cos(angle);
  return x.abs() <= rectangle.size.x / 2 + padding &&
      y.abs() <= rectangle.size.y / 2 + padding;
}

bool _polygonContains(
  EnvironmentPolygon polygon,
  EnvironmentGeometryPoint point,
  double padding,
) {
  var inside = false;
  for (
    var i = 0, j = polygon.points.length - 1;
    i < polygon.points.length;
    j = i++
  ) {
    final a = polygon.points[i];
    final b = polygon.points[j];
    if (((a.y > point.y) != (b.y > point.y)) &&
        point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
    if (padding > 0 && _distanceToSegment(point, a, b) <= padding) return true;
  }
  return inside;
}

bool _capsuleContains(
  EnvironmentCapsule capsule,
  EnvironmentGeometryPoint point,
  double padding,
) =>
    _distanceToSegment(point, capsule.start, capsule.end) <=
    capsule.radius + padding;

double _distanceToSegment(
  EnvironmentGeometryPoint point,
  EnvironmentGeometryPoint start,
  EnvironmentGeometryPoint end,
) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final lengthSquared = dx * dx + dy * dy;
  final t = lengthSquared == 0
      ? 0.0
      : (((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
            .clamp(0.0, 1.0);
  final nearestX = start.x + dx * t;
  final nearestY = start.y + dy * t;
  return math.sqrt(
    math.pow(point.x - nearestX, 2) + math.pow(point.y - nearestY, 2),
  );
}

List<EnvironmentGeometryPoint> _rectangleCorners(
  EnvironmentRectangle rectangle,
) {
  final angle = rectangle.rotationDegrees * math.pi / 180;
  final cosine = math.cos(angle);
  final sine = math.sin(angle);
  return [
    for (final point in [
      EnvironmentGeometryPoint(-rectangle.size.x / 2, -rectangle.size.y / 2),
      EnvironmentGeometryPoint(rectangle.size.x / 2, -rectangle.size.y / 2),
      EnvironmentGeometryPoint(rectangle.size.x / 2, rectangle.size.y / 2),
      EnvironmentGeometryPoint(-rectangle.size.x / 2, rectangle.size.y / 2),
    ])
      EnvironmentGeometryPoint(
        rectangle.center.x + point.x * cosine - point.y * sine,
        rectangle.center.y + point.x * sine + point.y * cosine,
      ),
  ];
}

List<EnvironmentGeometryPoint> _capsuleOutline(
  EnvironmentCapsule capsule,
  int segments,
) {
  final angle = math.atan2(
    capsule.end.y - capsule.start.y,
    capsule.end.x - capsule.start.x,
  );
  final half = math.max(4, segments ~/ 2);
  return [
    for (var index = 0; index <= half; index++)
      EnvironmentGeometryPoint(
        capsule.end.x +
            math.cos(angle - math.pi / 2 + index * math.pi / half) *
                capsule.radius,
        capsule.end.y +
            math.sin(angle - math.pi / 2 + index * math.pi / half) *
                capsule.radius,
      ),
    for (var index = 0; index <= half; index++)
      EnvironmentGeometryPoint(
        capsule.start.x +
            math.cos(angle + math.pi / 2 + index * math.pi / half) *
                capsule.radius,
        capsule.start.y +
            math.sin(angle + math.pi / 2 + index * math.pi / half) *
                capsule.radius,
      ),
  ];
}
