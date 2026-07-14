import 'rust/frb_generated.dart';

Future<void>? _initialization;

Future<void> initNeuraWorldRust({String? nativeLibraryPath}) =>
    _initialization ??= RustLib.init();
