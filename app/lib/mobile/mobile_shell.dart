// Interfaz para móvil (Android): navegación inferior, menú lateral deslizable y botón «+».
import 'package:flutter/material.dart';

import '../core/dates.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../ui/calendar/event_editor.dart';
import '../ui/calendar/month_view.dart';
import '../ui/calendar/week_view.dart';
import '../ui/common.dart';
import '../ui/settings_dialog.dart';
import '../ui/shell.dart';
import '../ui/sidebar.dart';
import '../ui/tasks/tasks_view.dart';
import '../ui/theme.dart';

class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.store});
  final AppStore store;
  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  final scaffold = GlobalKey<ScaffoldState>();
  bool settings = false;
  late TaskScope _scope = widget.store.taskScope;
  late DateTime _anchor = widget.store.anchor;
  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    super.dispose();
  }

  /// Al elegir una lista o un día en el menú lateral, el menú se cierra.
  void _onStore() {
    final changed = store.taskScope != _scope || !sameDay(store.anchor, _anchor);
    _scope = store.taskScope;
    _anchor = store.anchor;
    if (changed && (scaffold.currentState?.isDrawerOpen ?? false)) scaffold.currentState?.closeDrawer();
  }

  int get tab => settings ? 2 : (store.mode == AppMode.tasks ? 1 : 0);

  void _new() {
    if (store.mode == AppMode.tasks) {
      final list = store.defaultListId;
      if (list == null) return showError(context, 'Crea primero una lista de tareas.');
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
      openTaskPage(context, store, r['id'] as String);
    } else {
      final a = store.anchor;
      final now = DateTime.now();
      openEventEditor(context, store, start: sameDay(a, now) ? DateTime(a.year, a.month, a.day, now.hour + 1) : DateTime(a.year, a.month, a.day, 9));
    }
  }

  Widget _calendar(BuildContext context) {
    final t = context.tk;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: Center(
          child: PillSegmented<CalView>(
            compact: true,
            values: CalView.values,
            labels: const ['Día', 'Semana', 'Mes', 'Año'],
            selected: store.view,
            onChanged: store.setView,
          ),
        ),
      ),
      PeriodHeader(store: store),
      Expanded(
        child: GestureDetector(
          // Deslizar a izquierda o derecha: periodo siguiente o anterior.
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v.abs() > 300) store.step(v < 0 ? 1 : -1);
          },
          child: Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
            child: switch (store.view) {
              CalView.day => WeekView(key: const ValueKey('m-day'), store: store, days: 1),
              CalView.week => WeekView(key: const ValueKey('m-week'), store: store, days: 7),
              CalView.month => MonthView(store: store),
              CalView.year => YearView(store: store),
            },
          ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final titles = ['Calendario', 'Tareas', 'Ajustes'];
    return Scaffold(
      key: scaffold,
      backgroundColor: t.window,
      appBar: AppBar(
        backgroundColor: t.window,
        surfaceTintColor: Colors.transparent,
        title: Text(titles[tab], style: const TextStyle(fontWeight: FontWeight.w700)),
        leading: tab == 2 ? null : IconButton(tooltip: 'Calendarios y listas', icon: const Icon(Icons.menu_rounded), onPressed: () => scaffold.currentState?.openDrawer()),
        actions: [
          if (tab == 0) IconButton(tooltip: 'Hoy', icon: const Icon(Icons.today_rounded), onPressed: store.today),
          if (tab < 2) IconButton(tooltip: 'Buscar', icon: const Icon(Icons.search_rounded), onPressed: () => openSearch(context, store)),
          if (store.hasRemote)
            IconButton(
              tooltip: store.syncMessage.isEmpty ? 'Sincronizar' : store.syncMessage,
              icon: Icon(switch (store.syncState) {
                SyncState.syncing => Icons.sync_rounded,
                SyncState.offline => Icons.cloud_off_rounded,
                SyncState.error => Icons.sync_problem_rounded,
                SyncState.idle => Icons.cloud_done_outlined,
              }),
              onPressed: store.syncNow,
            ),
        ],
      ),
      drawer: tab == 2
          ? null
          : Drawer(
              backgroundColor: t.window,
              width: 290,
              child: SafeArea(child: store.mode == AppMode.tasks ? TaskSidebar(store: store) : CalendarSidebar(store: store)),
            ),
      body: SafeArea(
        top: false,
        child: switch (tab) {
          0 => _calendar(context),
          1 => TasksView(store: store, compact: true),
          _ => SettingsDialog(store: store, embedded: true),
        },
      ),
      floatingActionButton: tab == 2
          ? null
          : FloatingActionButton(
              tooltip: tab == 1 ? 'Nueva tarea' : 'Nuevo evento',
              backgroundColor: t.accent,
              foregroundColor: Colors.white,
              shape: const CircleBorder(),
              onPressed: _new,
              child: const Icon(Icons.add_rounded, size: 28),
            ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: t.sidebar,
        indicatorColor: t.accent.withValues(alpha: .15),
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() {
          settings = i == 2;
          if (i < 2) store.setMode(i == 1 ? AppMode.tasks : AppMode.calendar);
        }),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month_rounded), label: 'Calendario'),
          NavigationDestination(icon: Icon(Icons.inbox_outlined), selectedIcon: Icon(Icons.inbox_rounded), label: 'Tareas'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: 'Ajustes'),
        ],
      ),
    );
  }
}
