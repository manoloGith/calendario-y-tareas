// Calendario y Tareas — punto de entrada.
//   app                      → ventana principal
//   app --widget=<tipo> ...  → widget de escritorio (calendar, agenda, tasks)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'core/bridge.dart';
import 'core/dates.dart';
import 'core/settings.dart';
import 'core/store.dart';
import 'desktop_widgets/desktop_widget.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'ui/tray.dart';
import 'ui/unlock_page.dart';

String? _arg(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('--$name=')) return a.substring(name.length + 3);
  }
  return null;
}

Future<void> main(List<String> args) async {
  final kind = _arg(args, 'widget');
  if (kind != null) {
    return runDesktopWidget(kind, _arg(args, 'vault') ?? Settings.load().vaultPath);
  }
  // Instancia única: si ya hay una ventana principal, se le pide que se muestre (o que abra el día pedido) y se sale.
  final newEventDay = DateTime.tryParse(_arg(args, 'new-event') ?? '');
  if (!acquireInstanceLock('app')) {
    try {
      Core.call('sys.allowForeground');
    } catch (_) {}
    requestFile().writeAsStringSync(jsonEncode({
      'action': newEventDay != null ? 'newEvent' : 'show',
      if (newEventDay != null) 'date': fmtCoreDate(newEventDay),
      'at': DateTime.now().toIso8601String(),
    }));
    exit(0);
  }
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1320, 860),
    minimumSize: Size(720, 520),
    center: true,
    title: 'Calendario y Tareas',
    titleBarStyle: TitleBarStyle.hidden,
  );
  unawaited(windowManager.waitUntilReadyToShow(options, () async {
    // En macOS se mantienen los botones nativos del semáforo; en Windows y Linux se dibujan en la barra lateral.
    if (!Platform.isMacOS) await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    // Linux: icono de la ventana (en Windows y macOS lo lleva el propio ejecutable).
    if (Platform.isLinux) await windowManager.setIcon('assets/icon/app_icon.png');
    await windowManager.show();
    await windowManager.focus();
  }));
  final store = AppStore(Settings.load());
  // Doble clic en un día de un widget con la app cerrada: se abre en ese día con el formulario de evento.
  if (newEventDay != null) store.requestNewEvent(newEventDay);
  appTray = AppTray(store);
  try {
    await appTray!.init();
  } catch (e) {
    debugPrint('bandeja del sistema no disponible: $e');
  }
  store.onBringToFront = () => appTray!.show();
  store.startAppHeartbeat();
  runApp(CalendarioApp(store: store));
}

final _lightTheme = buildTheme(Tokens.light);
final _darkTheme = buildTheme(Tokens.darkTokens);

class CalendarioApp extends StatelessWidget {
  const CalendarioApp({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => MaterialApp(
          title: 'Calendario y Tareas',
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: switch (store.settings.themeMode) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system },
          localizationsDelegates: const [SpanishMaterialDelegate()],
          navigatorKey: rootNavigatorKey,
          home: store.unlocked ? Shell(store: store) : UnlockPage(store: store),
        ),
      );
}
