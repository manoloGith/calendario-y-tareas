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
import '../ui/attachments.dart';
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
ThemeData _theme(bool dark, String? font, String? accent) => _themes.putIfAbsent('$dark|${font ?? ''}|${accent ?? ''}', () {
      var tokens = dark ? Tokens.darkTokens : Tokens.light;
      if (accent != null) tokens = tokens.withAccent(parseHex(accent));
      return buildTheme(tokens, fontFamily: font).copyWith(scaffoldBackgroundColor: Colors.transparent);
    });

/// Casillas del mes que llenan exactamente el espacio: 7 columnas de ancho y 6 filas más la de letras.
(double, double) _monthCells(BuildContext context, BoxConstraints c) {
  final letters = 18 * MediaQuery.textScalerOf(context).scale(1) + 10; // fila L M X J V S D + separación (con margen)
  final w = (c.maxWidth / 7).floorToDouble();
  final h = ((c.maxHeight - letters) / 6).floorToDouble().clamp(12.0, 400.0);
  return (w, h);
}

/// Tamaño de texto de una parte del widget (Ajustes › Widgets).
double _ts(AppStore store, String key) => (store.settings.widgetText[key] ?? 1.0).clamp(0.7, 2.0);

/// Color de acento del widget, o el color propio del calendario (rojo) si no se ha elegido.
Color _accentOr(AppStore store, Color fallback) => store.settings.widgetAccent == null ? fallback : parseHex(store.settings.widgetAccent);

/// Aplica un tamaño de texto a una parte del widget.
class _TS extends StatelessWidget {
  const _TS(this.scale, this.child);
  final double scale;
  final Widget child;
  @override
  Widget build(BuildContext context) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child);
}

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
    // Tareas puede encogerse más en altura (es una lista con scroll).
    minimumSize: Size(base.width * .6, kind == 'tasks' ? 130 : base.height * .6),
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
      if (s.widgetSignature != cur.widgetSignature) {
        s.vaultPath = cur.vaultPath;
        setState(() => widget.store.settings = s);
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
    final st = widget.store.settings;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(false, st.widgetFont, st.widgetAccent),
      darkTheme: _theme(true, st.widgetFont, st.widgetAccent),
      themeMode: mode,
      themeAnimationDuration: Duration.zero,
      localizationsDelegates: const [SpanishMaterialDelegate()],
      home: Scaffold(
        backgroundColor: Colors.transparent,
        // Sin escalar el contenido: al cambiar el tamaño de la ventana hay más o menos espacio real.
        // El tamaño del texto se elige en Ajustes › Widgets.
        body: DragToResizeArea(
          resizeEdgeSize: 6,
          child: _Glass(
            transparency: st.widgetTransparency,
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
    );
  }
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.transparency = 10});
  final Widget child;
  /// Transparencia del fondo en % (0 = opaco).
  final int transparency;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final alpha = (1 - transparency / 100).clamp(0.1, 1.0);
    return Container(
      decoration: BoxDecoration(
        color: (t.dark ? const Color(0xFF202024) : Colors.white).withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: (t.dark ? Colors.white : Colors.white).withValues(alpha: t.dark ? .10 * alpha : .7 * alpha)),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

/// Pide a la ventana principal una acción (si no está abierta, la abre con el argumento equivalente).
Future<void> _askApp(Map<String, dynamic> request, List<String> args) async {
  try {
    Core.call('sys.allowForeground');
  } catch (_) {}
  if (appAlive()) {
    requestFile().writeAsStringSync(jsonEncode({...request, 'at': DateTime.now().toIso8601String()}));
  } else {
    await Process.start(Platform.resolvedExecutable, args, mode: ProcessStartMode.detached);
  }
}

/// Doble clic en un día o «+» de eventos: abre la app con el formulario de nuevo evento ese día.
Future<void> openAppOn(DateTime day) =>
    _askApp({'action': 'newEvent', 'date': fmtCoreDate(day)}, ['--new-event=${fmtCoreDate(day)}']);

/// «+» de tareas: abre la app con una tarea nueva lista para escribir.
Future<void> openAppNewTask() => _askApp({'action': 'newTask'}, ['--new-task']);

/// Cabecera arrastrable: título (crece con la letra en lugar de recortarse), botones opcionales y menú.
class _Header extends StatelessWidget {
  const _Header({required this.kind, required this.child, this.onAdd, this.addTooltip, this.actions = const []});
  final String kind;
  final Widget child;
  final VoidCallback? onAdd;
  final String? addTooltip;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(
        child: GestureDetector(
          onSecondaryTapDown: (d) => _widgetMenu(context, d.globalPosition, kind),
          child: DragToMoveArea(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 30),
              child: Align(alignment: Alignment.centerLeft, child: child),
            ),
          ),
        ),
      ),
      ...actions,
      if (onAdd != null)
        Tooltip(
          message: addTooltip ?? 'Añadir',
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onAdd,
            child: Container(
              width: 26,
              height: 26,
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle),
              child: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
            ),
          ),
        ),
    ]);
  }
}

/// Menú del widget con clic derecho en la cabecera: abrir la app o quitar el widget.
Future<void> _widgetMenu(BuildContext context, Offset pos, String kind) async {
  final v = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
    items: const [
      PopupMenuItem(value: 'open', child: Text('Abrir Calendario y Tareas')),
      PopupMenuItem(value: 'close', child: Text('Quitar del escritorio')),
    ],
  );
  if (v == 'open') {
    await _askApp({'action': 'show'}, const []);
  } else if (v == 'close') {
    final s = Settings.load();
    s.widgets[kind]!.enabled = false;
    s.save();
    exit(0);
  }
}

/// Clip para abrir los adjuntos de un evento o tarea (uno: se abre directamente; varios: menú).
class _Clip extends StatelessWidget {
  const _Clip({required this.ownerId, required this.count});
  final String ownerId;
  final int count;

  Future<void> _open(BuildContext context, Attachment a) async {
    try {
      final target = (await Core.callAsync('attachments.open', {'id': a.id})) as String;
      await openExternal(target);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  List<Attachment> _list() =>
      (Core.call('attachments.list', {'ownerId': ownerId}) as List).map((a) => Attachment.fromJson(a as Map<String, dynamic>)).toList();

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final icon = Icon(Icons.attach_file_rounded, size: 16, color: t.sec);
    if (count == 1) {
      return IconButton(
        tooltip: 'Abrir adjunto',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        onPressed: () {
          final l = _list();
          if (l.isNotEmpty) _open(context, l.first);
        },
        icon: icon,
      );
    }
    return PopupMenuButton<Attachment>(
      tooltip: '$count adjuntos',
      padding: EdgeInsets.zero,
      icon: Badge(label: Text('$count'), backgroundColor: t.accent, child: icon),
      itemBuilder: (_) => [
        for (final a in _list())
          PopupMenuItem(
            value: a,
            child: Row(children: [
              Icon(switch (a.kind) { 'file' => Icons.description_outlined, 'folder' => Icons.folder_outlined, _ => Icons.link_rounded }, size: 16),
              const SizedBox(width: 8),
              Flexible(child: Text(a.name, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
      onSelected: (a) => _open(context, a),
    );
  }
}

/// Etiqueta del periodo de la lista.
String _rangeLabel(int days) => switch (days) { 1 => 'Hoy', 30 => 'Próximo mes', _ => 'Próximos $days días' };

/// Cabecera de día en las listas: «HOY», «MAÑANA», «JUE 6 NOV».
String _dayHeader(DateTime d) {
  final diff = dateOnly(d).difference(dateOnly(DateTime.now())).inDays;
  if (diff == 0) return 'HOY';
  if (diff == 1) return 'MAÑANA';
  return shortDate(d).toUpperCase();
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

Widget _monthTitle(DateTime m, BuildContext context, [Color color = const Color(0xFFFF3B30)]) => Text.rich(
      TextSpan(children: [
        TextSpan(text: monthNames[m.month - 1].toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.w700, letterSpacing: .5)),
        TextSpan(text: '  ${m.year}', style: TextStyle(color: context.tk.sec)),
      ]),
      style: const TextStyle(fontSize: 13),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

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
  Widget build(BuildContext context) {
    final store = widget.store;
    final accent = _accentOr(store, const Color(0xFFFF3B30));
    return Column(children: [
      _TS(
        _ts(store, 'calendar.title'),
        _Header(
          kind: 'calendar',
          actions: [
            IconButton(tooltip: 'Mes anterior', iconSize: 16, visualDensity: VisualDensity.compact, onPressed: () => setState(() => month = addMonths(month, -1)), icon: const Icon(Icons.chevron_left_rounded)),
            IconButton(tooltip: 'Mes siguiente', iconSize: 16, visualDensity: VisualDensity.compact, onPressed: () => setState(() => month = addMonths(month, 1)), icon: const Icon(Icons.chevron_right_rounded)),
          ],
          child: _monthTitle(month, context, accent),
        ),
      ),
      const SizedBox(height: 4),
      Expanded(
        child: _TS(
          _ts(store, 'calendar.body'),
          LayoutBuilder(builder: (context, c) {
            final (cellW, cellH) = _monthCells(context, c);
            return Tooltip(
              message: 'Doble clic en un día para añadir un evento',
              waitDuration: const Duration(seconds: 1),
              child: MiniMonth(month: month, showHeader: false, cell: cellW, cellHeight: cellH, dots: _dots(store, month), onPick: (_) {}, onDoubleTap: openAppOn, todayColor: accent),
            );
          }),
        ),
      ),
    ]);
  }
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

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final store = widget.store;
    final days = store.settings.widgetRanges['agenda'] ?? 3;
    final occ = store.occurrences(day, addDays(day, days));
    // Agrupar por día (un evento de varios días aparece el día en que empieza o el primero del periodo).
    final groups = <String, List<Occurrence>>{};
    for (final o in occ) {
      final d = o.start.isBefore(day) ? day : dateOnly(o.start);
      groups.putIfAbsent(fmtCoreDate(d), () => []).add(o);
    }
    Widget item(Occurrence o) {
      final c = o.colorValue;
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        decoration: BoxDecoration(color: t.tint(c), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(child: Text(o.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(o.allDay ? 'todo el día' : fmtTime(o.start), style: TextStyle(fontSize: 12, color: t.sec)),
          if (o.attachments > 0) _Clip(ownerId: o.eventId, count: o.attachments) else const SizedBox(width: 6),
        ]),
      );
    }

    final title = days == 1 && sameDay(day, DateTime.now()) ? 'Hoy, ${weekdayLong[day.weekday - 1]} ${day.day}' : (sameDay(day, DateTime.now()) ? _rangeLabel(days) : '${capitalize(shortDate(day))} · ${_rangeLabel(days).toLowerCase()}');
    final accent = _accentOr(store, const Color(0xFFFF3B30));
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Calendario: ocupa el 40 % del ancho y sus celdas se adaptan al espacio.
      Expanded(
        flex: 4,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _TS(
            _ts(store, 'agenda.calTitle'),
            GestureDetector(
              onSecondaryTapDown: (d) => _widgetMenu(context, d.globalPosition, 'agenda'),
              child: DragToMoveArea(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 30),
                  child: Align(alignment: Alignment.centerLeft, child: _monthTitle(month, context, accent)),
                ),
              ),
            ),
          ),
          Expanded(
            child: _TS(
              _ts(store, 'agenda.calBody'),
              LayoutBuilder(builder: (context, c) {
                final (cellW, cellH) = _monthCells(context, c);
                return MiniMonth(
                  month: month,
                  showHeader: false,
                  cell: cellW,
                  cellHeight: cellH,
                  selected: day,
                  todayColor: accent,
                  onDoubleTap: openAppOn,
                  onPick: (d) => setState(() {
                    day = d;
                    if (d.month != month.month) month = startOfMonth(d);
                  }),
                );
              }),
            ),
          ),
        ]),
      ),
      Container(width: 1, margin: const EdgeInsets.symmetric(horizontal: 14), color: t.border),
      Expanded(
        flex: 6,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _TS(
            _ts(store, 'agenda.listTitle'),
            _Header(
              kind: 'agenda',
              onAdd: () => openAppOn(day),
              addTooltip: 'Nuevo evento',
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _TS(
              _ts(store, 'agenda.listBody'),
              occ.isEmpty
                  ? Padding(padding: const EdgeInsets.only(top: 8), child: Text('Sin eventos', style: TextStyle(color: t.faint)))
                  : ListView(children: [
                      for (final g in groups.entries) ...[
                        if (days > 1)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 6),
                            child: Text(_dayHeader(DateTime.parse(g.key)), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: t.sec)),
                          ),
                        ...g.value.map(item),
                      ],
                    ]),
            ),
          ),
        ]),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ tareas

class _TasksWidget extends StatelessWidget {
  const _TasksWidget({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final days = store.settings.widgetRanges['tasks'] ?? 1;
    final until = fmtCoreDate(addDays(dateOnly(DateTime.now()), days));
    final nodes = days == 1
        ? store.tasks(const TaskScope.smart('today'))
        : (Core.call('tasks.list', {'filter': {'smart': 'upcoming', 'until': until}}) as List).map((o) => TaskNode.fromJson(o as Map<String, dynamic>)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _TS(
        _ts(store, 'tasks.title'),
        _Header(
          kind: 'tasks',
          onAdd: openAppNewTask,
          addTooltip: 'Nueva tarea',
          child: Row(children: [
            Container(width: 24, height: 24, decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle), child: const Icon(Icons.check_rounded, size: 14, color: Colors.white)),
            const SizedBox(width: 8),
            Flexible(child: Text('Tareas · ${_rangeLabel(days)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            const SizedBox(width: 6),
            Text('${nodes.length}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: t.accent)),
          ]),
        ),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: _TS(
          _ts(store, 'tasks.body'),
          nodes.isEmpty
            ? Center(child: Text(days == 1 ? 'Nada pendiente para hoy' : 'Nada pendiente', style: TextStyle(color: t.faint)))
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
                              if (n.task.due != null || n.task.start != null) taskDates(n.task.start, n.task.due),
                              n.listName,
                              if (n.task.priority > 0) '!' * n.task.priority,
                            ].join(' · '),
                            style: TextStyle(fontSize: 11, color: n.overdue ? t.danger : t.sec),
                          ),
                        ]),
                      ),
                      if (n.attachments > 0) _Clip(ownerId: n.task.id, count: n.attachments),
                    ]),
                  ),
              ]),
        ),
      ),
    ]);
  }
}
