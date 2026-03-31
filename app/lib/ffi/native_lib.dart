import 'dart:ffi';
import 'dart:io';

/// Single lazily-opened handle to the native AgriNav library.
///
/// Each FFI bridge class references this singleton instead of calling
/// [DynamicLibrary.open] on its own, so the `.so` / `.dll` is mapped into
/// the process exactly once.
final DynamicLibrary nativeLib = DynamicLibrary.open(
  Platform.isAndroid ? 'libagri_nav_ffi.so' : 'agri_nav_ffi.dll',
);
