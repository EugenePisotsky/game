import 'package:flutter_test/flutter_test.dart';
import 'package:neura_editor/editor_controller.dart';
import 'package:neura_assets/neura_assets.dart';
import 'package:neura_world/neura_world.dart';

void main() {
  const groundJ6 = GroundCatalogItem(
    id: 'ground.j6',
    name: 'Dry Grass — Clumps',
    collectionId: 'ground.j',
    role: 'overlay',
    stackable: true,
    description: '',
    assets: {},
  );
  const groundCatalog = GroundCatalog(collections: [], items: [groundJ6]);

  test('expanded terrain tools paint serializable ground types', () {
    final controller = EditorController(
      WorldDocument.filled(
        id: 'test',
        name: 'Test',
        width: GroundType.values.length,
        height: 1,
      ),
      groundCatalog: groundCatalog,
    );
    final tools = <EditorTool, GroundType>{
      EditorTool.grass: GroundType.grass,
      EditorTool.rockySoil: GroundType.rockySoil,
      EditorTool.darkEarth: GroundType.darkEarth,
      EditorTool.cobblestone: GroundType.cobblestone,
      EditorTool.woodPlanks: GroundType.woodPlanks,
      EditorTool.stonePavers: GroundType.stonePavers,
      EditorTool.dryGrass: GroundType.dryGrass,
    };

    var x = 0;
    for (final entry in tools.entries) {
      controller
        ..selectTool(entry.key)
        ..beginStroke()
        ..paint(CellCoordinate(x, 0))
        ..endStroke();
      expect(controller.document.groundAt(x, 0), entry.value);
      x++;
    }

    final restored = WorldDocument.fromJsonString(
      controller.document.toJsonString(),
    );
    expect([
      for (var cellX = 0; cellX < GroundType.values.length; cellX++)
        restored.groundAt(cellX, 0),
    ], GroundType.values);
  });

  test('road tool paints a semantic road without replacing terrain', () {
    final controller = EditorController(
      WorldDocument.filled(id: 'test', name: 'Test', width: 2, height: 1),
      groundCatalog: groundCatalog,
    );

    controller
      ..selectTool(EditorTool.road)
      ..beginStroke()
      ..paint(const CellCoordinate(0, 0))
      ..paint(const CellCoordinate(1, 0))
      ..endStroke();

    expect(controller.document.groundAt(0, 0), GroundType.grass);
    expect(controller.document.roadAt(0, 0), RoadType.dirt);
    expect(
      controller.document.roadTileVariantAt(0, 0),
      RoadTileVariant.endPositiveX,
    );
  });

  test('elevation brush locks one target level until tool changes', () {
    final controller = EditorController(
      WorldDocument.filled(id: 'test', name: 'Test', width: 1, height: 1),
      groundCatalog: groundCatalog,
    );

    controller
      ..selectTool(EditorTool.raiseElevation)
      ..beginStroke()
      ..paint(const CellCoordinate(0, 0))
      ..endStroke()
      ..beginStroke()
      ..paint(const CellCoordinate(0, 0))
      ..endStroke();
    expect(controller.document.elevationAt(0, 0), 1);

    controller
      ..selectTool(EditorTool.lowerElevation)
      ..beginStroke()
      ..paint(const CellCoordinate(0, 0))
      ..endStroke();
    expect(controller.document.elevationAt(0, 0), 0);

    controller.undo();
    expect(controller.document.elevationAt(0, 0), 1);
  });

  test('raise brush extends edges and requires a ring for a new tier', () {
    final world = WorldDocument.filled(
      id: 'test',
      name: 'Test',
      width: 7,
      height: 7,
    );
    for (var y = 2; y <= 4; y++) {
      for (var x = 2; x <= 4; x++) {
        world.setElevation(x, y, 1);
      }
    }
    final controller = EditorController(world, groundCatalog: groundCatalog);

    controller
      ..selectTool(EditorTool.raiseElevation)
      ..beginStroke()
      ..paint(const CellCoordinate(2, 3))
      ..endStroke()
      ..beginStroke()
      ..paint(const CellCoordinate(1, 3))
      ..endStroke();

    expect(controller.elevationBrushTarget, 1);
    expect(world.elevationAt(2, 3), 1);
    expect(world.elevationAt(1, 3), 1);

    controller
      ..selectTool(EditorTool.grass)
      ..selectTool(EditorTool.raiseElevation)
      ..beginStroke()
      ..paint(const CellCoordinate(1, 2))
      ..endStroke();
    expect(controller.elevationBrushTarget, 1);
    expect(world.elevationAt(1, 2), 1);

    controller
      ..selectTool(EditorTool.grass)
      ..selectTool(EditorTool.raiseElevation)
      ..beginStroke()
      ..paint(const CellCoordinate(3, 3))
      ..endStroke();

    expect(controller.elevationBrushTarget, 2);
    expect(world.elevationAt(3, 3), 2);
  });

  test('narrow elevation has no valid starting cell for another tier', () {
    final world = WorldDocument.filled(
      id: 'test',
      name: 'Test',
      width: 4,
      height: 4,
    );
    for (final cell in const [
      CellCoordinate(1, 1),
      CellCoordinate(2, 1),
      CellCoordinate(1, 2),
      CellCoordinate(2, 2),
    ]) {
      world.setElevation(cell.x, cell.y, 1);
    }
    final controller = EditorController(world, groundCatalog: groundCatalog)
      ..selectTool(EditorTool.raiseElevation)
      ..beginStroke()
      ..paint(const CellCoordinate(1, 1))
      ..endStroke();

    expect(controller.elevationBrushTarget, 1);
    expect(world.elevations.values, everyElement(1));
  });

  test('first click bridges through the cliff apron to a nearby plateau', () {
    final cases = <CellCoordinate, List<CellCoordinate>>{
      const CellCoordinate(-2, 6): const [
        CellCoordinate(-2, 5),
        CellCoordinate(-2, 6),
      ],
      const CellCoordinate(3, 3): const [
        CellCoordinate(2, 3),
        CellCoordinate(3, 3),
      ],
      const CellCoordinate(-4, 3): const [
        CellCoordinate(-3, 3),
        CellCoordinate(-4, 3),
      ],
      const CellCoordinate(-4, 6): const [
        CellCoordinate(-3, 4),
        CellCoordinate(-3, 5),
        CellCoordinate(-4, 5),
        CellCoordinate(-4, 6),
      ],
    };

    for (final entry in cases.entries) {
      final world = WorldDocument.filled(
        id: 'test',
        name: 'Test',
        width: 10,
        height: 8,
        originX: -5,
      );
      for (final cell in const [
        CellCoordinate(-2, 3),
        CellCoordinate(-1, 3),
        CellCoordinate(0, 3),
        CellCoordinate(1, 3),
        CellCoordinate(-2, 4),
        CellCoordinate(-1, 4),
      ]) {
        world.setElevation(cell.x, cell.y, 1);
      }
      final controller = EditorController(world, groundCatalog: groundCatalog)
        ..selectTool(EditorTool.raiseElevation)
        ..beginStroke()
        ..paint(entry.key)
        ..endStroke();

      expect(controller.elevationBrushTarget, 1, reason: '${entry.key}');
      for (final cell in entry.value) {
        expect(
          world.elevationAt(cell.x, cell.y),
          1,
          reason: '${entry.key} should bridge through $cell',
        );
      }
    }
  });

  test('extending from 1,5 fills the nearby plateau rectangle', () {
    final world = WorldDocument.filled(
      id: 'test',
      name: 'Test',
      width: 10,
      height: 8,
      originX: -5,
    );
    for (final cell in const [
      CellCoordinate(-2, 3),
      CellCoordinate(-1, 3),
      CellCoordinate(0, 3),
      CellCoordinate(1, 3),
      CellCoordinate(-2, 4),
      CellCoordinate(-1, 4),
    ]) {
      world.setElevation(cell.x, cell.y, 1);
    }
    final controller = EditorController(world, groundCatalog: groundCatalog)
      ..selectTool(EditorTool.raiseElevation)
      ..beginStroke()
      ..paint(const CellCoordinate(1, 5))
      ..endStroke();

    expect(controller.elevationBrushTarget, 1);
    for (var y = 3; y <= 5; y++) {
      for (var x = -1; x <= 1; x++) {
        expect(world.elevationAt(x, y), 1, reason: 'Expected ($x, $y) filled');
      }
    }
  });

  test('each new stroke refreshes extension topology without undo', () {
    final world = WorldDocument.filled(
      id: 'test',
      name: 'Test',
      width: 10,
      height: 8,
      originX: -5,
    );
    for (final cell in const [
      CellCoordinate(-2, 3),
      CellCoordinate(-1, 3),
      CellCoordinate(0, 3),
      CellCoordinate(1, 3),
      CellCoordinate(-2, 4),
      CellCoordinate(-1, 4),
    ]) {
      world.setElevation(cell.x, cell.y, 1);
    }
    final controller = EditorController(world, groundCatalog: groundCatalog)
      ..selectTool(EditorTool.raiseElevation)
      ..beginStroke()
      ..paint(const CellCoordinate(-2, 6))
      ..endStroke()
      ..beginStroke()
      ..paint(const CellCoordinate(-4, 6))
      ..endStroke();

    expect(controller.elevationBrushTarget, 1);
    for (var y = 4; y <= 6; y++) {
      for (var x = -4; x <= -1; x++) {
        expect(world.elevationAt(x, y), 1, reason: 'Expected ($x, $y) filled');
      }
    }
  });

  test('elevation brush fills an edge-connected path between samples', () {
    final controller = EditorController(
      WorldDocument.filled(id: 'test', name: 'Test', width: 4, height: 4),
      groundCatalog: groundCatalog,
    );

    controller
      ..selectTool(EditorTool.raiseElevation)
      ..beginStroke()
      ..paint(const CellCoordinate(0, 0))
      ..paint(const CellCoordinate(3, 3))
      ..endStroke();

    expect(controller.document.elevations.keys.toSet(), {
      const CellCoordinate(0, 0),
      const CellCoordinate(1, 0),
      const CellCoordinate(1, 1),
      const CellCoordinate(2, 1),
      const CellCoordinate(2, 2),
      const CellCoordinate(3, 2),
      const CellCoordinate(3, 3),
    });
    expect(controller.document.elevations.values, everyElement(1));
  });

  test('separate clicks in one elevation session finish a flat rectangle', () {
    final controller = EditorController(
      WorldDocument.filled(id: 'test', name: 'Test', width: 2, height: 2),
      groundCatalog: groundCatalog,
    )..selectTool(EditorTool.raiseElevation);

    for (final cell in const [
      CellCoordinate(0, 0),
      CellCoordinate(1, 0),
      CellCoordinate(0, 1),
      CellCoordinate(1, 1),
    ]) {
      controller
        ..beginStroke()
        ..paint(cell)
        ..endStroke();
    }

    expect(controller.document.elevations, hasLength(4));
    expect(controller.document.elevations.values, everyElement(1));
  });

  test('ground variant tools stack and expose editable rotation', () {
    final controller = EditorController(
      WorldDocument.filled(id: 'test', name: 'Test', width: 2, height: 1),
      groundCatalog: groundCatalog,
    );

    controller
      ..selectGroundItem(groundJ6)
      ..beginStroke()
      ..paint(const CellCoordinate(0, 0))
      ..endStroke();

    expect(controller.selectedTileLayers, hasLength(1));
    expect(controller.selectedTileLayer?.assetId, 'ground.j6');

    controller.rotateSelectedTileLayer(TileRotation.west);

    expect(controller.selectedTileLayer?.rotation, TileRotation.west);
    expect(controller.selectedGroundRotation, TileRotation.west);
    controller
      ..beginStroke()
      ..paint(const CellCoordinate(1, 0))
      ..endStroke();
    expect(
      controller.document.tileLayersAt(1, 0).last.rotation,
      TileRotation.west,
    );
    final restored = WorldDocument.fromJsonString(
      controller.document.toJsonString(),
    );
    expect(restored.tileLayersAt(0, 0).last.rotation, TileRotation.west);
  });

  test('new prop tools paint the matching decoration IDs', () {
    final controller = EditorController(
      WorldDocument.filled(id: 'test', name: 'Test', width: 10, height: 1),
      groundCatalog: groundCatalog,
    );
    final tools = <EditorTool, DecorationType>{
      EditorTool.leafyGroundcover: DecorationType.leafyGroundcover,
      EditorTool.clayPots: DecorationType.clayPots,
      EditorTool.woodenCrate: DecorationType.woodenCrate,
      EditorTool.stoneWell: DecorationType.stoneWell,
      EditorTool.woodenSign: DecorationType.woodenSign,
      EditorTool.fallenLog: DecorationType.fallenLog,
      EditorTool.firewoodPile: DecorationType.firewoodPile,
      EditorTool.stonePile: DecorationType.stonePile,
      EditorTool.hayBale: DecorationType.hayBale,
      EditorTool.closedChest: DecorationType.closedChest,
    };

    var x = 0;
    for (final entry in tools.entries) {
      controller
        ..selectTool(entry.key)
        ..beginStroke()
        ..paint(CellCoordinate(x, 0))
        ..endStroke();
      expect(controller.document.decorationAt(x, 0)?.type, entry.value);
      x++;
    }
  });

  test('rural tree rotation persists for the active brush', () {
    final controller = EditorController(
      WorldDocument.filled(id: 'test', name: 'Test', width: 2, height: 1),
      groundCatalog: groundCatalog,
    );

    controller
      ..selectTool(EditorTool.ruralTreeC2)
      ..beginStroke()
      ..paint(const CellCoordinate(0, 0))
      ..endStroke()
      ..rotateSelectedDecoration(TileRotation.west)
      ..beginStroke()
      ..paint(const CellCoordinate(1, 0))
      ..endStroke();

    expect(controller.document.decorationAt(0, 0)?.rotation, TileRotation.west);
    expect(
      controller.document.decorationAt(1, 0)?.type,
      DecorationType.ruralTreeC2,
    );
    expect(controller.document.decorationAt(1, 0)?.rotation, TileRotation.west);
  });
}
