// Icono en la bandeja del sistema. Cerrar la ventana la oculta aquí; «Salir» cierra la app y sus widgets.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/bridge.dart';
import '../core/store.dart';

class AppTray with TrayListener, WindowListener {
  AppTray(this.store);
  final AppStore store;
  bool active = false;

  Future<void> init() async {
    await trayManager.setIcon(Platform.isWindows ? 'assets/icon/app_icon.ico' : 'assets/icon/app_icon_64.png');
    await trayManager.setToolTip('Calendario y Tareas');
    await _menu();
    trayManager.addListener(this);
    windowManager.addListener(this);
    // Solo con el icono creado: si no, cerrar la ventana la dejaría oculta sin forma de recuperarla.
    await windowManager.setPreventClose(true);
    active = true;
  }

  Future<void> _menu() => trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: 'Abrir Calendario y Tareas'),
        MenuItem(key: 'event', label: 'Nuevo evento'),
        MenuItem(key: 'task', label: 'Nueva tarea'),
        MenuItem.separator(),
        MenuItem(key: 'lock', label: 'Bloquear'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Salir'),
      ]));

  Future<void> show() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  /// Cierra los widgets, quita el icono y termina el proceso.
  Future<void> quit() async {
    await store.stopWidgets();
    try {
      await trayManager.destroy();
    } catch (_) {}
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  @override
  void onTrayIconMouseDown() => show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'open':
        show();
      case 'event':
        store.requestNewEvent(DateTime.now());
        show();
      case 'task':
        store.selectScope(const TaskScope.smart('today'));
        store.requestNewTask = true;
        show();
      case 'lock':
        if (store.unlocked) store.lock();
      case 'quit':
        quit();
    }
  }

  /// La X de la ventana no cierra la app: la deja en la bandeja.
  @override
  void onWindowClose() async {
    await windowManager.hide();
    if (!store.settings.trayHintShown) {
      store.settings.trayHintShown = true;
      store.settings.save();
      try {
        await Core.callAsync('sys.notify', {
          'title': 'Calendario y Tareas sigue abierto',
          'body': 'Está en la bandeja del sistema. Para cerrarlo del todo, usa «Salir» en su menú.',
        });
      } catch (_) {}
    }
  }
}

/// Acceso global al icono de la bandeja (para «Salir» desde la ventana).
AppTray? appTray;

/// Clave del navegador principal (para abrir formularios desde la bandeja).
final rootNavigatorKey = GlobalKey<NavigatorState>();
