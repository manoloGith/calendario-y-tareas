// Barras laterales: calendarios (agrupados por conector) y listas de tareas.
import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/platform.dart';
import '../core/dates.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'common.dart';
import 'settings_dialog.dart';
import 'theme.dart';

class ModeSwitch extends StatelessWidget {
  const ModeSwitch({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    Widget b(AppMode m, IconData i, String tip) => Tooltip(
          message: tip,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => store.setMode(m),
            child: Container(
              width: 34,
              height: 28,
              decoration: BoxDecoration(color: store.mode == m ? t.pillSel : Colors.transparent, borderRadius: BorderRadius.circular(999)),
              child: Icon(i, size: 16, color: store.mode == m ? t.text : t.sec),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: t.pill, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        b(AppMode.calendar, Icons.calendar_month_outlined, 'Calendario (Ctrl+1)'),
        const SizedBox(width: 2),
        b(AppMode.tasks, Icons.inbox_outlined, 'Tareas (Ctrl+2)'),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 14),
        child: Row(children: [const TrafficLights(), const Spacer(), ModeSwitch(store: store)]),
      );
}

String groupLabel(AppStore store, Calendar c) {
  if (c.source == 'ics') return 'Archivos .ics';
  if (c.source == 'caldav') {
    for (final a in store.accounts) {
      if (a.id == c.accountId) return a.name;
    }
    return 'CalDAV';
  }
  return 'En este equipo';
}

Map<String, List<Calendar>> grouped(AppStore store, List<Calendar> cals) {
  final m = <String, List<Calendar>>{};
  for (final c in cals) {
    m.putIfAbsent(groupLabel(store, c), () => []).add(c);
  }
  return m;
}

Widget syncLine(BuildContext context, AppStore store) {
  final t = context.tk;
  final (Color dot, String text) = switch (store.syncState) {
    SyncState.syncing => (t.accent, 'Sincronizando…'),
    SyncState.offline => (const Color(0xFFFF9500), store.pending > 0 ? 'Sin conexión · ${store.pending} cambios en cola' : 'Sin conexión'),
    SyncState.error => (t.danger, store.syncMessage),
    SyncState.idle => !store.hasRemote
        ? (const Color(0xFF34C759), 'Datos locales cifrados')
        : (const Color(0xFF34C759), store.pending > 0 ? '${store.pending} cambios pendientes' : (store.syncMessage.isEmpty ? 'Al día' : store.syncMessage)),
  };
  return InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: !store.hasRemote ? null : () => store.syncNow(),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Row(children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(fontSize: 11, color: t.sec), overflow: TextOverflow.ellipsis)),
        Icon(Icons.lock_outline_rounded, size: 11, color: t.sec),
      ]),
    ),
  );
}

// ------------------------------------------------------------------ calendario

class CalendarSidebar extends StatelessWidget {
  const CalendarSidebar({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final groups = grouped(store, store.calendars.where((c) => c.hasEvents).toList());
    return FloatingPanel(
      width: 250,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Header(store: store),
        Expanded(
          child: ListView(children: [
            for (final g in groups.entries) ...[
              SectionLabel(g.key, trailing: g.key == groups.keys.first ? AddSourceButton(store: store) : null),
              for (final c in g.value) CalendarRow(store: store, cal: c),
              const SizedBox(height: 12),
            ],
            if (groups.isEmpty) ...[SectionLabel('Calendarios', trailing: AddSourceButton(store: store))],
          ]),
        ),
        const Divider(height: 16),
        MiniMonth(
          month: store.anchor,
          selected: store.anchor,
          highlightWeek: store.view == CalView.week,
          onMonth: (m) => store.goTo(m),
          onPick: (d) => store.goTo(d, view: store.view == CalView.year || store.view == CalView.month ? CalView.day : null),
        ),
        const SizedBox(height: 6),
        syncLine(context, store),
      ]),
    );
  }
}

class CalendarRow extends StatelessWidget {
  const CalendarRow({super.key, required this.store, required this.cal});
  final AppStore store;
  final Calendar cal;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        cal.visible = !cal.visible;
        store.mutate('calendars.save', {'calendar': cal.toJson()});
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(children: [
          SizedBox(
            width: 18,
            height: 18,
            child: Checkbox(
              value: cal.visible,
              activeColor: cal.colorValue,
              side: BorderSide(color: cal.colorValue, width: 1.6),
              onChanged: (v) {
                cal.visible = v ?? true;
                store.mutate('calendars.save', {'calendar': cal.toJson()});
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(cal.name, overflow: TextOverflow.ellipsis)),
          if (cal.readonly) Icon(Icons.visibility_outlined, size: 13, color: t.faint),
          CalendarMenu(store: store, cal: cal),
        ]),
      ),
    );
  }
}

class CalendarMenu extends StatelessWidget {
  const CalendarMenu({super.key, required this.store, required this.cal});
  final AppStore store;
  final Calendar cal;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'Opciones',
        iconSize: 16,
        padding: EdgeInsets.zero,
        icon: Icon(Icons.more_horiz_rounded, color: context.tk.faint),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: Text('Editar nombre y color')),
          const PopupMenuItem(value: 'export', child: Text('Exportar a .ics…')),
          if (cal.source == 'caldav') const PopupMenuItem(value: 'sync', child: Text('Sincronizar ahora')),
          const PopupMenuItem(value: 'default', child: Text('Usar por defecto')),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'delete', child: Text(cal.source == 'caldav' ? 'Quitar de este equipo' : 'Eliminar', style: TextStyle(color: context.tk.danger))),
        ],
        onSelected: (v) async {
          try {
            switch (v) {
              case 'edit':
                await editCalendarDialog(context, store, cal);
              case 'export':
                final p = await pickFile(mode: 'save', title: 'Exportar «${cal.name}»', extensions: ['ics'], filterName: 'iCalendar', defaultName: '${cal.name}.ics');
                if (p != null) {
                  final n = Core.call('ics.export', {'calendarId': cal.id, 'path': p});
                  if (await finishSave(p) && context.mounted) showInfo(context, 'Exportados $n elementos');
                }
              case 'sync':
                await store.syncNow();
              case 'default':
                if (cal.hasEvents) store.settings.defaultCalendarId = cal.id;
                if (cal.hasTasks) store.settings.defaultListId = cal.id;
                store.settings.save();
                store.reload();
              case 'delete':
                final msg = cal.source == 'caldav'
                    ? 'Se quitará «${cal.name}» de este equipo. Los datos del servidor no se borran.'
                    : cal.source == 'ics'
                        ? 'Se dejará de enlazar «${cal.name}». El archivo .ics no se borra.'
                        : 'Se borrarán «${cal.name}» y todos sus eventos y tareas de este equipo.';
                if (await confirm(context, 'Eliminar calendario', msg)) store.mutate('calendars.delete', {'id': cal.id});
            }
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        },
      );
}

class AddSourceButton extends StatelessWidget {
  const AddSourceButton({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'Añadir',
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 230),
        icon: Icon(Icons.add_rounded, color: context.tk.sec),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'new', child: Text('Nuevo calendario o lista')),
          if (isDesktop) const PopupMenuItem(value: 'link', child: Text('Enlazar archivo .ics…')),
          const PopupMenuItem(value: 'import', child: Text('Importar .ics…')),
          const PopupMenuItem(value: 'caldav', child: Text('Añadir cuenta CalDAV…')),
        ],
        onSelected: (v) => addSource(context, store, v),
      );
}

Future<void> addSource(BuildContext context, AppStore store, String v) async {
  try {
    switch (v) {
      case 'new':
        await editCalendarDialog(context, store, null);
      case 'link':
        final p = await pickFile(title: 'Enlazar archivo .ics', extensions: ['ics'], filterName: 'iCalendar');
        if (p != null) {
          final r = Core.call('ics.link', {'path': p}) as Map;
          store.reload();
          if (context.mounted) showInfo(context, 'Enlazado «${(r['calendar'] as Map)['name']}» (${r['count']} elementos). Los cambios se guardarán en el archivo.');
        }
      case 'import':
        final p = await pickFile(title: 'Importar archivo .ics', extensions: ['ics'], filterName: 'iCalendar');
        if (p != null) {
          final r = await Core.callAsync('ics.import', {'path': p});
          store.reload();
          if (context.mounted) showInfo(context, 'Importados ${(r as Map)['count']} elementos en «${(r['calendar'] as Map)['name']}».');
        }
      case 'caldav':
        await showAddCalDav(context, store);
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> editCalendarDialog(BuildContext context, AppStore store, Calendar? cal) async {
  final name = TextEditingController(text: cal?.name ?? '');
  var color = cal?.colorValue ?? calendarPalette[1];
  var kind = cal?.kind ?? 'both';
  String? accountId;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(cal == null ? 'Nuevo calendario o lista' : 'Editar «${cal.name}»', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: name, autofocus: true, decoration: const InputDecoration(hintText: 'Nombre')),
            const SizedBox(height: 14),
            ColorRow(value: color, onChanged: (v) => set(() => color = v)),
            if (cal == null) ...[
              const SizedBox(height: 14),
              PillSegmented<String>(
                compact: true,
                values: const ['both', 'events', 'tasks'],
                labels: const ['Eventos y tareas', 'Solo eventos', 'Solo tareas'],
                selected: kind,
                onChanged: (v) => set(() => kind = v),
              ),
              if (store.accounts.isNotEmpty) ...[
                const SizedBox(height: 14),
                DropdownButton<String?>(
                  value: accountId,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('En este equipo')),
                    for (final a in store.accounts) DropdownMenuItem(value: a.id, child: Text('En ${a.name} (CalDAV)')),
                  ],
                  onChanged: (v) => set(() => accountId = v),
                ),
              ],
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              try {
                if (cal != null) {
                  cal.name = name.text.trim();
                  cal.color = toHex(color);
                  store.mutate('calendars.save', {'calendar': cal.toJson()});
                } else if (accountId != null) {
                  await Core.callAsync('caldav.createCalendar', {'accountId': accountId, 'name': name.text.trim(), 'color': toHex(color), 'kind': kind});
                  store.reload();
                } else {
                  store.mutate('calendars.save', {'calendar': Calendar(name: name.text.trim(), color: toHex(color), kind: kind).toJson()});
                }
                if (c.mounted) Navigator.pop(c);
              } catch (e) {
                if (c.mounted) showError(c, e);
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------------ tareas

class TaskSidebar extends StatelessWidget {
  const TaskSidebar({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final c = store.counts;
    final groups = grouped(store, store.calendars.where((c) => c.hasTasks).toList());
    Widget card(String smart, String label, int n, Color color, IconData icon) {
      final sel = store.taskScope == TaskScope.smart(smart);
      return Material(
        color: sel ? t.accent : t.card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => store.selectScope(TaskScope.smart(smart)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(color: sel ? Colors.white : color, shape: BoxShape.circle),
                  child: Icon(icon, size: 15, color: sel ? color : Colors.white),
                ),
                const Spacer(),
                Text('$n', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: sel ? Colors.white : t.text)),
              ]),
              const SizedBox(height: 8),
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sel ? Colors.white : t.sec)),
            ]),
          ),
        ),
      );
    }

    return FloatingPanel(
      width: 260,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Header(store: store),
        Expanded(
          child: ListView(children: [
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.75,
              children: [
                card('today', 'Hoy', c.today, const Color(0xFF007AFF), Icons.calendar_today_rounded),
                card('scheduled', 'Programadas', c.scheduled, const Color(0xFFFF3B30), Icons.schedule_rounded),
                card('all', 'Todas', c.all, const Color(0xFF48484A), Icons.inbox_rounded),
                card('flagged', 'Marcadas', c.flagged, const Color(0xFFFF9500), Icons.flag_rounded),
              ],
            ),
            const SizedBox(height: 8),
            card('completed', 'Completadas', c.completed, const Color(0xFF8E8E93), Icons.check_rounded),
            const SizedBox(height: 14),
            for (final g in groups.entries) ...[
              SectionLabel(g.key, trailing: g.key == groups.keys.first ? AddSourceButton(store: store) : null),
              for (final l in g.value) _ListRow(store: store, cal: l, count: c.lists[l.id] ?? 0),
              const SizedBox(height: 10),
            ],
            if (c.tags.isNotEmpty) ...[
              const SectionLabel('Etiquetas'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Wrap(spacing: 5, runSpacing: 5, children: [
                  for (final tg in c.tags)
                    Material(
                      color: store.taskScope == TaskScope.tag(tg.key) ? t.accent : t.tag,
                      borderRadius: BorderRadius.circular(999),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => store.selectScope(TaskScope.tag(tg.key)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                          child: Text(tg.key, style: TextStyle(fontSize: 12, color: store.taskScope == TaskScope.tag(tg.key) ? Colors.white : t.text)),
                        ),
                      ),
                    ),
                ]),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 6),
        syncLine(context, store),
      ]),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({required this.store, required this.cal, required this.count});
  final AppStore store;
  final Calendar cal;
  final int count;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final sel = store.taskScope == TaskScope.list(cal.id);
    return Material(
      color: sel ? t.pill : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => store.selectScope(TaskScope.list(cal.id)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 3, 0, 3),
          child: Row(children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(color: cal.colorValue, shape: BoxShape.circle),
              child: const Icon(Icons.format_list_bulleted_rounded, size: 13, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(cal.name, style: TextStyle(fontWeight: sel ? FontWeight.w600 : FontWeight.w400), overflow: TextOverflow.ellipsis)),
            Text('$count', style: TextStyle(color: t.sec)),
            CalendarMenu(store: store, cal: cal),
          ]),
        ),
      ),
    );
  }
}

/// Encabezado común del mes/año con navegación.
class PeriodHeader extends StatelessWidget {
  const PeriodHeader({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final a = store.anchor;
    final title = switch (store.view) {
      CalView.year => Text('${a.year}', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
      CalView.day => Text.rich(TextSpan(children: [
          TextSpan(text: '${a.day} de ${monthNames[a.month - 1]} ', style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: '${a.year}  ', style: const TextStyle(fontWeight: FontWeight.w400)),
          TextSpan(text: capitalize(weekdayLong[a.weekday - 1]), style: TextStyle(fontWeight: FontWeight.w400, fontSize: 18, color: context.tk.sec)),
        ]), style: const TextStyle(fontSize: 30)),
      _ => Text.rich(TextSpan(children: [
          TextSpan(text: '${capitalize(monthNames[a.month - 1])} ', style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: '${a.year}', style: const TextStyle(fontWeight: FontWeight.w400)),
        ]), style: const TextStyle(fontSize: 30)),
    };
    final unit = switch (store.view) { CalView.day => 'Día', CalView.week => 'Semana', CalView.month => 'Mes', CalView.year => 'Año' };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 16, 10),
      child: Row(children: [
        Expanded(child: title),
        SmallPill(icon: Icons.chevron_left_rounded, tooltip: '$unit anterior', onTap: () => store.step(-1)),
        const SizedBox(width: 6),
        SmallPill(label: 'Hoy', tooltip: 'Ir a hoy (Ctrl+T)', onTap: store.today),
        const SizedBox(width: 6),
        SmallPill(icon: Icons.chevron_right_rounded, tooltip: '$unit siguiente', onTap: () => store.step(1)),
      ]),
    );
  }
}
