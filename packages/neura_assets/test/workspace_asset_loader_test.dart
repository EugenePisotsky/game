import 'package:flutter_test/flutter_test.dart';
import 'package:neura_assets/neura_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'loads a generated environment image from the repository workspace',
    () async {
      final image = await loadGeneratedEnvironmentImage(
        'environment_generated/objects/tree/002_1.png',
      );
      expect(image.width, greaterThan(0));
      expect(image.height, greaterThan(0));
      image.dispose();
    },
  );

  test(
    'editor image proxy bounds decoded pixels but keeps source size',
    () async {
      final loaded = await loadWorkspaceEnvironmentImageForEditor(
        'environment_generated/objects/tree/002_1.png',
        maximumDimension: 64,
      );
      expect(loaded.image.width, lessThanOrEqualTo(64));
      expect(loaded.image.height, lessThanOrEqualTo(64));
      expect(loaded.sourceWidth, greaterThanOrEqualTo(loaded.image.width));
      expect(loaded.sourceHeight, greaterThanOrEqualTo(loaded.image.height));
      loaded.image.dispose();
    },
  );
}
