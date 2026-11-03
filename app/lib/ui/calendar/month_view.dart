// Vistas de mes y de año.
import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/models.dart';
import '../../core/store.dart';
import '../common.dart';
import '../theme.dart';
import 'event_editor.dart';

class MonthView extends StatelessWidget {
  const MonthView({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final month = startOfMonth(store.anchor);
    final start = monthGridStart(month);
    final end = addDays(start, 42);
    final occ = store.occurrences(start, end);
    final tasks = store.tasksInRange(start, end);
    final now = DateTime.now();
    return Column(children: [
      Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
        child: Row(children: [
          for (final w in weekdayShort)
            Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(0, 6, 10, 6), child: Text(w, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.sec)))),
        ]),
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, box) {
          final rowH = box.maxHeight / 6;
          final maxItems = ((rowH - 34) / 17).floor().clamp(0, 10);
          return Column(children: [
            for (var w = 0; w < 6; w++)
              SizedBox(
                height: rowH,
                child: Row(children: [
                  for (var d = 0; d < 7; d++)
                    Expanded(child: Builder(builder: (context) {
                      final day = addDays(start, w * 7 + d);
                      final next = addDays(day, 1);
                      final dayOcc = occ.where((o) => o.start.isBefore(next) && (o.end.isAfter(day) || (o.end == o.start && !o.start.isBefore(day)))).toList();
                      final dayTasks = tasks.where((n) => sameDay(n.task.dueDate!, day)).toList();
                      final items = <Widget>[
                        for (final o in dayOcc) _MonthEvent(store: store, occ: o),
                        for (final n in dayTasks) _MonthTask(store: store, node: n),
                      ];
                      final inMonth = day.month == month.month;
                      final today = sameDay(day, now);
                      return GestureDetector(
                        onDoubleTap: () => openEventEditor(context, store, start: DateTime(day.year, day.month, day.day, 9)),
                        child: Container(
                          decoration: BoxDecoration(
                            color: inMonth ? t.window : t.allDay,
                            border: Border(right: BorderSide(color: t.border), bottom: BorderSide(color: t.border)),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Align(
                              alignment: Alignment.topRight,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => store.goTo(day, view: CalView.day),
                                child: Container(
                                  constraints: const BoxConstraints(minWidth: 24),
                                  height: 24,
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  decoration: BoxDecoration(color: today ? const Color(0xFFFF3B30) : Colors.transparent, borderRadius: BorderRadius.circular(12)),
                                  child: Text(day.day == 1 ? '1 ${monthShort[day.month - 1]}' : '${day.day}',
                                      style: TextStyle(fontWeight: today ? FontWeight.w700 : FontWeight.w400, color: today ? Colors.white : (inMonth ? t.text : t.faint))),
                                ),
                              ),
                            ),
                            ...items.take(items.length > maxItems ? (maxItems - 1).clamp(0, 10) : maxItems),
                            if (items.length > maxItems && maxItems > 0)
                              InkWell(
                                onTap: () => store.goTo(day, view: CalView.day),
                                child: Padding(padding: const EdgeInsets.only(left: 4), child: Text('${items.length - maxItems + 1} más', style: TextStyle(fontSize: 11, color: t.sec))),
                              ),
                          ]),
                        ),
                      );
                    })),
                ]),
              ),
          ]);
        }),
      ),
    ]);
  }
}

class _MonthEvent extends StatelessWidget {
  const _MonthEvent({required this.store, required this.occ});
  final AppStore store;
  final Occurrence occ;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final c = occ.colorValue;
    return InkWell(
      onTap: () => openEventEditor(context, store, eventId: occ.eventId, occurrence: occ),
      child: Container(
        height: 17,
        margin: const EdgeInsets.only(bottom: 1),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: occ.allDay ? BoxDecoration(color: Color.alphaBlend(t.tint(c), t.window), borderRadius: BorderRadius.circular(4)) : null,
        child: Row(children: [
          if (!occ.allDay) ...[Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)), const SizedBox(width: 5)],
          Expanded(
            child: Text(occ.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, fontWeight: occ.allDay ? FontWeight.w600 : FontWeight.w400, color: occ.allDay ? t.tintText(c) : t.text)),
          ),
          if (!occ.allDay) Text(fmtTime(occ.start), style: TextStyle(fontSize: 11, color: t.sec)),
        ]),
      ),
    );
  }
}

class _MonthTask extends StatelessWidget {
  const _MonthTask({required this.store, required this.node});
  final AppStore store;
  final TaskNode node;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return SizedBox(
      height: 17,
      child: Row(children: [
        const SizedBox(width: 3),
        CheckCircle(color: node.color, done: node.task.completed, size: 11, label: node.task.title, onTap: () => store.mutate('tasks.toggle', {'id': node.task.id})),
        const SizedBox(width: 5),
        Expanded(
          child: Text(node.task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: node.task.completed ? t.faint : t.text, decoration: node.task.completed ? TextDecoration.lineThrough : null)),
        ),
      ]),
    );
  }
}

class YearView extends StatelessWidget {
  const YearView({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final y = store.anchor.year;
    final occ = store.occurrences(DateTime(y, 1, 1), DateTime(y + 1, 1, 1));
    final dots = <String, Color>{};
    for (final o in occ) {
      dots.putIfAbsent(fmtCoreDate(o.start), () => o.colorValue);
    }
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth > 1100 ? 4 : (box.maxWidth > 760 ? 3 : 2);
      final cell = ((box.maxWidth / cols) - 40) / 7;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 24, runSpacing: 22, children: [
          for (var m = 1; m <= 12; m++)
            SizedBox(
              width: cell * 7,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                InkWell(
                  onTap: () => store.goTo(DateTime(y, m, 1), view: CalView.month),
                  child: Text(capitalize(monthNames[m - 1]), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: m == DateTime.now().month && y == DateTime.now().year ? const Color(0xFFFF3B30) : null)),
                ),
                const SizedBox(height: 4),
                MiniMonth(
                  month: DateTime(y, m, 1),
                  cell: cell.clamp(18.0, 40.0),
                  showHeader: false,
                  dots: dots,
                  onPick: (d) => store.goTo(d, view: CalView.day),
                ),
              ]),
            ),
        ]),
      );
    });
  }
}
