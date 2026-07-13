import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:neura_editor/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('editor opens a named scene with its relevant stack selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      const NeuraEditorApp(debugSceneName: 'overlapping_selection'),
    );
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    expect(find.text('NEURA ENVIRONMENT DESIGNER'), findsOneWidget);
    expect(find.text('4 objects selected'), findsOneWidget);
    expect(find.text('Build release'), findsOneWidget);
    expect(find.textContaining('loaded'), findsWidgets);
  });
}
