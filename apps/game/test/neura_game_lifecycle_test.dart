import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/game.dart' show Vector2;
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neura_game/neura_game.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWithGame<NeuraGame>(
    'loads the deterministic release scene through the Flame lifecycle',
    NeuraGame.new,
    (game) async {
      expect(game.isLoaded, isTrue);
      expect(game.size.x, 800);
      expect(game.size.y, 600);
      expect(game.playerPosition.x, 12);
      expect(game.playerPosition.y, 20.5);
      expect(game.currentChunk?.x, 0);
      expect(game.currentChunk?.y, 0);
      expect(game.loadedChunkCount, 4);
      expect(game.terrainPictureCount, game.loadedChunkCount);
      expect(game.decodedImageCount, greaterThan(0));
      expect(game.pendingAssetRequests, 0);
      final order = game.debugRenderOrder;
      expect(order.indexOf('object_162'), lessThan(order.indexOf('player')));
      expect(order.indexOf('object_185'), greaterThan(-1));

      await game.teleportTo(const WorldPoint(4.6, 9));
      expect(
        game.debugRenderOrder.indexOf('player'),
        lessThan(game.debugRenderOrder.indexOf('object_185')),
      );
      await game.teleportTo(const WorldPoint(4.6, 10.2));
      expect(
        game.debugRenderOrder.indexOf('player'),
        greaterThan(game.debugRenderOrder.indexOf('object_185')),
      );

      await game.teleportTo(const WorldPoint(140, 20));
      expect(game.inactiveAssetCount, greaterThan(0));
      final hits = game.assetCacheHits;
      await game.teleportTo(const WorldPoint(12, 20.5));
      expect(game.assetCacheHits, greaterThan(hits));
      expect(game.inactiveAssetCount, lessThanOrEqualTo(24));
    },
  );

  testWithGame<NeuraGame>(
    'opens the same named regression scene used by interactive debugging',
    () => NeuraGame(debugSceneName: 'grass_below_actor'),
    (game) async {
      expect(game.debugScene?.id, 'grass_below_actor');
      expect(game.debugRandomSeed, 2101);
      expect(game.playerPosition.x, closeTo(12.9, 0.0001));
      expect(game.playerPosition.y, closeTo(16.8, 0.0001));
      expect(game.diagnosticsPaused, isTrue);
      expect(
        game.chunkStreamer.loadedChunks.keys.toSet(),
        game.debugScene!.expectedLoadedChunks.toSet(),
      );
    },
  );

  testWithGame<NeuraGame>(
    'crosses repeated chunk seams without gaps, navigation loss, or cache growth',
    NeuraGame.new,
    (game) async {
      const positions = <WorldPoint>[
        WorldPoint(31, 20),
        WorldPoint(33, 20),
        WorldPoint(63, 20),
        WorldPoint(65, 20),
        WorldPoint(97, 20),
        WorldPoint(129, 20),
      ];
      for (final position in positions) {
        await game.teleportTo(position);
        final center = game.worldManifest.coordinateFor(position);
        expect(game.currentChunk, center);
        expect(game.chunkStreamer.loadedChunks, contains(center));
        expect(game.terrainPictureCount, game.loadedChunkCount);
        expect(game.loadedChunkCount, lessThanOrEqualTo(9));
        expect(game.inactiveAssetCount, lessThanOrEqualTo(24));
        expect(game.inactiveAssetBytes, lessThanOrEqualTo(32 << 20));
        final route = game.navigationGrid.findPath(
          position,
          WorldPoint(position.x + 1, position.y),
        );
        expect(route, isNotEmpty, reason: 'navigation at $position');

        final recorder = ui.PictureRecorder();
        game.render(ui.Canvas(recorder));
        recorder.endRecording().dispose();
      }
    },
  );

  testWithGame<NeuraGame>(
    'retargeting while walking preserves the animation phase',
    NeuraGame.new,
    (game) async {
      await game.teleportTo(const WorldPoint(100, 100));
      expect(game.requestMovement(const WorldPoint(110, 104)), isTrue);

      game.update(0.137);
      final phaseBeforeRetarget = game.animationTime;
      expect(phaseBeforeRetarget, greaterThan(0));
      expect(game.isMoving, isTrue);

      expect(game.requestMovement(const WorldPoint(106, 110)), isTrue);

      expect(game.isMoving, isTrue);
      expect(game.animationTime, phaseBeforeRetarget);
    },
  );

  testWithGame<NeuraGame>(
    'opposite facing traverses intermediate rows before movement',
    NeuraGame.new,
    (game) async {
      const start = WorldPoint(100, 100);
      await game.teleportTo(start);

      expect(game.facing, EnvironmentDirection.north);
      expect(game.requestMovement(const WorldPoint(104, 104)), isTrue);
      final facings = <EnvironmentDirection>[game.facing];
      expect(game.isTurning, isTrue);

      for (var step = 0; step < 3; step++) {
        game.update(0.065);
        facings.add(game.facing);
        expect(game.playerPosition.x, closeTo(start.x, 0.0001));
        expect(game.playerPosition.y, closeTo(start.y, 0.0001));
      }

      expect(facings, [
        EnvironmentDirection.northEast,
        EnvironmentDirection.east,
        EnvironmentDirection.southEast,
        EnvironmentDirection.south,
      ]);
      expect(game.isTurning, isFalse);
      game.update(0.02);
      expect(
        game.playerPosition.distanceTo(Vector2(start.x, start.y)),
        greaterThan(0),
      );
    },
  );

  testWithGame<NeuraGame>(
    'short off-angle movement uses animated legs with one deliberate turn',
    NeuraGame.new,
    (game) async {
      const start = WorldPoint(100, 100);
      const target = WorldPoint(101.2, 100.4);
      await game.teleportTo(start);

      expect(game.requestMovement(target), isTrue);
      final plannedWaypoints = game.movementWaypoints;
      expect(plannedWaypoints, hasLength(2));
      var legStart = Vector2(start.x, start.y);
      for (final waypoint in plannedWaypoints) {
        expect(isDirectionAlignedDelta(waypoint - legStart), isTrue);
        legStart = waypoint;
      }

      var facingTransitions = 0;
      var previousFacing = game.facing;
      for (var frame = 0; frame < 600 && game.isMoving; frame++) {
        game.update(1 / 120);
        if (game.facing != previousFacing) {
          facingTransitions++;
          previousFacing = game.facing;
        }
        expect(game.cameraPosition.x, closeTo(game.playerPosition.x, 0.0001));
        expect(game.cameraPosition.y, closeTo(game.playerPosition.y, 0.0001));
      }

      expect(game.isMoving, isFalse);
      expect(facingTransitions, 4);
      expect(game.playerPosition.x, closeTo(target.x, 0.0001));
      expect(game.playerPosition.y, closeTo(target.y, 0.0001));
      expect(game.cameraPosition.x, closeTo(target.x, 0.0001));
      expect(game.cameraPosition.y, closeTo(target.y, 0.0001));
    },
  );

  testWithGame<NeuraGame>(
    'camera remains locked to the actor while it detours around a tree',
    NeuraGame.new,
    (game) async {
      const start = WorldPoint(3.5, 9.56);
      const target = WorldPoint(5.7, 9.56);
      await game.teleportTo(start);

      expect(game.requestMovement(target), isTrue);
      final plannedWaypointCount = game.movementWaypoints.length;
      expect(plannedWaypointCount, greaterThan(1));
      var legStart = Vector2(start.x, start.y);
      for (final waypoint in game.movementWaypoints) {
        expect(isDirectionAlignedDelta(waypoint - legStart), isTrue);
        legStart = waypoint;
      }
      var maximumActorDeviation = 0.0;
      var maximumCameraSeparation = 0.0;
      var facingTransitions = 0;
      var previousFacing = game.facing;
      for (var frame = 0; frame < 1200 && game.isMoving; frame++) {
        game.update(1 / 120);
        maximumActorDeviation = math.max(
          maximumActorDeviation,
          _lineDistance(game.playerPosition, start, target),
        );
        maximumCameraSeparation = math.max(
          maximumCameraSeparation,
          game.cameraPosition.distanceTo(game.playerPosition),
        );
        if (game.facing != previousFacing) {
          facingTransitions++;
          previousFacing = game.facing;
        }
      }

      expect(maximumActorDeviation, greaterThan(0.15));
      expect(maximumCameraSeparation, lessThan(0.0001));
      expect(facingTransitions, lessThanOrEqualTo(plannedWaypointCount * 4));
      expect(game.cameraPosition.x, closeTo(target.x, 0.0001));
      expect(game.cameraPosition.y, closeTo(target.y, 0.0001));
    },
  );
}

double _lineDistance(Vector2 point, WorldPoint start, WorldPoint end) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final numerator =
      (dy * point.x - dx * point.y + end.x * start.y - end.y * start.x).abs();
  return numerator / math.sqrt(dx * dx + dy * dy);
}
