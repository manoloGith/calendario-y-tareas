// Vista de semana y de día (estilo Calendario de macOS).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/models.dart';
import '../../core/store.dart';
import '../common.dart';
import '../theme.dart';
import 'event_editor.dart';

const double hourH = 48;
const double gutterW = 60;

class WeekView extends StatefulWidget {
  const WeekView({super.key, required this.store, required this.days});
  final AppStore store;
  /// 7 para semana, 1 para día.
  final int days;
  @override
  State<WeekView> createState() => _WeekViewState();
}

class _Seg {
  _Seg(this.occ, this.start, this.end);
  final Occurrence occ;
  final DateTime start;
  final DateTime end;
  int col = 0;
  int cols = 1;
}

class _Drag {
  _Drag(this.occ, this.resize);
  final Occurrence occ;
  final bool resize;
  double dy = 0;
  double dx = 0;
}

class _WeekViewState extends State<WeekView> {
  final scroll = ScrollController(initialScrollOffset: 7.5 * hourH);
  Timer? clock;
  _Drag? drag;

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    clock = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    clock?.cancel();
    scroll.dispose();
    super.dispose();
  }

  List<DateTime> get days {
    final first = widget.days == 1 ? dateOnly(store.anchor) : startOfWeek(store.anchor);
    return [for (var i = 0; i < widget.days; i++) addDays(first, i)];
  }

  /// Reparte en columnas los eventos que se solapan.
  List<_Seg> _layout(List<_Seg> segs) {
    segs.sort((a, b) => a.start.compareTo(b.start) != 0 ? a.start.compareTo(b.start) : b.end.compareTo(a.end));
    final clusters = <List<_Seg>>[];
    DateTime? clusterEnd;
    for (final s in segs) {
      if (clusterEnd == null || !s.start.isBefore(clusterEnd)) {
        clusters.add([s]);
        clusterEnd = s.end;
      } else {
        clusters.last.add(s);
        if (s.end.isAfter(clusterEnd)) clusterEnd = s.end;
      }
    }
    for (final c in clusters) {
      final colEnds = <DateTime>[];
      for (final s in c) {
        var placed = false;
        for (var i = 0; i < colEnds.length; i++) {
          if (!s.start.isBefore(colEnds[i])) {
            s.col = i;
            colEnds[i] = s.end;
            placed = true;
            break;
          }
        }
        if (!placed) {
          s.col = colEnds.length;
          colEnds.add(s.end);
        }
      }
      for (final s in c) {
        s.cols = colEnds.length;
      }
    }
    return segs;
  }

  Future<void> _commitDrag(double colW) async {
    final d = drag;
    if (d == null) return;
    final mins = ((d.dy / hourH) * 60 / 15).round() * 15;
    final dayShift = d.resize ? 0 : (d.dx / colW).round();
    setState(() => drag = null);
    if (mins == 0 && dayShift == 0) return;
    final e = store.event(d.occ.eventId);
    final os = DateTime.parse(d.occ.originalStart);
    final dur = DateTime.parse(e.end).difference(DateTime.parse(e.start));
    var ns = os.add(Duration(days: dayShift, minutes: d.resize ? 0 : mins));
    var ne = os.add(dur).add(Duration(days: dayShift, minutes: mins));
    if (d.resize && !ne.isAfter(ns.add(const Duration(minutes: 14)))) ne = ns.add(const Duration(minutes: 15));
    var scope = 'all';
    if (e.recurring) {
      final s = await askScope(context, deleting: false);
      if (s == null) return;
      scope = s;
      if (scope == 'all') {
        final ms = DateTime.parse(e.start);
        final shift = ns.difference(os);
        ns = ms.add(shift);
        ne = ns.add(ne.difference(os.add(shift)));
      }
    }
    e.start = fmtCore(ns);
    e.end = fmtCore(ne);
    try {
      store.mutate('events.save', {'event': e.toJson(), 'scope': scope, 'occurrence': d.occ.originalStart});
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final ds = days;
    final from = ds.first;
    final to = addDays(ds.last, 1);
    final occ = store.occurrences(from, to);
    final tasks = store.tasksInRange(from, to);
    final now = DateTime.now();

    return LayoutBuilder(builder: (context, box) {
      final colW = (box.maxWidth - gutterW) / ds.length;
      return Column(children: [
        // Cabecera de días
        Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
          child: Row(children: [
            const SizedBox(width: gutterW),
            for (final d in ds)
              SizedBox(
                width: colW,
                child: InkWell(
                  onTap: () => store.goTo(d, view: CalView.day),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(weekdayShort[d.weekday - 1],
                          style: TextStyle(fontSize: 15, fontWeight: sameDay(d, now) ? FontWeight.w700 : FontWeight.w400, color: d.weekday > 5 ? t.sec : t.text)),
                      const SizedBox(width: 6),
                      Container(
                        constraints: const BoxConstraints(minWidth: 26),
                        height: 26,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(color: sameDay(d, now) ? const Color(0xFFFF3B30) : Colors.transparent, borderRadius: BorderRadius.circular(13)),
                        child: Text('${d.day}',
                            style: TextStyle(fontSize: 15, fontWeight: sameDay(d, now) ? FontWeight.w700 : FontWeight.w400, color: sameDay(d, now) ? Colors.white : (d.weekday > 5 ? t.sec : t.text))),
                      ),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        // Fila «todo el día»: eventos de día completo y tareas sin hora
        Container(
          constraints: const BoxConstraints(minHeight: 34, maxHeight: 120),
          decoration: BoxDecoration(color: t.allDay, border: Border(bottom: BorderSide(color: t.border, width: 2))),
          child: SingleChildScrollView(
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: gutterW,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8, right: 8),
                    child: Text('todo el día', textAlign: TextAlign.right, style: TextStyle(fontSize: 10.5, color: t.sec)),
                  ),
                ),
                for (final d in ds)
                  GestureDetector(
                    onDoubleTap: () => openEventEditor(context, store, start: d, allDay: true),
                    child: Container(
                      width: colW,
                      padding: const EdgeInsets.fromLTRB(3, 4, 3, 4),
                      decoration: BoxDecoration(border: Border(left: BorderSide(color: t.border))),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final o in occ.where((o) => o.allDay && !o.start.isAfter(d) && o.end.isAfter(d))) _AllDayPill(store: store, occ: o),
                        for (final n in tasks.where((n) => !n.task.hasTime && sameDay(n.task.dueDate!, d))) _TaskChip(store: store, node: n),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        // Rejilla horaria
        Expanded(
          child: SingleChildScrollView(
            controller: scroll,
            child: SizedBox(
              height: 24 * hourH + 16,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: gutterW,
                    height: 24 * hourH,
                    child: Stack(clipBehavior: Clip.none, children: [
                      for (var h = 1; h < 24; h++)
                        Positioned(
                          top: h * hourH - 7,
                          right: 8,
                          child: Text('$h:00', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.sec)),
                        ),
                      if (ds.any((d) => sameDay(d, now)))
                        Positioned(
                          top: (now.hour + now.minute / 60) * hourH - 8,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(color: const Color(0xFFFF3B30), borderRadius: BorderRadius.circular(999)),
                            child: Text(fmtTime(now), style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.white)),
                          ),
                        ),
                    ]),
                  ),
                  for (var i = 0; i < ds.length; i++) _dayColumn(context, ds[i], i, colW, occ, tasks, now),
                ]),
              ),
            ),
          ),
        ),
      ]);
    });
  }

  Widget _dayColumn(BuildContext context, DateTime day, int index, double colW, List<Occurrence> occ, List<TaskNode> tasks, DateTime now) {
    final t = context.tk;
    final dayEnd = addDays(day, 1);
    final segs = _layout([
      for (final o in occ.where((o) => !o.allDay && o.start.isBefore(dayEnd) && o.end.isAfter(day)))
        _Seg(o, o.start.isBefore(day) ? day : o.start, o.end.isAfter(dayEnd) ? dayEnd : o.end),
    ]);
    double y(DateTime d) => (d.difference(day).inMinutes / 60) * hourH;
    final isToday = sameDay(day, now);

    return SizedBox(
      width: colW,
      height: 24 * hourH,
      child: Stack(clipBehavior: Clip.none, children: [
        // Fondo: líneas de horas y clic para crear
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTapDown: (d) {
              final mins = ((d.localPosition.dy / hourH) * 60 / 30).floor() * 30;
              openEventEditor(context, store, start: day.add(Duration(minutes: mins)));
            },
            onDoubleTap: () {},
            child: CustomPaint(painter: _GridPainter(t.border)),
          ),
        ),
        if (isToday)
          Positioned(
            top: y(now) - 1,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Row(children: [
                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFFF3B30), shape: BoxShape.circle)),
                Expanded(child: Container(height: 2, color: const Color(0xFFFF3B30))),
              ]),
            ),
          )
        else if (days.any((d) => sameDay(d, now)))
          Positioned(top: y(DateTime(day.year, day.month, day.day, now.hour, now.minute)), left: 0, right: 0, child: IgnorePointer(child: Container(height: 1, color: const Color(0x59FF3B30)))),
        for (final s in segs) _eventBlock(context, s, colW, y),
        for (final n in tasks.where((n) => n.task.hasTime && sameDay(n.task.dueDate!, day)))
          Positioned(
            top: y(n.task.dueDate!) + 1,
            left: 3,
            right: 4,
            child: _TaskChip(store: store, node: n, framed: true),
          ),
      ]),
    );
  }

  Widget _eventBlock(BuildContext context, _Seg s, double colW, double Function(DateTime) y) {
    final t = context.tk;
    final c = s.occ.colorValue;
    final isDragging = drag != null && drag!.occ.eventId == s.occ.eventId && drag!.occ.originalStart == s.occ.originalStart;
    var top = y(s.start);
    var height = (y(s.end) - top).clamp(20.0, 24 * hourH);
    if (isDragging) {
      final snapped = ((drag!.dy / hourH) * 60 / 15).round() * 15 / 60 * hourH;
      if (drag!.resize) {
        height = (height + snapped).clamp(hourH / 4, 24 * hourH);
      } else {
        top += snapped;
      }
    }
    final w = (colW - 7) / s.cols;
    final left = 3 + s.col * w + (isDragging && !drag!.resize ? ((drag!.dx / colW).round() * colW) : 0);
    final readonly = store.calendar(s.occ.calendarId)?.readonly ?? false;
    final text = t.tintText(c);
    return Positioned(
      top: top + 1,
      left: left,
      width: w - 1,
      height: height - 2,
      child: MouseRegion(
        cursor: readonly ? SystemMouseCursors.click : SystemMouseCursors.grab,
        child: GestureDetector(
          onTap: () => openEventEditor(context, store, eventId: s.occ.eventId, occurrence: s.occ),
          onPanStart: readonly ? null : (_) => setState(() => drag = _Drag(s.occ, false)),
          onPanUpdate: readonly
              ? null
              : (d) => setState(() {
                    drag!.dy += d.delta.dy;
                    drag!.dx += d.delta.dx;
                  }),
          onPanEnd: readonly ? null : (_) => _commitDrag(colW),
          child: Opacity(
            opacity: isDragging ? .85 : 1,
            child: Container(
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: Color.alphaBlend(t.tint(c), t.window),
                borderRadius: BorderRadius.circular(6),
                border: Border(left: BorderSide(color: c, width: 3)),
                boxShadow: isDragging ? const [BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 3))] : null,
              ),
              child: Stack(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 3, 4, 3),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text(s.occ.title,
                            maxLines: height > 44 ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: text)),
                      ),
                      if (s.occ.recurring) Icon(Icons.repeat_rounded, size: 11, color: text),
                    ]),
                    if (height >= 40)
                      Text('${fmtTime(s.occ.start)}–${fmtTime(s.occ.end)}', style: TextStyle(fontSize: 11, color: text), maxLines: 1),
                    if (height >= 60 && s.occ.location.isNotEmpty)
                      Row(children: [
                        Icon(Icons.place_outlined, size: 11, color: text),
                        const SizedBox(width: 2),
                        Expanded(child: Text(s.occ.location, style: TextStyle(fontSize: 11, color: text), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ]),
                  ]),
                ),
                if (!readonly)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 7,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeUpDown,
                      child: GestureDetector(
                        onVerticalDragStart: (_) => setState(() => drag = _Drag(s.occ, true)),
                        onVerticalDragUpdate: (d) => setState(() => drag!.dy += d.delta.dy),
                        onVerticalDragEnd: (_) => _commitDrag(colW),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(Offset.zero, Offset(0, size.height), p);
    for (var h = 0; h <= 24; h++) {
      canvas.drawLine(Offset(0, h * hourH), Offset(size.width, h * hourH), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

class _AllDayPill extends StatelessWidget {
  const _AllDayPill({required this.store, required this.occ});
  final AppStore store;
  final Occurrence occ;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final c = occ.colorValue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: Color.alphaBlend(t.tint(c), t.window),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => openEventEditor(context, store, eventId: occ.eventId, occurrence: occ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: Row(children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              Expanded(child: Text(occ.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.tintText(c)))),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Tarea dentro del calendario (fila «todo el día» o en su hora).
class _TaskChip extends StatelessWidget {
  const _TaskChip({required this.store, required this.node, this.framed = false});
  final AppStore store;
  final TaskNode node;
  final bool framed;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final task = node.task;
    return Padding(
      padding: EdgeInsets.only(bottom: framed ? 0 : 3),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: framed ? t.window : t.pill.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(framed ? 6 : 999),
          border: framed ? Border.all(color: t.border) : null,
        ),
        child: Row(children: [
          CheckCircle(
            color: node.color,
            done: task.completed,
            size: 13,
            label: task.title,
            onTap: () {
              try {
                store.mutate('tasks.toggle', {'id': task.id});
              } catch (e) {
                showError(context, e);
              }
            },
          ),
          const SizedBox(width: 6),
          Expanded(
            child: GestureDetector(
              onTap: () {
                store.selectScope(TaskScope.list(task.listId));
                store.selectTask(task.parentId ?? task.id);
              },
              child: Text(task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: task.completed ? t.faint : t.text,
                    decoration: task.completed ? TextDecoration.lineThrough : null,
                  )),
            ),
          ),
        ]),
      ),
    );
  }
}
