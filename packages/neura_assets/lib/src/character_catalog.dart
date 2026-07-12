import 'dart:convert';

class CharacterCatalog {
  const CharacterCatalog({
    required this.frameWidth,
    required this.frameHeight,
    required this.directionRows,
    required this.characters,
  });

  final int frameWidth;
  final int frameHeight;
  final List<String> directionRows;
  final List<CharacterAsset> characters;

  CharacterAsset characterById(String id) =>
      characters.firstWhere((character) => character.id == id);

  int rowForDirection(String direction) {
    final row = directionRows.indexOf(direction);
    return row < 0 ? 0 : row;
  }

  factory CharacterCatalog.fromJsonString(String source) {
    final json = jsonDecode(source) as Map<String, Object?>;
    return CharacterCatalog(
      frameWidth: (json['frameWidth'] as num).toInt(),
      frameHeight: (json['frameHeight'] as num).toInt(),
      directionRows: [
        for (final value in json['directionRows'] as List<Object?>)
          value as String,
      ],
      characters: [
        for (final value in json['characters'] as List<Object?>)
          CharacterAsset.fromJson(value as Map<String, Object?>),
      ],
    );
  }
}

class CharacterAsset {
  const CharacterAsset({
    required this.id,
    required this.name,
    required this.idlePath,
    required this.idleFrames,
    required this.walkPath,
    required this.walkFrames,
    required this.renderScale,
    required this.pivotX,
    required this.pivotY,
  });

  final String id;
  final String name;
  final String idlePath;
  final int idleFrames;
  final String walkPath;
  final int walkFrames;
  final double renderScale;
  final double pivotX;
  final double pivotY;

  factory CharacterAsset.fromJson(Map<String, Object?> json) => CharacterAsset(
    id: json['id'] as String,
    name: json['name'] as String,
    idlePath: json['idle'] as String,
    idleFrames: (json['idleFrames'] as num).toInt(),
    walkPath: json['walk'] as String,
    walkFrames: (json['walkFrames'] as num).toInt(),
    renderScale: (json['renderScale'] as num? ?? 1).toDouble(),
    pivotX: (json['pivotX'] as num? ?? 0.5).toDouble(),
    pivotY: (json['pivotY'] as num? ?? 1).toDouble(),
  );
}
