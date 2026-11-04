// Ventana principal: barra lateral flotante, barra de herramientas y contenido (calendario o tareas).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/bridge.dart';
import '../core/dates.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'calendar/event_editor.dart';
import 'calendar/month_view.dart';
import 'calendar/week_view.dart';
import 'common.dart';
import 'settings_dialog.dart';
import 'sidebar.dart';
import 'tasks/tasks_view.dart';
import 'theme.dart';
import 'tray.dart';

class Shell extends StatefulWidget {
  const Shell({super.key, required this.store});
  final AppStore store;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool sidebar = true;
  AppStore get store => widget.store;

  void _new() {
    if (store.mode == AppMode.tasks) {
      final list = store.defaultListId;
      if (list == null) return showError(context, 'Crea primero una lista de tareas.');
      // Que la tarea nueva aparezca en la lista que se está viendo.
      final scope = store.taskScope;
      final dated = scope.smart == 'today' || scope.smart == 'scheduled';
      final r = store.mutate('tasks.save', {
        'task': TaskData(
          listId: scope.listId ?? list,
          title: 'Nueva tarea',
          due: dated ? fmtCoreDate(DateTime.now()) : null,
          flagged: scope.smart == 'flagged',
          tags: scope.tag != null ? [scope.tag!] : null,
        ).toJson(),
      }) as Map<String, dynamic>;
      store.selectTask(r['id'] as String);
    } else {
      final a = store.anchor;
      final now = DateTime.now();
      openEventEditor(context, store, start: DateTime(a.year, a.month, a.day, now.hour + 1));
    }
  }

  bool _openingPending = false;

  /// Atiende la petición de un widget: formulario de nuevo evento en el día pedido.
  void _handlePending() {
    if (store.requestNewTask) {
      store.requestNewTask = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _new());
    }
    final day = store.pendingNewEvent;
    if (day == null || _openingPending) return;
    _openingPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      store.pendingNewEvent = null;
      final now = DateTime.now();
      final start = sameDay(day, now) ? DateTime(day.year, day.month, day.day, now.hour + 1) : DateTime(day.year, day.month, day.day, 9);
      if (mounted) await openEventEditor(context, store, start: start);
      _openingPending = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final mod = Platform.isMacOS;
    _handlePending();
    SingleActivator key(LogicalKeyboardKey k) => SingleActivator(k, meta: mod, control: !mod);
    return CallbackShortcuts(
      bindings: {
        key(LogicalKeyboardKey.keyN): _new,
        key(LogicalKeyboardKey.keyF): () => openSearch(context, store),
        key(LogicalKeyboardKey.keyT): store.today,
        key(LogicalKeyboardKey.keyL): store.lock,
        key(LogicalKeyboardKey.comma): () => showSettings(context, store),
        key(LogicalKeyboardKey.digit1): () => store.setMode(AppMode.calendar),
        key(LogicalKeyboardKey.digit2): () => store.setMode(AppMode.tasks),
        key(LogicalKeyboardKey.keyR): () => store.syncNow(),
        key(LogicalKeyboardKey.keyQ): () => appTray?.active == true ? appTray!.quit() : windowManager.close(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () => store.step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () => store.step(1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: LayoutBuilder(builder: (context, box) {
            final showSide = sidebar && box.maxWidth > 760;
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (showSide) store.mode == AppMode.calendar ? CalendarSidebar(store: store) : TaskSidebar(store: store),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  DragToMoveArea(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(showSide ? 0 : 12, 10, 14, 6),
                      child: Row(children: [
                        if (!showSide) ...[const TrafficLights(), const SizedBox(width: 12)],
                        RoundIconButton(icon: Icons.view_sidebar_outlined, tooltip: 'Barra lateral', onTap: () => setState(() => sidebar = !sidebar)),
                        const SizedBox(width: 8),
                        RoundIconButton(icon: Icons.add_rounded, tooltip: store.mode == AppMode.tasks ? 'Nueva tarea (Ctrl+N)' : 'Nuevo evento (Ctrl+N)', onTap: _new),
                        const Spacer(),
                        if (store.mode == AppMode.calendar)
                          PillSegmented<CalView>(
                            values: CalView.values,
                            labels: const ['Día', 'Semana', 'Mes', 'Año'],
                            selected: store.view,
                            onChanged: store.setView,
                          )
                        else
                          PillSegmented<bool>(
                            values: const [false, true],
                            labels: const ['Pendientes', 'Con completadas'],
                            selected: store.showCompleted,
                            onChanged: (_) => store.toggleShowCompleted(),
                          ),
                        const Spacer(),
                        if (store.accounts.isNotEmpty) ...[
                          RoundIconButton(
                            icon: switch (store.syncState) {
                              SyncState.syncing => Icons.sync_rounded,
                              SyncState.offline => Icons.cloud_off_rounded,
                              SyncState.error => Icons.sync_problem_rounded,
                              SyncState.idle => Icons.cloud_done_outlined,
                            },
                            tooltip: '${store.syncMessage.isEmpty ? 'Sincronizar' : store.syncMessage} (Ctrl+R)',
                            onTap: store.syncNow,
                          ),
                          const SizedBox(width: 8),
                        ],
                        RoundIconButton(icon: Icons.search_rounded, tooltip: 'Buscar (Ctrl+F)', onTap: () => openSearch(context, store)),
                        const SizedBox(width: 8),
                        RoundIconButton(icon: Icons.settings_outlined, tooltip: 'Ajustes (Ctrl+,)', onTap: () => showSettings(context, store)),
                      ]),
                    ),
                  ),
                  Expanded(
                    child: store.mode == AppMode.tasks
                        ? TasksView(store: store)
                        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            PeriodHeader(store: store),
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
                                child: switch (store.view) {
                                  CalView.day => WeekView(key: const ValueKey('day'), store: store, days: 1),
                                  CalView.week => WeekView(key: const ValueKey('week'), store: store, days: 7),
                                  CalView.month => MonthView(store: store),
                                  CalView.year => YearView(store: store),
                                },
                              ),
                            ),
                          ]),
                  ),
                ]),
              ),
            ]);
          }),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ búsqueda

Future<void> openSearch(BuildContext context, AppStore store) => showDialog(context: context, builder: (_) => _SearchDialog(store: store));

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.store});
  final AppStore store;
  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  List<EventData> events = [];
  List<TaskData> tasks = [];

  void _search(String q) {
    if (q.trim().length < 2) {
      setState(() {
        events = [];
        tasks = [];
      });
      return;
    }
    final r = Core.call('search', {'q': q.trim()}) as Map<String, dynamic>;
    setState(() {
      events = (r['events'] as List).map((e) => EventData.fromJson(e as Map<String, dynamic>)).toList();
      tasks = (r['tasks'] as List).map((e) => TaskData.fromJson(e as Map<String, dynamic>)).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final store = widget.store;
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 80),
      child: SizedBox(
        width: 560,
        height: 460,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Buscar eventos y tareas', prefixIcon: Icon(Icons.search_rounded, size: 18)),
              onChanged: _search,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(children: [
                if (events.isNotEmpty) const SectionLabel('Eventos'),
                for (final e in events)
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(radius: 5, backgroundColor: store.calendar(e.calendarId)?.colorValue ?? t.accent),
                    title: Text(e.title),
                    subtitle: Text('${capitalize(longDate(DateTime.parse(e.start)))}${e.allDay ? '' : ', ${fmtTime(DateTime.parse(e.start))}'}${e.recurring ? ' · ${describeRule(e.rrule)}' : ''}'),
                    onTap: () {
                      Navigator.pop(context);
                      store.setMode(AppMode.calendar);
                      store.goTo(DateTime.parse(e.start), view: CalView.day);
                    },
                  ),
                if (tasks.isNotEmpty) const SectionLabel('Tareas'),
                for (final tk in tasks)
                  ListTile(
                    dense: true,
                    leading: Icon(tk.completed ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 16, color: store.calendar(tk.listId)?.colorValue ?? t.accent),
                    title: Text(tk.title),
                    subtitle: tk.due == null ? null : Text(relativeDue(tk.due!)),
                    onTap: () {
                      Navigator.pop(context);
                      store.selectScope(TaskScope.list(tk.listId));
                      if (tk.completed && !store.showCompleted) store.toggleShowCompleted();
                      store.selectTask(tk.parentId ?? tk.id);
                    },
                  ),
                if (events.isEmpty && tasks.isEmpty) Padding(padding: const EdgeInsets.all(30), child: Text('Escribe al menos dos letras', textAlign: TextAlign.center, style: TextStyle(color: t.faint))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
