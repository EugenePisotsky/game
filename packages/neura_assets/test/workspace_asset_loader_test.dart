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
}
