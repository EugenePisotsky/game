import 'dart:collection';
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

EnvironmentGeometryPoint inverseTransformEnvironmentGeometryPoint(
  WorldPoint point,
  PlacedEnvironmentObject object,
) => _inversePoint(point, object);

enum EnvironmentPointFootprintPosition {
  noFootprint,
  behind,
  inside,
  lateral,
  inFront,
}

class EnvironmentDepthSpan {
  const EnvironmentDepthSpan({required this.back, required this.front});

  final double back;
  final double front;
}

class EnvironmentDepthEntity<T> {
  EnvironmentDepthEntity({
    required this.id,
    required this.value,
    required this.contact,
    required this.depth,
    this.tieBreaker = 0,
    List<List<WorldPoint>> footprintOutlines = const [],
    this.footprintDepthBias = 0,
  }) {
    this.footprintOutlines = _immutableNonEmptyOutlines(footprintOutlines);
    footprintHorizontalRanges = this.footprintOutlines.isEmpty
        ? const []
        : List.unmodifiable([
            for (final outline in this.footprintOutlines)
              _footprintHorizontalRange(outline),
          ]);
    if (footprintHorizontalRanges.isEmpty) {
      footprintHorizontalMin = footprintHorizontalMax = _horizontalCoordinate(
        contact,
      );
    } else {
      var horizontalMin = footprintHorizontalRanges.first.$1;
      var horizontalMax = footprintHorizontalRanges.first.$2;
      for (final range in footprintHorizontalRanges.skip(1)) {
        horizontalMin = math.min(horizontalMin, range.$1);
        horizontalMax = math.max(horizontalMax, range.$2);
      }
      footprintHorizontalMin = horizontalMin;
      footprintHorizontalMax = horizontalMax;
    }
  }

  final String id;
  final T value;
  final WorldPoint contact;
  final double depth;
  final double tieBreaker;
  late final List<List<WorldPoint>> footprintOutlines;
  late final List<(double, double)> footprintHorizontalRanges;
  final double footprintDepthBias;
  late final double footprintHorizontalMin;
  late final double footprintHorizontalMax;

  bool get hasFootprint => footprintOutlines.isNotEmpty;
}

List<List<WorldPoint>> _immutableNonEmptyOutlines(
  Iterable<List<WorldPoint>> outlines,
) {
  if (outlines.isEmpty) return const [];
  return List.unmodifiable(
    outlines
        .where((outline) => outline.isNotEmpty)
        .map(List<WorldPoint>.unmodifiable),
  );
}

/// Sorts actors and objects together while preserving stable scalar depth as
/// the fallback. Footprints add local front/behind constraints only where
/// their horizontal ground projections overlap.
List<EnvironmentDepthEntity<T>> sortEnvironmentDepthEntities<T>(
  Iterable<EnvironmentDepthEntity<T>> entities,
) {
  final base = [...entities]
    ..sort((a, b) {
      final depth = a.depth.compareTo(b.depth);
      if (depth != 0) return depth;
      final tie = a.tieBreaker.compareTo(b.tieBreaker);
      return tie != 0 ? tie : a.id.compareTo(b.id);
    });
  if (base.length < 2) return base;

  final outgoing = [for (var index = 0; index < base.length; index++) <int>{}];
  final incoming = List<int>.filled(base.length, 0);
  for (var a = 0; a < base.length - 1; a++) {
    for (var b = a + 1; b < base.length; b++) {
      if (!_depthEntitiesMayConstrain(base[a], base[b])) continue;
      final order = environmentDepthConstraint(base[a], base[b]);
      if (order == null || order == 0) continue;
      final before = order < 0 ? a : b;
      final after = order < 0 ? b : a;
      if (outgoing[before].add(after)) incoming[after]++;
    }
  }

  final remaining = SplayTreeSet<int>.of([
    for (var index = 0; index < base.length; index++) index,
  ]);
  final ready = SplayTreeSet<int>.of([
    for (var index = 0; index < base.length; index++)
      if (incoming[index] == 0) index,
  ]);
  final result = <EnvironmentDepthEntity<T>>[];
  while (remaining.isNotEmpty) {
    // Conflicting overlap constraints can form a cycle. Break it with the
    // stable scalar order instead of allowing the draw order to flicker.
    final next = ready.isEmpty ? remaining.first : ready.first;
    ready.remove(next);
    remaining.remove(next);
    result.add(base[next]);
    for (final target in outgoing[next]) {
      incoming[target]--;
      if (incoming[target] == 0 && remaining.contains(target)) {
        ready.add(target);
      }
    }
  }
  return result;
}

/// Finds where a dynamic entity belongs in an already sorted static scene.
///
/// Static object geometry and object-to-object constraints can therefore be
/// cached. A moving actor only needs one linear pass over that cached order.
int environmentDepthInsertionIndex<T>(
  List<EnvironmentDepthEntity<T>> staticOrder,
  EnvironmentDepthEntity<T> dynamicEntity,
) {
  var scalarIndex = staticOrder.length;
  var minimumIndex = 0;
  var maximumIndex = staticOrder.length;
  var foundScalarIndex = false;

  for (var index = 0; index < staticOrder.length; index++) {
    final entity = staticOrder[index];
    if (!foundScalarIndex && _compareDepth(dynamicEntity, entity) < 0) {
      scalarIndex = index;
      foundScalarIndex = true;
    }
    if (!_depthEntitiesMayConstrain(dynamicEntity, entity)) continue;
    final constraint = environmentDepthConstraint(dynamicEntity, entity);
    if (constraint == null || constraint == 0) continue;
    if (constraint < 0) {
      maximumIndex = math.min(maximumIndex, index);
    } else {
      minimumIndex = math.max(minimumIndex, index + 1);
    }
  }

  // Inconsistent authored shapes can create a cycle around the dynamic
  // entity. Preserve stable scalar order in that exceptional case.
  if (minimumIndex > maximumIndex) return scalarIndex;
  return scalarIndex.clamp(minimumIndex, maximumIndex);
}

int _compareDepth<T>(EnvironmentDepthEntity<T> a, EnvironmentDepthEntity<T> b) {
  final depth = a.depth.compareTo(b.depth);
  if (depth != 0) return depth;
  final tie = a.tieBreaker.compareTo(b.tieBreaker);
  return tie != 0 ? tie : a.id.compareTo(b.id);
}

bool _depthEntitiesMayConstrain<T>(
  EnvironmentDepthEntity<T> a,
  EnvironmentDepthEntity<T> b,
) {
  if (!a.hasFootprint && !b.hasFootprint) return false;
  if (b.hasFootprint && _horizontalWithin(a.contact, b, epsilon: 1e-7)) {
    return true;
  }
  if (a.hasFootprint && _horizontalWithin(b.contact, a, epsilon: 1e-7)) {
    return true;
  }
  return a.hasFootprint &&
      b.hasFootprint &&
      a.footprintHorizontalMin <= b.footprintHorizontalMax &&
      b.footprintHorizontalMin <= a.footprintHorizontalMax;
}

/// Returns a negative value when [a] must draw before [b], a positive value
/// when [b] must draw before [a], and null when scalar depth should decide.
int? environmentDepthConstraint<T>(
  EnvironmentDepthEntity<T> a,
  EnvironmentDepthEntity<T> b,
) {
  if (!a.hasFootprint && !b.hasFootprint) return null;
  int? vote;

  if (b.hasFootprint && _horizontalWithin(a.contact, b, epsilon: 1e-7)) {
    final relation = _pointRelativeToEntityFootprints(a.contact, b);
    switch (relation) {
      case EnvironmentPointFootprintPosition.behind:
      case EnvironmentPointFootprintPosition.inside:
        vote = -1;
      case EnvironmentPointFootprintPosition.inFront:
        vote = 1;
      case EnvironmentPointFootprintPosition.lateral:
      case EnvironmentPointFootprintPosition.noFootprint:
        break;
    }
  }

  if (a.hasFootprint && _horizontalWithin(b.contact, a, epsilon: 1e-7)) {
    final relation = _pointRelativeToEntityFootprints(b.contact, a);
    switch (relation) {
      case EnvironmentPointFootprintPosition.behind:
      case EnvironmentPointFootprintPosition.inside:
        if (vote == -1) return null;
        vote = 1;
      case EnvironmentPointFootprintPosition.inFront:
        if (vote == 1) return null;
        vote = -1;
      case EnvironmentPointFootprintPosition.lateral:
      case EnvironmentPointFootprintPosition.noFootprint:
        break;
    }
  }

  if (vote == null && a.hasFootprint && b.hasFootprint) {
    for (var aIndex = 0; aIndex < a.footprintOutlines.length; aIndex++) {
      final aOutline = a.footprintOutlines[aIndex];
      final aRange = a.footprintHorizontalRanges[aIndex];
      for (var bIndex = 0; bIndex < b.footprintOutlines.length; bIndex++) {
        final bOutline = b.footprintOutlines[bIndex];
        final bRange = b.footprintHorizontalRanges[bIndex];
        final overlapMin = math.max(aRange.$1, bRange.$1);
        final overlapMax = math.min(aRange.$2, bRange.$2);
        if (overlapMin <= overlapMax) {
          final horizontal = (overlapMin + overlapMax) / 2;
          final aSlice = environmentFootprintDepthSliceAt(
            aOutline,
            horizontal,
            depthBias: a.footprintDepthBias,
          );
          final bSlice = environmentFootprintDepthSliceAt(
            bOutline,
            horizontal,
            depthBias: b.footprintDepthBias,
          );
          if (aSlice != null && bSlice != null) {
            int? shapeVote;
            if (aSlice.front <= bSlice.back) {
              shapeVote = -1;
            } else if (bSlice.front <= aSlice.back) {
              shapeVote = 1;
            }
            if (shapeVote != null) {
              if (vote != null && vote != shapeVote) return null;
              vote = shapeVote;
            }
          }
        }
      }
    }
  }

  return vote;
}

EnvironmentPointFootprintPosition _pointRelativeToEntityFootprints<T>(
  WorldPoint point,
  EnvironmentDepthEntity<T> entity,
) => _pointRelativeToFootprintOutlines(
  point,
  entity.footprintOutlines,
  depthBias: entity.footprintDepthBias,
);

EnvironmentPointFootprintPosition _pointRelativeToFootprintOutlines(
  WorldPoint point,
  Iterable<List<WorldPoint>> outlines, {
  required double depthBias,
  double epsilon = 1e-7,
}) {
  EnvironmentPointFootprintPosition? nearest;
  var nearestDistance = double.infinity;
  final horizontal = _horizontalCoordinate(point);
  final depth = _depthCoordinate(point);
  for (final outline in outlines) {
    final slice = environmentFootprintDepthSliceAt(
      outline,
      horizontal,
      depthBias: depthBias,
      epsilon: epsilon,
    );
    if (slice == null) continue;
    final relation = environmentPointRelativeToFootprintOutline(
      point,
      outline,
      depthBias: depthBias,
      epsilon: epsilon,
    );
    if (relation == EnvironmentPointFootprintPosition.inside) return relation;
    final distance = depth < slice.back
        ? slice.back - depth
        : depth > slice.front
        ? depth - slice.front
        : 0.0;
    if (distance < nearestDistance) {
      nearest = relation;
      nearestDistance = distance;
    }
  }
  return nearest ?? EnvironmentPointFootprintPosition.lateral;
}

(double, double) _footprintHorizontalRange(List<WorldPoint> outline) {
  final horizontal = outline.map(_horizontalCoordinate);
  return (horizontal.reduce(math.min), horizontal.reduce(math.max));
}

EnvironmentDepthSpan? environmentFootprintDepthSliceAt(
  List<WorldPoint> outline,
  double horizontal, {
  double depthBias = 0,
  double epsilon = 1e-7,
}) {
  if (outline.length < 2) return null;
  var back = double.infinity;
  var front = double.negativeInfinity;
  for (var index = 0; index < outline.length; index++) {
    final a = outline[index];
    final b = outline[(index + 1) % outline.length];
    final aHorizontal = _horizontalCoordinate(a);
    final bHorizontal = _horizontalCoordinate(b);
    final delta = bHorizontal - aHorizontal;
    if (delta.abs() <= epsilon) {
      if ((horizontal - aHorizontal).abs() <= epsilon) {
        final aDepth = _depthCoordinate(a) + depthBias;
        final bDepth = _depthCoordinate(b) + depthBias;
        back = math.min(back, math.min(aDepth, bDepth));
        front = math.max(front, math.max(aDepth, bDepth));
      }
      continue;
    }
    final t = (horizontal - aHorizontal) / delta;
    if (t < -epsilon || t > 1 + epsilon) continue;
    final depth =
        _depthCoordinate(a) +
        (_depthCoordinate(b) - _depthCoordinate(a)) * t.clamp(0, 1) +
        depthBias;
    back = math.min(back, depth);
    front = math.max(front, depth);
  }
  return back.isFinite ? EnvironmentDepthSpan(back: back, front: front) : null;
}

EnvironmentPointFootprintPosition environmentPointRelativeToFootprintOutline(
  WorldPoint point,
  List<WorldPoint> outline, {
  double depthBias = 0,
  double epsilon = 1e-7,
}) {
  if (outline.length < 2) {
    return EnvironmentPointFootprintPosition.noFootprint;
  }
  final slice = environmentFootprintDepthSliceAt(
    outline,
    _horizontalCoordinate(point),
    depthBias: depthBias,
    epsilon: epsilon,
  );
  if (slice == null) return EnvironmentPointFootprintPosition.lateral;
  final depth = _depthCoordinate(point);
  if (depth >= slice.front - epsilon) {
    return EnvironmentPointFootprintPosition.inFront;
  }
  if (depth <= slice.back + epsilon) {
    return EnvironmentPointFootprintPosition.behind;
  }

  final intersections = _footprintDepthIntersections(
    outline,
    _horizontalCoordinate(point),
    depthBias: depthBias,
    epsilon: epsilon,
  );
  for (var index = 0; index + 1 < intersections.length; index += 2) {
    if (depth >= intersections[index] - epsilon &&
        depth <= intersections[index + 1] + epsilon) {
      return EnvironmentPointFootprintPosition.inside;
    }
  }
  return EnvironmentPointFootprintPosition.lateral;
}

EnvironmentDepthSpan? environmentObjectFootprintDepthSpan(
  EnvironmentObjectAsset asset,
  PlacedEnvironmentObject object, {
  EnvironmentAssetGeometry? geometry,
}) {
  final footprints = (geometry ?? asset.geometry).footprints;
  final outlines = [
    for (final footprint in footprints)
      environmentShapeOutline(footprint, object),
  ].where((outline) => outline.isNotEmpty);
  if (outlines.isEmpty) return null;
  final bias = asset.defaultSortBias + object.sortBias;
  var back = double.infinity;
  var front = double.negativeInfinity;
  for (final outline in outlines) {
    for (final point in outline) {
      final depth = point.x + point.y + bias;
      back = math.min(back, depth);
      front = math.max(front, depth);
    }
  }
  return EnvironmentDepthSpan(back: back, front: front);
}

EnvironmentPointFootprintPosition environmentPointRelativeToObjectFootprint(
  WorldPoint point,
  EnvironmentObjectAsset asset,
  PlacedEnvironmentObject object, {
  EnvironmentAssetGeometry? geometry,
  double epsilon = 1e-6,
}) {
  final resolvedGeometry = geometry ?? asset.geometry;
  if (resolvedGeometry.footprints.isEmpty) {
    return EnvironmentPointFootprintPosition.noFootprint;
  }
  return _pointRelativeToFootprintOutlines(
    point,
    [
      for (final footprint in resolvedGeometry.footprints)
        environmentShapeOutline(footprint, object),
    ],
    depthBias: asset.defaultSortBias + object.sortBias,
    epsilon: epsilon,
  );
}

List<double> _footprintDepthIntersections(
  List<WorldPoint> outline,
  double horizontal, {
  required double depthBias,
  required double epsilon,
}) {
  final intersections = <double>[];
  for (var index = 0; index < outline.length; index++) {
    final a = outline[index];
    final b = outline[(index + 1) % outline.length];
    final aHorizontal = _horizontalCoordinate(a);
    final bHorizontal = _horizontalCoordinate(b);
    if ((aHorizontal - bHorizontal).abs() <= epsilon) continue;
    final crosses =
        (aHorizontal <= horizontal && horizontal < bHorizontal) ||
        (bHorizontal <= horizontal && horizontal < aHorizontal);
    if (!crosses) continue;
    final t = (horizontal - aHorizontal) / (bHorizontal - aHorizontal);
    intersections.add(
      _depthCoordinate(a) +
          (_depthCoordinate(b) - _depthCoordinate(a)) * t +
          depthBias,
    );
  }
  intersections.sort();
  return intersections;
}

bool _horizontalWithin<T>(
  WorldPoint point,
  EnvironmentDepthEntity<T> entity, {
  required double epsilon,
}) {
  final horizontal = _horizontalCoordinate(point);
  return horizontal >= entity.footprintHorizontalMin - epsilon &&
      horizontal <= entity.footprintHorizontalMax + epsilon;
}

double _horizontalCoordinate(WorldPoint point) => point.x - point.y;

double _depthCoordinate(WorldPoint point) => point.x + point.y;

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

/// Resolves the surface pass in which an object should be depth sorted.
///
/// The object's support surface still owns its elevation, collision, and
/// liquid interaction. Tall objects may opt into a later overlapping surface
/// pass so actors standing on that surface can sort in front of or behind the
/// object using the normal footprint rules.
String environmentObjectDepthSurfaceId({
  required EnvironmentDocument document,
  required EnvironmentObjectAsset asset,
  required PlacedEnvironmentObject object,
  required double objectElevation,
  EnvironmentAssetGeometry? geometry,
}) {
  final support =
      document.surfaceById(object.supportSurfaceId) ?? document.baseSurface;
  if (!object.crossSurfaceOcclusion || object.occlusionHeight <= 0) {
    return support.id;
  }

  final footprintOutlines = [
    for (final footprint in (geometry ?? asset.geometry).footprints)
      environmentShapeOutline(footprint, object),
  ];
  final anchor = WorldPoint(object.x, object.y);
  var selected = support;
  var selectedElevation = selected.elevationAt(anchor);
  const epsilon = 1e-7;

  for (final candidate in document.surfaces) {
    if (candidate.id == support.id) continue;
    final candidateElevation = candidate.elevationAt(anchor);
    final height = candidateElevation - objectElevation;
    if (height < -epsilon || height > object.occlusionHeight + epsilon) {
      continue;
    }
    final overlaps = footprintOutlines.isEmpty
        ? candidate.contains(anchor)
        : footprintOutlines.any(
            (outline) => _environmentPolygonsOverlap(outline, candidate.points),
          );
    if (!overlaps) continue;

    final laterOrder = candidate.order.compareTo(selected.order);
    if (laterOrder > 0 ||
        (laterOrder == 0 && candidateElevation > selectedElevation)) {
      selected = candidate;
      selectedElevation = candidateElevation;
    }
  }
  return selected.id;
}

bool _environmentPolygonsOverlap(
  List<WorldPoint> first,
  List<WorldPoint> second,
) {
  if (first.length < 3 || second.length < 3) return false;
  if (first.any((point) => _pointInWorldPolygon(point, second)) ||
      second.any((point) => _pointInWorldPolygon(point, first))) {
    return true;
  }
  for (var a = 0; a < first.length; a++) {
    final aStart = first[a];
    final aEnd = first[(a + 1) % first.length];
    for (var b = 0; b < second.length; b++) {
      if (_worldSegmentsIntersect(
        aStart,
        aEnd,
        second[b],
        second[(b + 1) % second.length],
      )) {
        return true;
      }
    }
  }
  return false;
}

bool _pointInWorldPolygon(WorldPoint point, List<WorldPoint> polygon) {
  var inside = false;
  for (
    var current = 0, previous = polygon.length - 1;
    current < polygon.length;
    previous = current++
  ) {
    final a = polygon[current];
    final b = polygon[previous];
    if (_worldPointOnSegment(point, a, b)) return true;
    if ((a.y > point.y) != (b.y > point.y) &&
        point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

bool _worldSegmentsIntersect(
  WorldPoint a,
  WorldPoint b,
  WorldPoint c,
  WorldPoint d,
) {
  final abC = _worldOrientation(a, b, c);
  final abD = _worldOrientation(a, b, d);
  final cdA = _worldOrientation(c, d, a);
  final cdB = _worldOrientation(c, d, b);
  if (((abC > 0 && abD < 0) || (abC < 0 && abD > 0)) &&
      ((cdA > 0 && cdB < 0) || (cdA < 0 && cdB > 0))) {
    return true;
  }
  return _worldPointOnSegment(c, a, b) ||
      _worldPointOnSegment(d, a, b) ||
      _worldPointOnSegment(a, c, d) ||
      _worldPointOnSegment(b, c, d);
}

double _worldOrientation(WorldPoint a, WorldPoint b, WorldPoint c) =>
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

bool _worldPointOnSegment(WorldPoint point, WorldPoint start, WorldPoint end) {
  const epsilon = 1e-7;
  if (_worldOrientation(start, end, point).abs() > epsilon) return false;
  return point.x >= math.min(start.x, end.x) - epsilon &&
      point.x <= math.max(start.x, end.x) + epsilon &&
      point.y >= math.min(start.y, end.y) - epsilon &&
      point.y <= math.max(start.y, end.y) + epsilon;
}

/// Returns the front-facing silhouette of one or more ground footprints.
///
/// In Neura's isometric projection, `x - y` is the horizontal screen axis and
/// `x + y` increases toward the camera. The convex front chain therefore gives
/// renderers a stable intersection line for a horizontal liquid surface.
/// Multiple footprints are treated as one visual silhouette; transparent gaps
/// in the sprite remain transparent when the resulting mask is composited.
List<WorldPoint> environmentFootprintFrontBoundary(
  Iterable<List<WorldPoint>> outlines,
) {
  final points = <_IsometricFootprintPoint>[
    for (final outline in outlines)
      for (final point in outline)
        _IsometricFootprintPoint(
          horizontal: point.x - point.y,
          depth: point.x + point.y,
        ),
  ];
  if (points.length < 2) return const [];
  points.sort((a, b) {
    final horizontal = a.horizontal.compareTo(b.horizontal);
    return horizontal != 0 ? horizontal : a.depth.compareTo(b.depth);
  });
  final unique = <_IsometricFootprintPoint>[];
  for (final point in points) {
    if (unique.isEmpty ||
        (point.horizontal - unique.last.horizontal).abs() > 1e-9 ||
        (point.depth - unique.last.depth).abs() > 1e-9) {
      unique.add(point);
    }
  }
  if (unique.length < 2) return const [];

  final lower = <_IsometricFootprintPoint>[];
  for (final point in unique) {
    while (lower.length >= 2 &&
        _isometricCross(lower[lower.length - 2], lower.last, point) <= 0) {
      lower.removeLast();
    }
    lower.add(point);
  }
  final upper = <_IsometricFootprintPoint>[];
  for (final point in unique.reversed) {
    while (upper.length >= 2 &&
        _isometricCross(upper[upper.length - 2], upper.last, point) <= 0) {
      upper.removeLast();
    }
    upper.add(point);
  }

  // [lower] and [upper] are named after the conventional Cartesian hull.
  // Screen depth grows downward, so the chain with the larger mean depth is
  // the visible/front liquid intersection.
  final lowerForward = lower;
  final upperForward = upper.reversed.toList(growable: false);
  final front =
      _meanIsometricDepth(lowerForward) >= _meanIsometricDepth(upperForward)
      ? lowerForward
      : upperForward;
  return [
    for (final point in front)
      WorldPoint(
        (point.depth + point.horizontal) / 2,
        (point.depth - point.horizontal) / 2,
      ),
  ];
}

class _IsometricFootprintPoint {
  const _IsometricFootprintPoint({
    required this.horizontal,
    required this.depth,
  });

  final double horizontal;
  final double depth;
}

double _isometricCross(
  _IsometricFootprintPoint origin,
  _IsometricFootprintPoint a,
  _IsometricFootprintPoint b,
) =>
    (a.horizontal - origin.horizontal) * (b.depth - origin.depth) -
    (a.depth - origin.depth) * (b.horizontal - origin.horizontal);

double _meanIsometricDepth(List<_IsometricFootprintPoint> points) =>
    points.fold<double>(0, (sum, point) => sum + point.depth) / points.length;

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
