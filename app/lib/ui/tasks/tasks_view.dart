// Gestor de tareas estilo Recordatorios: lista con secciones, subtareas, etiquetas, recurrencias e inspector.
import 'package:flutter/material.dart';

import '../../core/bridge.dart';
import '../../core/dates.dart';
import '../../core/models.dart';
import '../../core/store.dart';
import '../attachments.dart';
import '../common.dart';
import '../theme.dart';

class TasksView extends StatefulWidget {
  const TasksView({super.key, required this.store});
  final AppStore store;
  @override
  State<TasksView> createState() => _TasksViewState();
}

class _TasksViewState extends State<TasksView> {
  final Set<String> expanded = {};
  final quick = TextEditingController();
  final quickFocus = FocusNode();
  String? quickHint;

  AppStore get store => widget.store;

  @override
  void dispose() {
    quick.dispose();
    quickFocus.dispose();
    super.dispose();
  }

  (String, Color) _title(Tokens t) {
    final s = store.taskScope;
    if (s.listId != null) {
      final c = store.calendar(s.listId!);
      return (c?.name ?? 'Lista', c == null ? t.accent : t.tintText(c.colorValue));
    }
    if (s.tag != null) return (s.tag!, t.text);
    return switch (s.smart) {
      'today' => ('Hoy', const Color(0xFF007AFF)),
      'scheduled' => ('Programadas', const Color(0xFFFF3B30)),
      'flagged' => ('Marcadas', const Color(0xFFFF9500)),
      'completed' => ('Completadas', t.sec),
      _ => ('Todas', t.text),
    };
  }

  void _quickChanged(String text) {
    if (text.trim().isEmpty) return setState(() => quickHint = null);
    final q = QuickParse.fromJson(Core.call('nlp.parse', {'text': text}) as Map<String, dynamic>);
    final parts = <String>[
      if (q.date != null) relativeDue(q.date!),
      if (q.rrule != null) describeRule(q.rrule),
      ...q.tags,
      if (q.priority > 0) '!' * q.priority,
    ];
    setState(() => quickHint = parts.isEmpty ? null : parts.join(' · '));
  }

  void _quickAdd() {
    final text = quick.text.trim();
    final list = store.defaultListId;
    if (text.isEmpty) return;
    if (list == null) return showError(context, 'Crea primero una lista de tareas.');
    try {
      final r = store.mutate('tasks.quickAdd', {'text': text, 'listId': list}) as Map<String, dynamic>;
      quick.clear();
      setState(() => quickHint = null);
      store.selectTask(r['id'] as String);
      quickFocus.requestFocus();
    } catch (e) {
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final scope = store.taskScope;
    final includeCompleted = store.showCompleted || scope.smart == 'completed';
    final nodes = store.tasks(scope, includeCompleted: includeCompleted);
    final (title, color) = _title(t);
    final pending = nodes.where((n) => !n.task.completed).length;
    final completedHidden = !includeCompleted && scope.listId != null ? (Core.call('tasks.list', {'filter': {...scope.toFilter(includeCompleted: true)}}) as List).length - nodes.length : 0;

    // Agrupar por sección (en listas) o por lista (en listas inteligentes).
    final groups = <String, List<TaskNode>>{};
    for (final n in nodes) {
      final key = scope.listId != null ? n.task.section : (scope.smart == 'today' || scope.smart == 'scheduled' ? _dayGroup(n) : n.listName);
      groups.putIfAbsent(key, () => []).add(n);
    }
    final selected = store.selectedTaskId;
    TaskNode? selNode;
    for (final n in nodes) {
      if (n.task.id == selected) selNode = n;
    }

    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (store.syncState == SyncState.offline)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(color: t.warnBg, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(Icons.wifi_off_rounded, size: 16, color: t.warn),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: 'Sin conexión. ', style: TextStyle(fontWeight: FontWeight.w700, color: t.warn)),
                    TextSpan(text: 'Los cambios se guardan cifrados en este equipo y se sincronizarán al volver la red.', style: TextStyle(color: t.warn)),
                  ]), style: const TextStyle(fontSize: 12)),
                ),
                if (store.pending > 0) Text('${store.pending} pendientes', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.warn)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 18, 4),
            child: Row(children: [
              Expanded(child: Text(title, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: color), overflow: TextOverflow.ellipsis)),
              Text('$pending', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600, color: color)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 16, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: quick,
                focusNode: quickFocus,
                decoration: InputDecoration(
                  hintText: 'Nueva tarea… «Pagar IBI mañana #casa !!»',
                  prefixIcon: Icon(Icons.add_circle_outline_rounded, size: 18, color: t.sec),
                ),
                onChanged: _quickChanged,
                onSubmitted: (_) => _quickAdd(),
              ),
              if (quickHint != null)
                Padding(padding: const EdgeInsets.only(left: 6, top: 4), child: Text(quickHint!, style: TextStyle(fontSize: 12, color: t.accent))),
            ]),
          ),
          Expanded(
            child: nodes.isEmpty
                ? Center(child: Text(scope.smart == 'completed' ? 'Aún no has completado tareas' : 'Nada pendiente', style: TextStyle(color: t.faint, fontSize: 15)))
                : ListView(padding: const EdgeInsets.fromLTRB(12, 0, 16, 16), children: [
                    for (final g in groups.entries) ...[
                      if (g.key.isNotEmpty || groups.length > 1)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 14, 0, 4),
                          child: Text(g.key.isEmpty ? 'Sin sección' : g.key, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
                      Divider(height: 1, color: t.border),
                      for (final n in g.value) ...[
                        _TaskRow(
                          store: store,
                          node: n,
                          selected: n.task.id == selected,
                          expanded: expanded.contains(n.task.id),
                          showList: scope.listId == null,
                          onExpand: () => setState(() => expanded.contains(n.task.id) ? expanded.remove(n.task.id) : expanded.add(n.task.id)),
                        ),
                        if (expanded.contains(n.task.id))
                          for (final c in n.children) _SubtaskRow(store: store, task: c, color: n.color),
                        if (expanded.contains(n.task.id)) _AddSubtask(store: store, parent: n.task),
                      ],
                    ],
                    if (completedHidden > 0 || store.showCompleted)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: store.toggleShowCompleted,
                          child: Text(store.showCompleted ? 'Ocultar completadas' : '$completedHidden completadas · Mostrar', style: TextStyle(color: t.sec)),
                        ),
                      ),
                  ]),
          ),
        ]),
      ),
      if (selNode != null) SizedBox(width: 350, child: TaskInspector(key: ValueKey('${selNode.task.id}@${store.revision}'), store: store, node: selNode)),
    ]);
  }

  String _dayGroup(TaskNode n) {
    final d = n.task.dueDate;
    if (d == null) return 'Sin fecha';
    if (n.overdue) return 'Vencidas';
    final diff = dateOnly(d).difference(dateOnly(DateTime.now())).inDays;
    if (diff == 0) return 'Hoy';
    if (diff == 1) return 'Mañana';
    return capitalize(longDate(d));
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.store, required this.node, required this.selected, required this.expanded, required this.onExpand, required this.showList});
  final AppStore store;
  final TaskNode node;
  final bool selected;
  final bool expanded;
  final bool showList;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final task = node.task;
    final meta = <Widget>[
      if (task.due != null || task.start != null)
        Text(taskDates(task.start, task.due), style: TextStyle(fontSize: 12, color: node.overdue ? t.danger : t.sec)),
      if (task.recurring)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.repeat_rounded, size: 12, color: t.sec),
          const SizedBox(width: 3),
          Text(describeRule(task.rrule), style: TextStyle(fontSize: 12, color: t.sec)),
        ]),
      for (final tag in task.tags) TagChip(tag, onTap: () => store.selectScope(TaskScope.tag(tag))),
      if (showList)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: node.color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(node.listName, style: TextStyle(fontSize: 12, color: t.sec)),
        ]),
      if (node.attachments > 0)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.attach_file_rounded, size: 12, color: t.sec),
          Text('${node.attachments}', style: TextStyle(fontSize: 12, color: t.sec)),
        ]),
      if (node.subTotal > 0)
        InkWell(
          onTap: onExpand,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 14, color: t.sec),
            Text('${node.subDone}/${node.subTotal} subtareas', style: TextStyle(fontSize: 12, color: t.sec)),
          ]),
        ),
    ];
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
      child: Material(
        color: selected ? t.sel : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => store.selectTask(selected ? null : task.id),
          onDoubleTap: node.subTotal > 0 ? onExpand : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: CheckCircle(
                  color: node.color,
                  done: task.completed,
                  label: task.title,
                  onTap: () {
                    try {
                      final r = store.mutate('tasks.toggle', {'id': task.id}) as Map<String, dynamic>;
                      if (task.recurring && r['completed'] != true && r['due'] != null) {
                        showInfo(context, '«${task.title}» pasa a ${relativeDue(r['due'] as String)}');
                      }
                    } catch (e) {
                      showError(context, e);
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (task.priority > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: Text('!' * task.priority, style: TextStyle(fontWeight: FontWeight.w800, color: t.accent)),
                      ),
                    Expanded(
                      child: Text(task.title,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: task.completed ? t.faint : t.text,
                            decoration: task.completed ? TextDecoration.lineThrough : null,
                          )),
                    ),
                    if (task.flagged) const Icon(Icons.flag_rounded, size: 15, color: Color(0xFFFF9500)),
                  ]),
                  if (task.notes.isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 2), child: Text(task.notes, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.sec))),
                  if (meta.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: meta)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SubtaskRow extends StatelessWidget {
  const _SubtaskRow({required this.store, required this.task, required this.color});
  final AppStore store;
  final TaskData task;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Container(
      margin: const EdgeInsets.only(left: 38),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
      child: Row(children: [
        CheckCircle(color: color, done: task.completed, size: 16, label: task.title, onTap: () => store.mutate('tasks.toggle', {'id': task.id})),
        const SizedBox(width: 10),
        Expanded(
          child: Text(task.title,
              style: TextStyle(fontSize: 12.5, color: task.completed ? t.faint : t.text, decoration: task.completed ? TextDecoration.lineThrough : null)),
        ),
        IconButton(
          tooltip: 'Eliminar subtarea',
          iconSize: 14,
          visualDensity: VisualDensity.compact,
          onPressed: () => store.mutate('tasks.delete', {'id': task.id}),
          icon: Icon(Icons.close_rounded, color: t.faint),
        ),
      ]),
    );
  }
}

class _AddSubtask extends StatefulWidget {
  const _AddSubtask({required this.store, required this.parent});
  final AppStore store;
  final TaskData parent;
  @override
  State<_AddSubtask> createState() => _AddSubtaskState();
}

class _AddSubtaskState extends State<_AddSubtask> {
  final c = TextEditingController();
  final f = FocusNode();
  @override
  void dispose() {
    c.dispose();
    f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(38, 4, 0, 6),
        child: TextField(
          controller: c,
          focusNode: f,
          style: const TextStyle(fontSize: 12.5),
          decoration: const InputDecoration(hintText: 'Añadir subtarea', prefixIcon: Icon(Icons.subdirectory_arrow_right_rounded, size: 16)),
          onSubmitted: (v) {
            if (v.trim().isEmpty) return;
            try {
              widget.store.mutate('tasks.quickAdd', {'text': v.trim(), 'listId': widget.parent.listId, 'parentId': widget.parent.id});
              c.clear();
              f.requestFocus();
            } catch (e) {
              showError(context, e);
            }
          },
        ),
      );
}

// ------------------------------------------------------------------ inspector

class TaskInspector extends StatefulWidget {
  const TaskInspector({super.key, required this.store, required this.node});
  final AppStore store;
  final TaskNode node;
  @override
  State<TaskInspector> createState() => _TaskInspectorState();
}

class _TaskInspectorState extends State<TaskInspector> {
  late TaskData task = widget.node.task;
  late final title = TextEditingController(text: task.title);
  late final notes = TextEditingController(text: task.notes);
  late final section = TextEditingController(text: task.section);
  final tagInput = TextEditingController();
  final titleFocus = FocusNode();

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    // Tarea recién creada (botón +, bandeja o widget): título listo para escribir.
    if (task.title == 'Nueva tarea') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        titleFocus.requestFocus();
        title.selection = TextSelection(baseOffset: 0, extentOffset: title.text.length);
      });
    }
  }

  @override
  void dispose() {
    title.dispose();
    notes.dispose();
    section.dispose();
    tagInput.dispose();
    titleFocus.dispose();
    super.dispose();
  }

  void _save() {
    task.title = title.text.trim().isEmpty ? task.title : title.text.trim();
    task.notes = notes.text;
    task.section = section.text.trim();
    try {
      store.mutate('tasks.save', {'task': task.toJson()});
    } catch (e) {
      showError(context, e);
      // Se vuelve a lo guardado para no mostrar un valor que no se ha aplicado.
      setState(() => task = store.task(task.id));
    }
  }

  Widget _icon(IconData icon, Color c) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 14, color: Colors.white),
      );

  /// Fila con icono, etiqueta y control que ocupa el resto del ancho (nunca se sale del panel).
  Widget _inline(Tokens t, IconData icon, Color c, String label, Widget control, {bool last = false}) => Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: t.border))),
        child: Row(children: [
          _icon(icon, c),
          const SizedBox(width: 10),
          SizedBox(width: 76, child: Text(label, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          Expanded(child: control),
        ]),
      );

  /// Fecha de inicio o de fin: etiqueta arriba y, debajo, fecha y hora (opcional), con botones para quitar.
  Widget _dateBlock(Tokens t, String label, IconData icon, Color c, String? value, ValueChanged<String?> onChanged) {
    final d = value == null ? null : DateTime.tryParse(value);
    final hasTime = value != null && value.contains('T');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _icon(icon, c),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
          if (d == null)
            TextButton(
              onPressed: () {
                final other = label == 'Fecha fin' ? task.startDate : null;
                onChanged(fmtCoreDate(other ?? DateTime.now()));
              },
              child: const Text('Añadir'),
            )
          else
            IconButton(
              tooltip: 'Quitar ${label.toLowerCase()}',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              onPressed: () => onChanged(null),
              icon: Icon(Icons.close_rounded, color: t.faint),
            ),
        ]),
        if (d != null)
          Padding(
            padding: const EdgeInsets.only(left: 34, top: 4),
            child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              DateField(value: d, onChanged: (n) => onChanged(hasTime ? fmtCore(n) : fmtCoreDate(n))),
              if (hasTime) ...[
                TimeField(value: d, onChanged: (n) => onChanged(fmtCore(n))),
                IconButton(
                  tooltip: 'Quitar la hora',
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onChanged(fmtCoreDate(d)),
                  icon: Icon(Icons.schedule_rounded, color: t.faint),
                ),
              ] else
                TextButton.icon(
                  onPressed: () => onChanged(fmtCore(DateTime(d.year, d.month, d.day, 9))),
                  icon: const Icon(Icons.schedule_rounded, size: 14),
                  label: const Text('Hora'),
                ),
            ]),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final lists = store.writableTaskLists;
    return FloatingPanel(
      padding: const EdgeInsets.all(14),
      child: ListView(children: [
        Row(children: [
          Text('Detalles', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.sec)),
          const Spacer(),
          IconButton(tooltip: 'Cerrar', iconSize: 16, onPressed: () => store.selectTask(null), icon: const Icon(Icons.close_rounded)),
        ]),
        TextField(
          controller: title,
          focusNode: titleFocus,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          decoration: const InputDecoration(filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, contentPadding: EdgeInsets.zero),
          onSubmitted: (_) => _save(),
          onTapOutside: (_) {
            if (title.text.trim() != task.title) _save();
          },
        ),
        TextField(
          controller: notes,
          minLines: 1,
          maxLines: 6,
          style: TextStyle(fontSize: 12.5, color: t.sec),
          decoration: const InputDecoration(hintText: 'Notas', filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 6)),
          onTapOutside: (_) {
            if (notes.text != task.notes) _save();
          },
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(color: t.card, borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            _dateBlock(t, 'Fecha inicio', Icons.play_arrow_rounded, const Color(0xFF34C759), task.start, (v) {
              task.start = v;
              _save();
            }),
            _dateBlock(t, 'Fecha fin', Icons.event_rounded, const Color(0xFFFF3B30), task.due, (v) {
              task.due = v;
              if (v == null) task.rrule = null;
              if (v == null || !v.contains('T')) task.alarm = null;
              _save();
            }),
            if (task.due != null)
              _inline(
                t,
                Icons.repeat_rounded,
                const Color(0xFF8E8E93),
                'Repetir',
                DropdownButton<String?>(
                  isExpanded: true,
                  isDense: true,
                  underline: const SizedBox(),
                  value: repeatOptions.containsKey(task.rrule) ? task.rrule : '__custom',
                  items: [
                    for (final o in repeatOptions.entries) DropdownMenuItem(value: o.key, child: Text(o.value, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                    if (!repeatOptions.containsKey(task.rrule))
                      DropdownMenuItem(value: '__custom', child: Text(describeRule(task.rrule), style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) {
                    if (v == '__custom') return;
                    task.rrule = v;
                    _save();
                  },
                ),
              ),
            if (task.hasTime)
              _inline(
                t,
                Icons.notifications_none_rounded,
                const Color(0xFFFF9500),
                'Aviso',
                DropdownButton<int?>(
                  isExpanded: true,
                  isDense: true,
                  underline: const SizedBox(),
                  value: alarmOptions.containsKey(task.alarm) ? task.alarm : null,
                  items: [for (final o in alarmOptions.entries) DropdownMenuItem(value: o.key, child: Text(o.value, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis))],
                  onChanged: (v) {
                    task.alarm = v;
                    _save();
                  },
                ),
              ),
            _inline(
              t,
              Icons.priority_high_rounded,
              const Color(0xFFFF3B30),
              'Prioridad',
              DropdownButton<int>(
                isExpanded: true,
                isDense: true,
                underline: const SizedBox(),
                value: task.priority,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Ninguna', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 1, child: Text('Baja (!)', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 2, child: Text('Media (!!)', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 3, child: Text('Alta (!!!)', style: TextStyle(fontSize: 13))),
                ],
                onChanged: (v) {
                  task.priority = v ?? 0;
                  _save();
                },
              ),
            ),
            _inline(
              t,
              Icons.flag_rounded,
              const Color(0xFFFF9500),
              'Marcada',
              Align(
                alignment: Alignment.centerRight,
                child: Switch(
                  value: task.flagged,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) {
                    task.flagged = v;
                    _save();
                  },
                ),
              ),
            ),
            if (task.parentId == null)
              _inline(
                t,
                Icons.format_list_bulleted_rounded,
                const Color(0xFF007AFF),
                'Lista',
                DropdownButton<String>(
                  isExpanded: true,
                  isDense: true,
                  underline: const SizedBox(),
                  value: lists.any((l) => l.id == task.listId) ? task.listId : null,
                  items: [for (final l in lists) DropdownMenuItem(value: l.id, child: Text(l.name, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis))],
                  onChanged: (v) {
                    if (v == null) return;
                    task.listId = v;
                    _save();
                  },
                ),
                last: true,
              ),
          ]),
        ),
        const SizedBox(height: 12),
        const SectionLabel('Etiquetas'),
        Wrap(spacing: 5, runSpacing: 5, children: [
          for (final tag in task.tags)
            TagChip(tag, onDelete: () {
              task.tags = task.tags.where((x) => x != tag).toList();
              _save();
            }),
          SizedBox(
            width: 120,
            child: TextField(
              controller: tagInput,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(hintText: '#etiqueta', contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5)),
              onSubmitted: (v) {
                final tags = v.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty);
                if (tags.isEmpty) return;
                task.tags = [...task.tags, ...tags];
                tagInput.clear();
                _save();
              },
            ),
          ),
        ]),
        if (task.parentId == null) ...[
          const SizedBox(height: 12),
          const SectionLabel('Sección'),
          TextField(
            controller: section,
            style: const TextStyle(fontSize: 12.5),
            decoration: const InputDecoration(hintText: 'p. ej. «Sprint 14»'),
            onSubmitted: (_) => _save(),
            onTapOutside: (_) {
              if (section.text.trim() != task.section) _save();
            },
          ),
          const SizedBox(height: 12),
          SectionLabel('Subtareas (${widget.node.subDone}/${widget.node.subTotal})'),
          for (final c in widget.node.children)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                CheckCircle(color: widget.node.color, done: c.completed, size: 15, label: c.title, onTap: () => store.mutate('tasks.toggle', {'id': c.id})),
                const SizedBox(width: 8),
                Expanded(child: Text(c.title, style: TextStyle(fontSize: 12.5, decoration: c.completed ? TextDecoration.lineThrough : null, color: c.completed ? t.faint : t.text))),
              ]),
            ),
          _AddSubtask(store: store, parent: task),
        ],
        const SizedBox(height: 12),
        AttachmentsSection(store: store, ownerKind: 'task', ownerId: task.id),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: t.okBg, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(Icons.lock_outline_rounded, size: 14, color: t.ok),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                store.calendar(task.listId)?.source == 'caldav'
                    ? (store.syncState == SyncState.offline ? 'Guardada cifrada en local · se subirá al reconectar' : 'Guardada cifrada en local · se sincroniza con CalDAV')
                    : store.zkAccounts.isNotEmpty
                        ? (store.syncState == SyncState.offline
                            ? 'Cifrada de extremo a extremo · se subirá al reconectar'
                            : 'Cifrada de extremo a extremo · se sincroniza con tu servidor')
                        : 'Guardada cifrada en este equipo',
                style: TextStyle(fontSize: 12, color: t.ok),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: () async {
            if (await confirm(context, 'Eliminar tarea', '¿Eliminar «${task.title}»${widget.node.subTotal > 0 ? ' y sus subtareas' : ''}?')) {
              store.selectTask(null);
              store.mutate('tasks.delete', {'id': task.id});
            }
          },
          icon: Icon(Icons.delete_outline_rounded, size: 16, color: t.danger),
          label: Text('Eliminar tarea', style: TextStyle(color: t.danger)),
        ),
      ]),
    );
  }
}
