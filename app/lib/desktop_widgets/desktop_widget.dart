// Widgets de escritorio: cada uno es un proceso ligero de la propia app, sin marco, anclado al escritorio
// y conectado a la misma base de datos cifrada (se refresca solo cuando cambian los datos).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
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

final _themes = <String, ThemeData>{};

/// Temas por fuente (se crean una vez: reconstruirlos en cada refresco provocaba repintados).
ThemeData _theme(bool dark, String? font) => _themes.putIfAbsent(
      '$dark|${font ?? ''}',
      () => buildTheme(dark ? Tokens.darkTokens : Tokens.light, fontFamily: font).copyWith(scaffoldBackgroundColor: Colors.transparent),
    );

/// Clave de un monitor: nombre + resolución física + escala (sirve también al cambiar de equipo con un USB).
String monitorKey(Display d) {
  final scale = (d.scaleFactor ?? 1).toDouble();
  final w = (d.size.width * scale).round();
  final h = (d.size.height * scale).round();
  return '${d.name ?? d.id}|${w}x$h@${(scale * 100).round()}%';
}

Rect visibleRect(Display d) => (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size);

/// Monitor que contiene el centro de `r` (o el principal).
Display displayFor(Rect r, List<Display> all, Display primary) {
  for (final d in all) {
    if (visibleRect(d).contains(r.center)) return d;
  }
  return primary;
}

/// Mantiene el rectángulo dentro del área visible del monitor.
Rect clampInto(Rect r, Rect area) {
  final w = r.width.clamp(80.0, area.width);
  final h = r.height.clamp(80.0, area.height);
  final x = r.left.clamp(area.left, area.right - w);
  final y = r.top.clamp(area.top, area.bottom - h);
  return Rect.fromLTWH(x, y, w, h);
}

/// Posición y tamaño iniciales: lo guardado para un monitor conectado o, si no hay, un tamaño adaptado a la resolución.
Future<Rect> initialBounds(String kind, WidgetPrefs prefs) async {
  final base = widgetSizes[kind] ?? const Size(320, 320);
  List<Display> displays = [];
  Display? primary;
  try {
    displays = await screenRetriever.getAllDisplays();
    primary = await screenRetriever.getPrimaryDisplay();
  } catch (_) {}
  if (primary == null) return Offset(40.0 + Settings.widgetKinds.indexOf(kind) * 360, 60) & base;
  final keys = {for (final d in displays) monitorKey(d): d};
  // 1) el último monitor usado, si está conectado; 2) cualquier monitor conectado con medidas guardadas
  for (final key in [?prefs.lastMonitor, ...prefs.layouts.keys]) {
    final d = keys[key];
    final l = prefs.layouts[key];
    if (d != null && l != null) return clampInto(Rect.fromLTWH(l.x, l.y, l.w, l.h), visibleRect(d));
  }
  // 3) monitor nuevo: tamaño base (ya escalado por DPI) ajustado a la altura disponible de la pantalla
  final area = visibleRect(primary);
  final factor = (area.height / 1000).clamp(0.85, 1.8);
  final size = Size(base.width * factor, base.height * factor);
  var x = area.left + 40;
  for (final k in Settings.widgetKinds.take(Settings.widgetKinds.indexOf(kind))) {
    x += (widgetSizes[k]!.width * factor) + 24;
  }
  var pos = Offset(x, area.top + 60);
  if (prefs.x != null && prefs.y != null) pos = Offset(prefs.x!, prefs.y!); // versiones anteriores
  return clampInto(pos & size, area);
}

Future<void> runDesktopWidget(String kind, String vaultPath) async {
  // Un solo proceso por tipo de widget.
  if (!acquireInstanceLock('widget-$kind')) exit(0);
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final settings = Settings.load()..vaultPath = vaultPath;
  final prefs = settings.widgets[kind]!;
  final base = widgetSizes[kind] ?? const Size(320, 320);
  final bounds = await initialBounds(kind, prefs);
  final options = WindowOptions(
    size: bounds.size,
    minimumSize: Size(base.width * .6, base.height * .6),
    maximumSize: Size(base.width * 3, base.height * 3),
    skipTaskbar: true,
    title: widgetTitle(kind),
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    backgroundColor: Colors.transparent,
  );
  unawaited(windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);
    await windowManager.setResizable(true);
    await windowManager.setBounds(bounds);
    // Linux: siempre al fondo. En Windows NO se usa: window_manager lo reaplica en cada cambio de posición,
    // lo que provocaba parpadeos y bloqueaba el arrastre; allí el anclaje lo hace el núcleo (pinToDesktop).
    if (Platform.isLinux) {
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
    heartbeat = Timer.periodic(const Duration(seconds: 3), (_) => _beat());
  }

  void _beat() {
    try {
      heartbeatFile(widget.kind).writeAsStringSync('$pid');
      // Si se desactiva desde Ajustes, el widget se cierra solo.
      final s = Settings.load();
      if (!s.widgets[widget.kind]!.enabled) exit(0);
      final cur = widget.store.settings;
      if (s.themeMode != cur.themeMode || s.widgetFont != cur.widgetFont || s.widgetFontScale != cur.widgetFontScale) {
        setState(() {
          cur.themeMode = s.themeMode;
          cur.widgetFont = s.widgetFont;
          cur.widgetFontScale = s.widgetFontScale;
        });
      }
    } catch (_) {}
  }

  @override
  void onWindowMoved() => _saveLayout();

  @override
  void onWindowResized() => _saveLayout();

  void _saveLayout() {
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 600), () async {
      final b = await windowManager.getBounds();
      String key = 'principal';
      try {
        final all = await screenRetriever.getAllDisplays();
        final primary = await screenRetriever.getPrimaryDisplay();
        key = monitorKey(displayFor(b, all, primary));
      } catch (_) {}
      final s = Settings.load();
      final p = s.widgets[widget.kind]!;
      p.layouts[key] = WidgetLayout(b.left, b.top, b.width, b.height);
      p.lastMonitor = key;
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
    // El MaterialApp no se reconstruye con cada refresco de datos: solo el contenido del widget.
    final font = widget.store.settings.widgetFont;
    final scale = widget.store.settings.widgetFontScale.clamp(0.7, 1.6);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(false, font),
      darkTheme: _theme(true, font),
      themeMode: mode,
      themeAnimationDuration: Duration.zero,
      localizationsDelegates: const [SpanishMaterialDelegate()],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale.toDouble())),
        child: child!,
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: DragToResizeArea(
          resizeEdgeSize: 6,
          child: _Scaled(
            base: widgetSizes[widget.kind] ?? const Size(320, 320),
            child: _Glass(
          child: ListenableBuilder(
            listenable: widget.store,
            builder: (context, _) => widget.store.unlocked
                ? switch (widget.kind) {
                    'agenda' => _AgendaWidget(store: widget.store),
                    'tasks' => _TasksWidget(store: widget.store),
                    _ => _CalendarWidget(store: widget.store),
                  }
                : _LockedWidget(store: widget.store, error: widget.initialError),
          ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Escala el contenido de forma uniforme según el tamaño de la ventana (diseñado para `base`).
class _Scaled extends StatelessWidget {
  const _Scaled({required this.base, required this.child});
  final Size base;
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final s = (c.maxWidth / base.width < c.maxHeight / base.height ? c.maxWidth / base.width : c.maxHeight / base.height).clamp(0.5, 3.0);
        return FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(width: c.maxWidth / s, height: c.maxHeight / s, child: child),
        );
      });
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
      child: Stack(children: [
        Positioned.fill(child: Padding(padding: const EdgeInsets.all(16), child: child)),
        // Asa para cambiar el tamaño (también se puede desde cualquier borde).
        Positioned(
          right: 4,
          bottom: 4,
          child: Tooltip(
            message: 'Arrastra para cambiar el tamaño',
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeDownRight,
              child: GestureDetector(
                onPanStart: (_) => windowManager.startResizing(ResizeEdge.bottomRight),
                child: SizedBox(width: 16, height: 16, child: CustomPaint(painter: _GripPainter(t.faint.withValues(alpha: .6)))),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _GripPainter extends CustomPainter {
  _GripPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (final o in [4.0, 8.0, 12.0]) {
      canvas.drawLine(Offset(size.width - 2, size.height - 2 - o), Offset(size.width - 2 - o, size.height - 2), p);
    }
  }

  @override
  bool shouldRepaint(_GripPainter old) => old.color != color;
}

/// Doble clic en un día: abre la app en ese día con el formulario de nuevo evento.
Future<void> openAppOn(DateTime day) async {
  try {
    Core.call('sys.allowForeground');
  } catch (_) {}
  if (appAlive()) {
    requestFile().writeAsStringSync(jsonEncode({'action': 'newEvent', 'date': fmtCoreDate(day), 'at': DateTime.now().toIso8601String()}));
  } else {
    await Process.start(Platform.resolvedExecutable, ['--new-event=${fmtCoreDate(day)}'], mode: ProcessStartMode.detached);
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
              try {
                Core.call('sys.allowForeground');
              } catch (_) {}
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
        Tooltip(
          message: 'Doble clic en un día para añadir un evento',
          waitDuration: const Duration(seconds: 1),
          child: MiniMonth(month: month, showHeader: false, cell: 40, dots: _dots(widget.store, month), onPick: (_) {}, onDoubleTap: openAppOn),
        ),
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
            onDoubleTap: openAppOn,
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
