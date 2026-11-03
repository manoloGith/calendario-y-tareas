// Preferencias locales no sensibles (tema, widgets, ruta de la bóveda). Nunca contiene datos ni contraseñas.
import 'dart:convert';
import 'dart:io';

String appDataDir() {
  final env = Platform.environment;
  String base;
  if (Platform.isWindows) {
    base = '${env['APPDATA'] ?? env['USERPROFILE'] ?? '.'}\\CalendarioTareas';
  } else if (Platform.isMacOS) {
    base = '${env['HOME']}/Library/Application Support/CalendarioTareas';
  } else {
    final xdg = env['XDG_DATA_HOME'];
    base = '${(xdg != null && xdg.isNotEmpty) ? xdg : '${env['HOME']}/.local/share'}/calendario-tareas';
  }
  Directory(base).createSync(recursive: true);
  return base;
}

String joinPath(String a, String b) => '$a${Platform.pathSeparator}$b';

class WidgetPrefs {
  WidgetPrefs({this.enabled = false, this.x, this.y});
  factory WidgetPrefs.fromJson(Map<String, dynamic> j) =>
      WidgetPrefs(enabled: j['enabled'] as bool? ?? false, x: (j['x'] as num?)?.toDouble(), y: (j['y'] as num?)?.toDouble());
  bool enabled;
  double? x;
  double? y;
  Map<String, dynamic> toJson() => {'enabled': enabled, 'x': x, 'y': y};
}

class Settings {
  Settings._(this.file, Map<String, dynamic> j)
      : vaultPath = j['vaultPath'] as String? ?? joinPath(appDataDir(), 'datos.calendario'),
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
      'vaultPath': vaultPath,
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
