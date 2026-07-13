import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neura_game/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sandbox-ready game opens a named bundled regression scene', (
    tester,
  ) async {
    await tester.pumpWidget(
      const NeuraApp(debugSceneName: 'grass_below_actor'),
    );
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    expect(find.text('ENVIRONMENT PROTOTYPE'), findsOneWidget);
    expect(find.textContaining('world 12.90, 16.80'), findsOneWidget);
    expect(find.textContaining('loaded 4'), findsOneWidget);
  });
}
