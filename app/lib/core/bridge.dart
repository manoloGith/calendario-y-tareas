// Puente con el núcleo Rust mediante dart:ffi. Protocolo: JSON de entrada y de salida.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

typedef _AllocC = Pointer<Uint8> Function(IntPtr len);
typedef _AllocD = Pointer<Uint8> Function(int len);
typedef _DeallocC = Void Function(Pointer<Uint8> ptr, IntPtr len);
typedef _DeallocD = void Function(Pointer<Uint8> ptr, int len);
typedef _CallC = Pointer<Uint8> Function(Pointer<Uint8> req);
typedef _FreeC = Void Function(Pointer<Uint8> s);
typedef _FreeD = void Function(Pointer<Uint8> s);

/// Error devuelto por el núcleo. `code`: wrong_password, locked, not_found, invalid, offline, caldav, error.
class CoreError implements Exception {
  CoreError(this.message, this.code);
  final String message;
  final String code;
  bool get isOffline => code == 'offline';
  @override
  String toString() => message;
}

/// Ruta de la biblioteca nativa según la plataforma. Se puede forzar con CALENDARIO_CORE.
String coreLibraryPath() {
  final override = Platform.environment['CALENDARIO_CORE'];
  if (override != null && override.isNotEmpty) return override;
  // Android: la biblioteca va dentro del APK (jniLibs) y el sistema la encuentra por su nombre.
  if (Platform.isAndroid) return 'libcalendario_core.so';
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final sep = Platform.pathSeparator;
  final libName = Platform.isWindows ? 'calendario_core.dll' : (Platform.isMacOS ? 'libcalendario_core.dylib' : 'libcalendario_core.so');
  // Desarrollo (`flutter run` desde app/): usa la compilación de core/ si existe.
  final dev = File('${Directory.current.path}$sep..${sep}core${sep}target${sep}release$sep$libName');
  final bundled = Platform.isWindows ? '$exeDir$sep$libName' : (Platform.isMacOS ? '$exeDir/../Frameworks/$libName' : '$exeDir/lib/$libName');
  if (!File(bundled).existsSync() && dev.existsSync()) return dev.path;
  if (Platform.isWindows) return '$exeDir${sep}calendario_core.dll';
  if (Platform.isMacOS) {
    final inFrameworks = '$exeDir/../Frameworks/libcalendario_core.dylib';
    if (File(inFrameworks).existsSync()) return inFrameworks;
    return '$exeDir/libcalendario_core.dylib';
  }
  final inLib = '$exeDir/lib/libcalendario_core.so';
  if (File(inLib).existsSync()) return inLib;
  return '$exeDir/libcalendario_core.so';
}

class _Native {
  _Native._(DynamicLibrary lib)
      : alloc = lib.lookupFunction<_AllocC, _AllocD>('cal_alloc'),
        dealloc = lib.lookupFunction<_DeallocC, _DeallocD>('cal_dealloc'),
        call = lib.lookupFunction<_CallC, _CallC>('cal_call'),
        free = lib.lookupFunction<_FreeC, _FreeD>('cal_free');

  final _AllocD alloc;
  final _DeallocD dealloc;
  final Pointer<Uint8> Function(Pointer<Uint8>) call;
  final _FreeD free;

  // Una instancia por isolate (los campos estáticos de Dart son por isolate).
  static _Native? _instance;
  static _Native get instance => _instance ??= _Native._(DynamicLibrary.open(coreLibraryPath()));
}

String _rawCall(String request) {
  final n = _Native.instance;
  final bytes = utf8.encode(request);
  final ptr = n.alloc(bytes.length + 1);
  final view = ptr.asTypedList(bytes.length + 1);
  view.setAll(0, bytes);
  view[bytes.length] = 0;
  final out = n.call(ptr);
  n.dealloc(ptr, bytes.length + 1);
  var len = 0;
  while (out[len] != 0) {
    len++;
  }
  final resp = utf8.decode(out.asTypedList(len));
  n.free(out);
  return resp;
}

dynamic _decode(String resp) {
  final m = jsonDecode(resp) as Map<String, dynamic>;
  if (m['ok'] == true) return m['data'];
  throw CoreError(m['error'] as String? ?? 'Error desconocido', m['code'] as String? ?? 'error');
}

class Core {
  /// Llamada síncrona: para operaciones locales rápidas (milisegundos).
  static dynamic call(String method, [Map<String, dynamic> params = const {}]) {
    return _decode(_rawCall(jsonEncode({'method': method, 'params': params})));
  }

  /// Llamada en otro isolate: para red (CalDAV), copias de seguridad, diálogos y apertura de la bóveda.
  static Future<dynamic> callAsync(String method, [Map<String, dynamic> params = const {}]) async {
    final req = jsonEncode({'method': method, 'params': params});
    final resp = await Isolate.run(() => _rawCall(req));
    return _decode(resp);
  }
}
