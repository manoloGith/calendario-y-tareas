// Ajusta los proyectos nativos que genera `flutter create` para esta app:
//  - empaqueta la biblioteca Rust (calendario_core) junto al ejecutable,
//  - arranca la ventana oculta hasta que window_manager la configura (sin parpadeos en los widgets),
//  - ventanas transparentes en Linux (esquinas redondeadas de los widgets),
//  - macOS: red, diálogos de archivos y biblioteca nativa (sin App Sandbox; app fuera de la App Store).
//
// Uso (desde app/):  dart run tool/patch_runners.dart
// Es idempotente: se puede ejecutar varias veces.
import 'dart:io';

int changes = 0;
int warnings = 0;

void patch(String path, String Function(String) f, String what) {
  final file = File(path);
  if (!file.existsSync()) return;
  final before = file.readAsStringSync();
  final after = f(before);
  if (after != before) {
    file.writeAsStringSync(after);
    changes++;
    stdout.writeln('  ✓ $path: $what');
  }
}

String replaceOnce(String s, String from, String to, String file) {
  if (s.contains(to)) return s;
  if (!s.contains(from)) {
    warnings++;
    stderr.writeln('  ! $file: no se encontró «${from.trim()}»; revisa este archivo a mano (ver README).');
    return s;
  }
  return s.replaceFirst(from, to);
}

void linux() {
  final cc = File('linux/runner/my_application.cc').existsSync() ? 'linux/runner/my_application.cc' : 'linux/my_application.cc';
  patch(cc, (s) {
    const marker = '// calendario: ventana transparente';
    if (s.contains(marker)) return s;
    // Barra de título tradicional: window_manager la oculta y dibujamos la nuestra.
    var r = s.replaceFirst('gboolean use_header_bar = TRUE;', 'gboolean use_header_bar = FALSE;');
    const snippet = '''
  $marker
  {
    GdkScreen* rgba_screen = gtk_window_get_screen(window);
    GdkVisual* visual = gdk_screen_get_rgba_visual(rgba_screen);
    if (visual != nullptr && gdk_screen_is_composited(rgba_screen)) {
      gtk_widget_set_visual(GTK_WIDGET(window), visual);
    }
    gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  }
''';
    final m = RegExp(r'  gtk_window_set_default_size\(window, \d+, \d+\);\n').firstMatch(r);
    if (m == null) {
      warnings++;
      stderr.writeln('  ! $cc: no se encontró gtk_window_set_default_size; la transparencia de los widgets no se aplicará.');
      return r;
    }
    r = r.replaceRange(m.end, m.end, snippet);
    r = r.replaceFirst('gdk_rgba_parse(&background_color, "#000000");', 'gdk_rgba_parse(&background_color, "#00000000");');
    // Plantillas antiguas: la ventana se mostraba antes de que window_manager la configurase.
    r = r.replaceFirst('  gtk_widget_show(GTK_WIDGET(window));\n', '  gtk_widget_realize(GTK_WIDGET(window));\n');
    return r;
  }, 'transparencia y barra de título');
  patch('linux/CMakeLists.txt', (s) {
    if (s.contains('calendario_core')) return s;
    return '''$s
# Biblioteca nativa del núcleo (Rust)
install(FILES "\${PROJECT_SOURCE_DIR}/../../core/target/release/libcalendario_core.so"
  DESTINATION "\${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
''';
  }, 'empaqueta libcalendario_core.so');
}

void windows() {
  patch('windows/runner/win32_window.cpp', (s) => s.replaceFirst('WS_OVERLAPPEDWINDOW | WS_VISIBLE', 'WS_OVERLAPPEDWINDOW'), 'ventana oculta al arrancar');
  patch('windows/runner/flutter_window.cpp', (s) {
    if (s.contains('// la muestra window_manager') || !s.contains('this->Show();')) return s;
    return s.replaceFirst('this->Show();', '// this->Show();  // la muestra window_manager');
  }, 'sin Show() automático');
  patch('windows/CMakeLists.txt', (s) {
    if (s.contains('calendario_core')) return s;
    return '''$s
# Biblioteca nativa del núcleo (Rust)
install(FILES "\${PROJECT_SOURCE_DIR}/../../core/target/release/calendario_core.dll"
  DESTINATION "\${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
''';
  }, 'empaqueta calendario_core.dll');
}

void macos() {
  patch('macos/Runner/MainFlutterWindow.swift', (s) {
    if (s.contains('hiddenWindowAtLaunch')) return s;
    var r = replaceOnce(s, 'import FlutterMacOS', 'import FlutterMacOS\nimport window_manager', 'MainFlutterWindow.swift');
    final idx = r.lastIndexOf('}');
    if (idx < 0) return r;
    r = '${r.substring(0, idx)}\n  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {\n    super.order(place, relativeTo: otherWin)\n    hiddenWindowAtLaunch()\n  }\n}\n';
    return r;
  }, 'ventana oculta al arrancar');
  for (final f in ['macos/Runner/DebugProfile.entitlements', 'macos/Runner/Release.entitlements']) {
    patch(f, (s) {
      var r = s.replaceAll(RegExp(r'<key>com\.apple\.security\.app-sandbox</key>\s*<true/>'), '<key>com.apple.security.app-sandbox</key>\n\t<false/>');
      if (!r.contains('com.apple.security.network.client')) {
        r = r.replaceFirst('</dict>', '\t<key>com.apple.security.network.client</key>\n\t<true/>\n</dict>');
      }
      return r;
    }, 'sin App Sandbox y con acceso a la red');
  }
}

void main() {
  if (!File('pubspec.yaml').existsSync()) {
    stderr.writeln('Ejecuta este script desde la carpeta app/.');
    exit(1);
  }
  if (Directory('linux').existsSync()) linux();
  if (Directory('windows').existsSync()) windows();
  if (Directory('macos').existsSync()) macos();
  stdout.writeln(changes == 0 ? 'Nada que cambiar (ya estaba aplicado).' : '$changes cambios aplicados.');
  if (warnings > 0) exit(2);
}
