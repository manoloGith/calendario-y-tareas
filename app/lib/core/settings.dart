// Preferencias locales no sensibles (tema, widgets, ruta de la bóveda). Nunca contiene datos ni contraseñas.
import 'dart:convert';
import 'dart:io';

import 'bridge.dart';

String? _dataDir;

/// Carpeta «datos» junto al ejecutable (modo portable). En macOS, junto al .app.
String portableDir() {
  var base = File(Platform.resolvedExecutable).parent;
  if (Platform.isMacOS && base.path.endsWith('Contents/MacOS')) base = base.parent.parent.parent;
  return '${base.path}${Platform.pathSeparator}datos';
}

/// Ubicación de versiones anteriores (carpeta del usuario).
String legacyDir() {
  final env = Platform.environment;
  if (Platform.isWindows) return '${env['APPDATA'] ?? env['USERPROFILE'] ?? '.'}\\CalendarioTareas';
  if (Platform.isMacOS) return '${env['HOME']}/Library/Application Support/CalendarioTareas';
  final xdg = env['XDG_DATA_HOME'];
  return '${(xdg != null && xdg.isNotEmpty) ? xdg : '${env['HOME']}/.local/share'}/calendario-tareas';
}

bool _writable(String dir) {
  try {
    Directory(dir).createSync(recursive: true);
    final probe = File('$dir${Platform.pathSeparator}.escritura');
    probe.writeAsStringSync('ok');
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

/// Carpeta de la app (ajustes, señales de los widgets y, por defecto, los datos).
/// Portable: junto al ejecutable. Si no se puede escribir ahí (p. ej. Archivos de programa), en la carpeta del usuario.
String appDataDir() => _dataDir ??= () {
      final forced = Platform.environment['CALENDARIO_DATA'];
      if (forced != null && forced.isNotEmpty && _writable(forced)) return forced;
      final p = portableDir();
      if (_writable(p)) {
        _migrateLegacy(p);
        return p;
      }
      final l = legacyDir();
      Directory(l).createSync(recursive: true);
      return l;
    }();

/// Si había datos de la versión anterior en la carpeta del usuario, se siguen usando (se pueden mover desde Ajustes).
void _migrateLegacy(String portable) {
  final target = File('$portable${Platform.pathSeparator}ajustes.json');
  if (target.existsSync()) return;
  final legacy = legacyDir();
  final oldSettings = File('$legacy${Platform.pathSeparator}ajustes.json');
  final oldVault = File('$legacy${Platform.pathSeparator}datos.calendario');
  if (!oldVault.existsSync()) return;
  Map<String, dynamic> j = {};
  try {
    if (oldSettings.existsSync()) j = jsonDecode(oldSettings.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {}
  j['vaultPath'] ??= oldVault.path;
  target.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(j));
}

String joinPath(String a, String b) => '$a${Platform.pathSeparator}$b';

/// Posición y tamaño de un widget en un monitor concreto (coordenadas lógicas).
class WidgetLayout {
  WidgetLayout(this.x, this.y, this.w, this.h);
  factory WidgetLayout.fromJson(Map<String, dynamic> j) =>
      WidgetLayout((j['x'] as num).toDouble(), (j['y'] as num).toDouble(), (j['w'] as num).toDouble(), (j['h'] as num).toDouble());
  final double x, y, w, h;
  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
}

class WidgetPrefs {
  WidgetPrefs({this.enabled = false, this.x, this.y, Map<String, WidgetLayout>? layouts, this.lastMonitor}) : layouts = layouts ?? {};
  factory WidgetPrefs.fromJson(Map<String, dynamic> j) => WidgetPrefs(
        enabled: j['enabled'] as bool? ?? false,
        x: (j['x'] as num?)?.toDouble(),
        y: (j['y'] as num?)?.toDouble(),
        layouts: {
          for (final e in ((j['layouts'] as Map?) ?? {}).entries)
            e.key as String: WidgetLayout.fromJson((e.value as Map).cast<String, dynamic>()),
        },
        lastMonitor: j['lastMonitor'] as String?,
      );
  bool enabled;
  /// Posición de versiones anteriores (sin tamaño ni monitor).
  double? x;
  double? y;
  /// Clave «monitor|resolución@escala» → posición y tamaño en ese monitor.
  final Map<String, WidgetLayout> layouts;
  String? lastMonitor;
  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'x': x,
        'y': y,
        'layouts': {for (final e in layouts.entries) e.key: e.value.toJson()},
        'lastMonitor': lastMonitor,
      };
}

class Settings {
  Settings._(this.file, Map<String, dynamic> j)
      : customFolder = j['customFolder'] as bool? ?? false,
        vaultPath = _resolveVault(j['vaultPath'] as String?, j['customFolder'] as bool? ?? false),
        widgetFont = j['widgetFont'] as String?,
        widgetFontScale = ((j['widgetFontScale'] as num?) ?? 1.0).toDouble(),
        trayHintShown = j['trayHintShown'] as bool? ?? false,
        themeMode = j['themeMode'] as String? ?? 'system',
        defaultCalendarId = j['defaultCalendarId'] as String?,
        defaultListId = j['defaultListId'] as String?,
        syncMinutes = (j['syncMinutes'] as num?)?.toInt() ?? 5,
        widgets = {
          for (final k in widgetKinds)
            k: WidgetPrefs.fromJson(((j['widgets'] as Map?)?[k] as Map?)?.cast<String, dynamic>() ?? {}),
        };

  static const widgetKinds = ['calendar', 'agenda', 'tasks'];

  final File file;
  String vaultPath;
  /// El usuario eligió expresamente otra carpeta (si no, mandan los datos de «datos/» junto a la app).
  bool customFolder;
  /// Fuente y tamaño del texto de los widgets (null = fuente del sistema).
  String? widgetFont;
  double widgetFontScale;
  bool trayHintShown;
  /// "system", "light" o "dark"
  String themeMode;
  String? defaultCalendarId;
  String? defaultListId;
  int syncMinutes;
  final Map<String, WidgetPrefs> widgets;

  static Settings load() {
    final f = File(joinPath(appDataDir(), 'ajustes.json'));
    Map<String, dynamic> j = {};
    try {
      if (f.existsSync()) j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {}
    return Settings._(f, j);
  }

  /// Vuelve a leer del disco (otro proceso, p. ej. un widget, puede haberlo cambiado).
  Settings reload() => load();

  void save() {
    final j = {
      'vaultPath': toStoredPath(vaultPath),
      'customFolder': customFolder,
      'widgetFont': widgetFont,
      'widgetFontScale': widgetFontScale,
      'trayHintShown': trayHintShown,
      'themeMode': themeMode,
      'defaultCalendarId': defaultCalendarId,
      'defaultListId': defaultListId,
      'syncMinutes': syncMinutes,
      'widgets': {for (final e in widgets.entries) e.key: e.value.toJson()},
    };
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(j));
    tmp.renameSync(file.path);
  }
}

/// Señal de vida de cada widget (para no abrirlo dos veces).
File heartbeatFile(String kind) => File(joinPath(appDataDir(), 'widget-$kind.alive'));

bool widgetAlive(String kind) {
  final f = heartbeatFile(kind);
  if (!f.existsSync()) return false;
  return DateTime.now().difference(f.lastModifiedSync()).inSeconds < 15;
}

/// Señal de vida de la ventana principal.
File appHeartbeatFile() => File(joinPath(appDataDir(), 'app.alive'));

bool appAlive() {
  final f = appHeartbeatFile();
  if (!f.existsSync()) return false;
  return DateTime.now().difference(f.lastModifiedSync()).inSeconds < 12;
}

/// Petición de un widget a la app principal (p. ej. abrir un día con el formulario de nuevo evento).
File requestFile() => File(joinPath(appDataDir(), 'peticion.json'));

/// Carpeta de la aplicación (donde está el ejecutable o, en macOS, el .app).
String appBaseDir() => File(portableDir()).parent.path;

/// Las rutas dentro de la carpeta de la app se guardan relativas: así siguen valiendo si el USB
/// cambia de letra de unidad o la carpeta se copia a otro equipo.
String toStoredPath(String path) {
  final base = appBaseDir() + Platform.pathSeparator;
  final cmp = Platform.isWindows ? path.toLowerCase().startsWith(base.toLowerCase()) : path.startsWith(base);
  return cmp ? path.substring(base.length) : path;
}

String fromStoredPath(String stored) {
  final isAbs = stored.startsWith('/') || stored.startsWith(r'\\') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(stored);
  return isAbs ? stored : joinPath(appBaseDir(), stored);
}

/// Datos a usar al arrancar:
///  1. la carpeta elegida expresamente por el usuario, si existe;
///  2. si no, «datos/datos.calendario» junto a la app, si existe;
///  3. si no, la ruta guardada (versiones anteriores), si existe;
///  4. si no, «datos/» junto a la app (allí se crearán).
String _resolveVault(String? stored, bool custom) {
  final configured = stored == null ? null : fromStoredPath(stored);
  final portable = joinPath(appDataDir(), 'datos.calendario');
  if (custom && configured != null && File(configured).existsSync()) return configured;
  if (File(portable).existsSync()) return portable;
  if (configured != null && File(configured).existsSync()) return configured;
  return portable;
}

RandomAccessFile? _lock;

/// Instancia única: devuelve false si otro proceso de esta app ya tiene `name` («app», «widget-tasks»…).
///  - Windows: mutex con nombre del sistema (vía núcleo Rust), propio de la carpeta de la app.
///  - macOS y Linux: bloqueo exclusivo sobre el primer byte de un archivo `.lock`.
/// Si no se puede comprobar, no se impide el arranque.
bool acquireInstanceLock(String name) {
  if (Platform.isWindows) {
    try {
      return Core.call('sys.singleInstance', {'key': '${appBaseDir()}|$name'}) as bool;
    } catch (_) {
      return true;
    }
  }
  RandomAccessFile raf;
  try {
    raf = File(joinPath(appDataDir(), '$name.lock')).openSync(mode: FileMode.append);
  } catch (_) {
    return true;
  }
  try {
    // Rango explícito: con «hasta el final» un archivo vacío no quedaba bloqueado.
    raf.lockSync(FileLock.exclusive, 0, 1);
    _lock = raf; // se mantiene abierto mientras viva el proceso
    return true;
  } catch (_) {
    raf.closeSync();
    return false;
  }
}

bool get holdsInstanceLock => _lock != null;
