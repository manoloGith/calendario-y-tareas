// Widgets de la pantalla de inicio de Android.
//
// Los widgets son nativos (Kotlin, en android_src/). No pueden abrir la base de datos cifrada, así que la app
// les deja una instantánea con lo que deben mostrar (widgets.json, en la carpeta privada de la app) cada vez
// que cambian los datos o los ajustes, y les avisa para que se redibujen. Al tocarlos abren la app con una
// acción («day:AAAA-MM-DD», «newEvent:AAAA-MM-DD», «newTask», «task:<id>», «open»).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/dates.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/store.dart';

class AndroidWidgets {
  static const _channel = MethodChannel('calendario/widgets');
  static Timer? _timer;
  static AppStore? _store;

  /// Conecta los widgets con la app: actualiza la instantánea al cambiar algo y atiende sus acciones.
  static void attach(AppStore store, void Function(String action) onAction) {
    if (!Platform.isAndroid) return;
    _store = store;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is String) onAction(call.arguments as String);
      return null;
    });
    store.addListener(_schedule);
    Settings.onSaved = _schedule;
    _schedule();
    _channel.invokeMethod<String>('initialAction').then((a) {
      if (a != null && a.isNotEmpty) onAction(a);
    }).catchError((_) {});
  }

  static void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 700), () => write());
  }

  /// Escribe la instantánea y pide a Android que redibuje los widgets.
  static Future<void> write() async {
    final store = _store;
    if (store == null || !store.unlocked) return;
    try {
      final s = Settings.load(); // ajustes al día (los sliders guardan al soltar)
      final now = DateTime.now();
      final today = dateOnly(now);

      // Mes actual (6 semanas desde el lunes) con puntos en los días con eventos.
      final month = startOfMonth(now);
      final start = monthGridStart(month);
      final dots = <String, String>{};
      for (final o in store.occurrences(start, addDays(start, 42))) {
        dots.putIfAbsent(fmtCoreDate(o.start), () => o.color);
      }
      final cells = [
        for (var i = 0; i < 42; i++)
          () {
            final d = addDays(start, i);
            final key = fmtCoreDate(d);
            return {'d': d.day, 'in': d.month == month.month, 'today': sameDay(d, today), 'dot': dots[key], 'date': key};
          }(),
      ];

      // Lista de eventos del periodo elegido en Ajustes › Widgets, agrupada por día.
      final aDays = s.widgetRanges['agenda'] ?? 3;
      final occ = store.occurrences(today, addDays(today, aDays));
      final agenda = <Map<String, dynamic>>[];
      String? lastDay;
      for (final o in occ) {
        final d = o.start.isBefore(today) ? today : dateOnly(o.start);
        final key = fmtCoreDate(d);
        if (aDays > 1 && key != lastDay) {
          final diff = d.difference(today).inDays;
          agenda.add({'h': diff == 0 ? 'HOY' : (diff == 1 ? 'MAÑANA' : shortDate(d).toUpperCase())});
          lastDay = key;
        }
        agenda.add({
          't': o.title,
          'time': o.allDay ? 'todo el día' : fmtTime(o.start),
          'c': o.color,
          'clip': o.attachments > 0,
          'date': key,
        });
      }

      // Tareas del periodo elegido (vencidas incluidas).
      final tDays = s.widgetRanges['tasks'] ?? 1;
      final List<TaskNode> nodes = tDays == 1
          ? store.tasks(const TaskScope.smart('today'))
          : store.tasksUpcoming(fmtCoreDate(addDays(today, tDays)));
      final tasks = [
        for (final n in nodes)
          {
            'id': n.task.id,
            't': n.task.title,
            'meta': [
              if (n.task.due != null || n.task.start != null) taskDates(n.task.start, n.task.due),
              n.listName,
              if (n.task.priority > 0) '!' * n.task.priority,
            ].join(' · '),
            'c': n.listColor,
            'overdue': n.overdue,
            'clip': n.attachments > 0,
          },
      ];

      String range(int d) => switch (d) { 1 => 'Hoy', 30 => 'Próximo mes', _ => 'Próximos $d días' };
      final snapshot = {
        'generated': now.toIso8601String(),
        'today': fmtCoreDate(today),
        'dark': switch (s.themeMode) { 'dark' => true, 'light' => false, _ => null },
        'transparency': s.widgetTransparency,
        'accent': s.widgetAccent,
        'text': s.widgetText,
        'month': {'title': '${monthNames[month.month - 1].toUpperCase()}  ${month.year}', 'cells': cells},
        'agenda': {'title': aDays == 1 ? 'Hoy, ${weekdayLong[today.weekday - 1]} ${today.day}' : range(aDays), 'items': agenda},
        'tasks': {'title': 'Tareas · ${range(tDays)}', 'count': nodes.length, 'items': tasks},
      };
      final f = File(joinPath(appDataDir(), 'widgets.json'));
      final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(snapshot));
      tmp.renameSync(f.path);
      await _channel.invokeMethod('update');
    } catch (_) {
      // Sin widgets en la pantalla de inicio (o sin el canal nativo): no pasa nada.
    }
  }
}
