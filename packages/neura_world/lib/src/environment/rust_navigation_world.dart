import '../rust/api.dart';

class RustNavigationWorld {
  RustNavigationWorld._(this._handle, this.snapshot);

  final int _handle;
  NativeNavigationSnapshot snapshot;
  bool _closed = false;

  static Future<RustNavigationWorld> create(
    NativeNavigationWorldInput input,
  ) async {
    final created = await nativeNavigationWorldCreate(input: input);
    return RustNavigationWorld._(created.handle, created.snapshot);
  }

  Future<NativeNavigationSnapshot> replace(
    NativeNavigationWorldInput input,
  ) async {
    _ensureOpen();
    return snapshot = await nativeNavigationWorldReplace(
      handle: _handle,
      input: input,
    );
  }

  Future<NativeNavigationPathResult> findPath({
    required NativeNavigationPoint start,
    required NativeNavigationPoint destination,
  }) {
    _ensureOpen();
    return nativeNavigationWorldFindPath(
      handle: _handle,
      start: start,
      destination: destination,
    );
  }

  void close() {
    if (_closed) return;
    nativeNavigationWorldClose(handle: _handle);
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The native navigation world is closed.');
  }
}
