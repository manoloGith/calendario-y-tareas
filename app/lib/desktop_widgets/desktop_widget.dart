// Widgets de escritorio: cada uno es un proceso ligero de la propia app, sin marco, anclado al escritorio
// y conectado a la misma base de datos cifrada (se refresca solo cuando cambian los datos).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/bridge.dart';
import '../core/dates.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/store.dart';
import '../ui/common.dart';
import '../ui/theme.dart';

const widgetSizes = {
  'calendar': Size(320, 320),
  'agenda': Size(640, 320),
  'tasks': Size(320, 460),
};

String widgetTitle(String kind) => 'CalendarioWidget-$kind';

Future<void> runDesktopWidget(String kind, String vaultPath) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final settings = Settings.load()..vaultPath = vaultPath;
  final prefs = settings.widgets[kind]!;
  final size = widgetSizes[kind] ?? const Size(320, 320);
  final options = WindowOptions(
    size: size,
    skipTaskbar: true,
    title: widgetTitle(kind),
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    backgroundColor: Colors.transparent,
  );
  unawaited(windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);
    await windowManager.setResizable(false);
    if (prefs.x != null && prefs.y != null) {
      await windowManager.setPosition(Offset(prefs.x!, prefs.y!));
    } else {
      final index = Settings.widgetKinds.indexOf(kind);
      await windowManager.setPosition(Offset(40.0 + index * 360, 60));
    }
    if (!Platform.isMacOS) {
      try {
        await windowManager.setAlwaysOnBottom(true);
      } catch (_) {}
    }
    await windowManager.show(inactive: true);
    // Windows y macOS: propietario = escritorio, así no lo oculta Win+D / «Mostrar escritorio».
    try {
      await Core.callAsync('sys.pinToDesktop', {'title': widgetTitle(kind)});
    } catch (_) {}
  }));

  final store = AppStore(settings, isWidget: true);
  String? error;
  try {
    await store.open(); // llavero del sistema
  } catch (_) {
    // Contraseña recibida por stdin desde la app principal.
    try {
      final line = await stdin.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 3));
      if (line.isNotEmpty) await store.open(password: line);
    } catch (e) {
      error = e is CoreError ? e.message : null;
    }
  }
  runApp(DesktopWidgetApp(store: store, kind: kind, initialError: error));
}

class DesktopWidgetApp extends StatefulWidget {
  const DesktopWidgetApp({super.key, required this.store, required this.kind, this.initialError});
  final AppStore store;
  final String kind;
  final String? initialError;
  @override
  State<DesktopWidgetApp> createState() => _DesktopWidgetAppState();
}

class _DesktopWidgetAppState extends State<DesktopWidgetApp> with WindowListener {
  Timer? heartbeat;
  Timer? saveTimer;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _beat();
    heartbeat = Timer.periodic(const Duration(seconds: 5), (_) => _beat());
  }

  void _beat() {
    try {
      heartbeatFile(widget.kind).writeAsStringSync('$pid');
      // Si se desactiva desde Ajustes, el widget se cierra solo.
      final s = Settings.load();
      if (!s.widgets[widget.kind]!.enabled) exit(0);
      if (s.themeMode != widget.store.settings.themeMode) setState(() => widget.store.settings.themeMode = s.themeMode);
    } catch (_) {}
  }

  @override
  void onWindowMoved() {
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 600), () async {
      final p = await windowManager.getPosition();
      final s = Settings.load();
      s.widgets[widget.kind]!
        ..x = p.dx
        ..y = p.dy;
      s.save();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    heartbeat?.cancel();
    saveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = switch (widget.store.settings.themeMode) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system };
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Tokens.light).copyWith(scaffoldBackgroundColor: Colors.transparent),
        darkTheme: buildTheme(Tokens.darkTokens).copyWith(scaffoldBackgroundColor: Colors.transparent),
        themeMode: mode,
        localizationsDelegates: const [SpanishMaterialDelegate()],
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: _Glass(
            child: widget.store.unlocked
                ? switch (widget.kind) {
                    'agenda' => _AgendaWidget(store: widget.store),
                    'tasks' => _TasksWidget(store: widget.store),
                    _ => _CalendarWidget(store: widget.store),
                  }
                : _LockedWidget(store: widget.store, error: widget.initialError),
          ),
        ),
      ),
    );
  }
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Container(
      decoration: BoxDecoration(
        color: (t.dark ? const Color(0xFF202024) : Colors.white).withValues(alpha: .9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: t.dark ? const Color(0x1AFFFFFF) : const Color(0xB3FFFFFF)),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

/// Cabecera arrastrable con menú (abrir la app, cerrar el widget).
class _Header extends StatelessWidget {
  const _Header({required this.store, required this.child, required this.kind});
  final AppStore store;
  final Widget child;
  final String kind;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: DragToMoveArea(child: SizedBox(height: 28, child: Align(alignment: Alignment.centerLeft, child: child)))),
        PopupMenuButton<String>(
          tooltip: 'Opciones del widget',
          iconSize: 16,
          padding: EdgeInsets.zero,
          icon: Icon(Icons.push_pin_outlined, color: context.tk.sec),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'open', child: Text('Abrir Calendario y Tareas')),
            PopupMenuItem(value: 'close', child: Text('Quitar del escritorio')),
          ],
          onSelected: (v) async {
            if (v == 'open') {
              await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
            } else {
              final s = Settings.load();
              s.widgets[kind]!.enabled = false;
              s.save();
              exit(0);
            }
          },
        ),
      ]);
}

class _LockedWidget extends StatefulWidget {
  const _LockedWidget({required this.store, this.error});
  final AppStore store;
  final String? error;
  @override
  State<_LockedWidget> createState() => _LockedWidgetState();
}

class _LockedWidgetState extends State<_LockedWidget> {
  final c = TextEditingController();
  late String? error = widget.error;
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        DragToMoveArea(child: Icon(Icons.lock_outline_rounded, size: 28, color: context.tk.sec)),
        const SizedBox(height: 10),
        const Text('Datos bloqueados', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        TextField(
          controller: c,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Contraseña'),
          onSubmitted: (v) async {
            try {
              await widget.store.open(password: v, remember: true);
            } on CoreError catch (e) {
              setState(() => error = e.message);
            }
          },
        ),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(error!, style: TextStyle(fontSize: 11, color: context.tk.danger))),
      ]);
}

Map<String, Color> _dots(AppStore store, DateTime month) {
  final start = monthGridStart(month);
  final dots = <String, Color>{};
  for (final o in store.occurrences(start, addDays(start, 42))) {
    dots.putIfAbsent(fmtCoreDate(o.start), () => o.colorValue);
  }
  return dots;
}

Widget _monthTitle(DateTime m, BuildContext context) => Text.rich(TextSpan(children: [
      TextSpan(text: monthNames[m.month - 1].toUpperCase(), style: const TextStyle(color: Color(0xFFFF3B30), fontWeight: FontWeight.w700, letterSpacing: .5)),
      TextSpan(text: '  ${m.year}', style: TextStyle(color: context.tk.sec)),
    ]), style: const TextStyle(fontSize: 13));

// ------------------------------------------------------------------ solo calendario

class _CalendarWidget extends StatefulWidget {
  const _CalendarWidget({required this.store});
  final AppStore store;
  @override
  State<_CalendarWidget> createState() => _CalendarWidgetState();
}

class _CalendarWidgetState extends State<_CalendarWidget> {
  DateTime month = startOfMonth(DateTime.now());
  @override
  Widget build(BuildContext context) => Column(children: [
        _Header(
          store: widget.store,
          kind: 'calendar',
          child: Row(children: [
            _monthTitle(month, context),
            const Spacer(),
            IconButton(tooltip: 'Mes anterior', iconSize: 16, onPressed: () => setState(() => month = addMonths(month, -1)), icon: const Icon(Icons.chevron_left_rounded)),
            IconButton(tooltip: 'Mes siguiente', iconSize: 16, onPressed: () => setState(() => month = addMonths(month, 1)), icon: const Icon(Icons.chevron_right_rounded)),
          ]),
        ),
        const SizedBox(height: 4),
        MiniMonth(month: month, showHeader: false, cell: 40, dots: _dots(widget.store, month), onPick: (_) {}),
      ]);
}

// ------------------------------------------------------------------ calendario + eventos

class _AgendaWidget extends StatefulWidget {
  const _AgendaWidget({required this.store});
  final AppStore store;
  @override
  State<_AgendaWidget> createState() => _AgendaWidgetState();
}

class _AgendaWidgetState extends State<_AgendaWidget> {
  DateTime month = startOfMonth(DateTime.now());
  DateTime day = dateOnly(DateTime.now());
  final quick = TextEditingController();

  @override
  void dispose() {
    quick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final store = widget.store;
    final today = sameDay(day, DateTime.now());
    final first = store.occurrences(day, addDays(day, 1));
    final second = today ? store.occurrences(addDays(day, 1), addDays(day, 2)) : <Occurrence>[];
    Widget item(Occurrence o) {
      final c = o.colorValue;
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: t.tint(c), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(child: Text(o.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(o.allDay ? 'todo el día' : fmtTime(o.start), style: TextStyle(fontSize: 12, color: t.sec)),
        ]),
      );
    }

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 7 * 33,
        child: Column(children: [
          _Header(store: store, kind: 'agenda', child: _monthTitle(month, context)),
          MiniMonth(
            month: month,
            showHeader: false,
            cell: 33,
            selected: day,
            onPick: (d) => setState(() {
              day = d;
              if (d.month != month.month) month = startOfMonth(d);
            }),
          ),
        ]),
      ),
      Container(width: 1, margin: const EdgeInsets.symmetric(horizontal: 16), color: t.border),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DragToMoveArea(
            child: SizedBox(
              height: 28,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(today ? 'Hoy, ${weekdayLong[day.weekday - 1]} ${day.day}' : capitalize(longDate(day)), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView(children: [
              if (first.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('Sin eventos', style: TextStyle(color: t.faint))),
              ...first.map(item),
              if (second.isNotEmpty) ...[
                Padding(padding: const EdgeInsets.only(top: 4, bottom: 6), child: Text('MAÑANA', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.sec))),
                ...second.map(item),
              ],
            ]),
          ),
          TextField(
            controller: quick,
            style: const TextStyle(fontSize: 12.5),
            decoration: const InputDecoration(hintText: 'Añadir evento… «Cena con Ana el viernes a las 21h»', prefixIcon: Icon(Icons.add_rounded, size: 16)),
            onSubmitted: (v) {
              final cal = store.defaultCalendarId;
              if (v.trim().isEmpty || cal == null) return;
              try {
                store.mutate('events.quickAdd', {'text': v.trim(), 'calendarId': cal});
                quick.clear();
              } catch (e) {
                showError(context, e);
              }
            },
          ),
        ]),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ tareas

class _TasksWidget extends StatefulWidget {
  const _TasksWidget({required this.store});
  final AppStore store;
  @override
  State<_TasksWidget> createState() => _TasksWidgetState();
}

class _TasksWidgetState extends State<_TasksWidget> {
  final quick = TextEditingController();
  @override
  void dispose() {
    quick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final store = widget.store;
    final nodes = store.tasks(const TaskScope.smart('today'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Header(
        store: store,
        kind: 'tasks',
        child: Row(children: [
          Container(width: 24, height: 24, decoration: const BoxDecoration(color: Color(0xFF007AFF), shape: BoxShape.circle), child: const Icon(Icons.check_rounded, size: 14, color: Colors.white)),
          const SizedBox(width: 8),
          const Text('Tareas · Hoy', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('${nodes.length}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF007AFF))),
          const SizedBox(width: 4),
        ]),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: nodes.isEmpty
            ? Center(child: Text('Nada pendiente para hoy', style: TextStyle(color: t.faint)))
            : ListView(children: [
                for (final n in nodes)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      CheckCircle(color: n.color, done: n.task.completed, label: n.task.title, onTap: () => store.mutate('tasks.toggle', {'id': n.task.id})),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(n.task.title),
                          Text(
                            [
                              if (n.task.due != null) relativeDue(n.task.due!),
                              n.listName,
                              if (n.task.priority > 0) '!' * n.task.priority,
                            ].join(' · '),
                            style: TextStyle(fontSize: 11, color: n.overdue ? t.danger : t.sec),
                          ),
                        ]),
                      ),
                    ]),
                  ),
              ]),
      ),
      const SizedBox(height: 6),
      TextField(
        controller: quick,
        style: const TextStyle(fontSize: 12.5),
        decoration: const InputDecoration(hintText: 'Nueva tarea', prefixIcon: Icon(Icons.add_rounded, size: 16)),
        onSubmitted: (v) {
          final list = store.defaultListId;
          if (v.trim().isEmpty || list == null) return;
          try {
            // Sin fecha explícita, la tarea se crea para hoy (es el widget «Hoy»).
            final r = store.mutate('tasks.quickAdd', {'text': v.trim(), 'listId': list}) as Map<String, dynamic>;
            if (r['due'] == null) {
              final task = TaskData.fromJson(r)..due = fmtCoreDate(DateTime.now());
              store.mutate('tasks.save', {'task': task.toJson()});
            }
            quick.clear();
          } catch (e) {
            showError(context, e);
          }
        },
      ),
    ]);
  }
}
