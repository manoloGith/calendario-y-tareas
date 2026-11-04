// Editor de eventos: captura rápida, fechas, repetición, avisos y ámbito para eventos recurrentes.
import 'package:flutter/material.dart';

import '../../core/bridge.dart';
import '../../core/dates.dart';
import '../../core/models.dart';
import '../../core/platform.dart';
import '../../core/store.dart';
import '../attachments.dart';
import '../common.dart';
import '../theme.dart';

/// Abre el editor. Para una ocurrencia de un evento recurrente se pasa `occurrence`.
Future<void> openEventEditor(BuildContext context, AppStore store, {String? eventId, Occurrence? occurrence, DateTime? start, bool allDay = false}) async {
  final cal = store.defaultCalendarId;
  if (cal == null && eventId == null) {
    showError(context, 'Crea primero un calendario en el que se pueda escribir.');
    return;
  }
  EventData data;
  if (eventId != null) {
    data = store.event(eventId);
    if (occurrence != null && data.recurring) {
      // Se edita la ocurrencia concreta: se muestran sus fechas.
      final dur = DateTime.parse(data.end).difference(DateTime.parse(data.start));
      final os = DateTime.parse(occurrence.originalStart);
      data.start = data.allDay ? fmtCoreDate(os) : fmtCore(os);
      data.end = data.allDay ? fmtCoreDate(os.add(dur)) : fmtCore(os.add(dur));
    }
  } else {
    final s = start ?? DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day, DateTime.now().hour + 1);
    data = EventData(
      calendarId: cal!,
      start: allDay ? fmtCoreDate(s) : fmtCore(s),
      end: allDay ? fmtCoreDate(addDays(s, 1)) : fmtCore(s.add(const Duration(hours: 1))),
      allDay: allDay,
      alarms: allDay ? [] : [10],
    );
  }
  if (isMobile) {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => EventEditor(store: store, data: data, occurrence: occurrence, fullScreen: true),
    ));
    return;
  }
  await showDialog<void>(context: context, builder: (_) => EventEditor(store: store, data: data, occurrence: occurrence));
}

class EventEditor extends StatefulWidget {
  const EventEditor({super.key, required this.store, required this.data, this.occurrence, this.fullScreen = false});
  /// Móvil: el editor ocupa toda la pantalla.
  final bool fullScreen;
  final AppStore store;
  final EventData data;
  final Occurrence? occurrence;
  @override
  State<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<EventEditor> {
  late final EventData e = widget.data;
  late final TextEditingController title = TextEditingController(text: e.title);
  late final TextEditingController location = TextEditingController(text: e.location);
  late final TextEditingController notes = TextEditingController(text: e.notes);
  late DateTime start = DateTime.parse(e.start);
  late DateTime end = e.allDay ? addDays(DateTime.parse(e.end), -1) : DateTime.parse(e.end);
  late final String? originalRule = e.rrule;
  late final String originalStart = e.start;
  String? hint;
  final pendingAttachments = <Attachment>[];

  bool get isNew => e.id.isEmpty;

  @override
  void dispose() {
    title.dispose();
    location.dispose();
    notes.dispose();
    super.dispose();
  }

  /// Interpreta el título como lenguaje natural mientras se escribe (solo en eventos nuevos).
  void _parse(String text) {
    if (!isNew || text.trim().isEmpty) {
      setState(() => hint = null);
      return;
    }
    final q = QuickParse.fromJson(Core.call('nlp.parse', {'text': text}) as Map<String, dynamic>);
    if (q.date == null && q.rrule == null) {
      setState(() => hint = null);
      return;
    }
    final parts = <String>[];
    if (q.date != null) {
      final d = DateTime.parse(q.date!);
      parts.add(q.hasTime ? '${shortDate(d)}, ${fmtTime(d)}' : '${shortDate(d)} (todo el día)');
    }
    if (q.rrule != null) parts.add(describeRule(q.rrule));
    setState(() => hint = '«${q.title}» · ${parts.join(' · ')} — pulsa Intro para aplicar');
  }

  void _applyParse() {
    final q = QuickParse.fromJson(Core.call('nlp.parse', {'text': title.text}) as Map<String, dynamic>);
    setState(() {
      title.text = q.title;
      if (q.date != null) {
        final d = DateTime.parse(q.date!);
        e.allDay = !q.hasTime;
        start = d;
        end = e.allDay ? d : d.add(Duration(minutes: q.durationMin));
      }
      if (q.rrule != null) e.rrule = q.rrule;
      hint = null;
    });
  }

  Future<void> _save() async {
    if (title.text.trim().isEmpty) return showError(context, 'Escribe un título');
    if (!e.allDay && !end.isAfter(start)) end = start.add(const Duration(hours: 1));
    e.title = title.text.trim();
    e.location = location.text.trim();
    e.notes = notes.text.trim();
    e.start = e.allDay ? fmtCoreDate(start) : fmtCore(start);
    e.end = e.allDay ? fmtCoreDate(addDays(dateOnly(end.isBefore(start) ? start : end), 1)) : fmtCore(end);
    var scope = 'all';
    String? occ;
    final wasRecurring = originalRule != null && originalRule!.isNotEmpty;
    // Si se cambia la propia repetición, el cambio es de toda la serie: no se pregunta.
    final ruleChanged = (e.rrule ?? '') != (originalRule ?? '');
    if (!isNew && wasRecurring && !ruleChanged) {
      final s = await askScope(context, deleting: false);
      if (s == null) return;
      scope = s;
      // Abierto desde la búsqueda (sin ocurrencia concreta): se usa la primera de la serie.
      occ = widget.occurrence?.originalStart ?? originalStart;
      if (scope == 'all') {
        // Al cambiar «todas», se conserva el desplazamiento aplicado sobre la serie original.
        final master = widget.store.event(e.id);
        final delta = start.difference(DateTime.parse(originalStart));
        final ms = DateTime.parse(master.start).add(delta);
        final dur = (e.allDay ? DateTime.parse(e.end) : end).difference(e.allDay ? DateTime.parse(e.start) : start);
        e.start = e.allDay ? fmtCoreDate(ms) : fmtCore(ms);
        e.end = e.allDay ? fmtCoreDate(ms.add(dur)) : fmtCore(ms.add(dur));
        e.exdates = master.exdates;
      }
    }
    try {
      final saved = widget.store.mutate('events.save', {'event': e.toJson(), 'scope': scope, 'occurrence': ?occ}) as Map<String, dynamic>;
      for (final a in pendingAttachments) {
        await Core.callAsync('attachments.add', {
          'ownerKind': 'event',
          'ownerId': saved['id'],
          'kind': a.kind,
          if (a.kind == 'link') 'url': a.target else 'path': a.target,
        });
      }
      if (pendingAttachments.isNotEmpty) widget.store.reload();
      if (mounted) Navigator.pop(context);
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }

  Future<void> _delete() async {
    var scope = 'all';
    final wasRecurring = originalRule != null && originalRule!.isNotEmpty;
    if (wasRecurring) {
      final s = await askScope(context, deleting: true);
      if (s == null) return;
      scope = s;
    } else if (!await confirm(context, 'Eliminar evento', '¿Eliminar «${e.title}»?')) {
      return;
    }
    try {
      widget.store.mutate('events.delete', {'id': e.id, 'scope': scope, 'occurrence': widget.occurrence?.originalStart ?? originalStart});
      if (mounted) Navigator.pop(context);
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final cals = widget.store.writableEventCalendars;
    final cal = widget.store.calendar(e.calendarId);
    final readonly = cal?.readonly ?? false;
    Widget label(String s) => SizedBox(width: 96, child: Text(s, style: TextStyle(color: t.sec)));
    final content = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(width: 12, height: 12, decoration: BoxDecoration(color: cal?.colorValue ?? t.accent, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Text(isNew ? 'Nuevo evento' : (readonly ? 'Evento (solo lectura)' : 'Editar evento'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: title,
              autofocus: isNew,
              readOnly: readonly,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              decoration: InputDecoration(hintText: isNew ? 'Título… o «Cena con Ana el viernes a las 21h»' : 'Título'),
              onChanged: _parse,
              onSubmitted: (_) => hint != null ? _applyParse() : _save(),
            ),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: InkWell(onTap: _applyParse, child: Text(hint!, style: TextStyle(fontSize: 12, color: t.accent))),
              ),
            const SizedBox(height: 14),
            Row(children: [
              label('Todo el día'),
              Switch(value: e.allDay, onChanged: readonly ? null : (v) => setState(() => e.allDay = v)),
            ]),
            const SizedBox(height: 6),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 0, runSpacing: 6, children: [
              label('Fecha inicio'),
              DateField(
                value: start,
                onChanged: (d) => setState(() {
                  final dur = end.difference(start);
                  start = d;
                  end = d.add(dur);
                }),
              ),
              if (!e.allDay) ...[
                const SizedBox(width: 8),
                TimeField(
                  value: start,
                  onChanged: (d) => setState(() {
                    final dur = end.difference(start);
                    start = d;
                    end = d.add(dur);
                  }),
                ),
              ],
            ]),
            const SizedBox(height: 8),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 0, runSpacing: 6, children: [
              label('Fecha fin'),
              DateField(value: end, onChanged: (d) => setState(() => end = d)),
              if (!e.allDay) ...[const SizedBox(width: 8), TimeField(value: end, onChanged: (d) => setState(() => end = d))],
            ]),
            const SizedBox(height: 10),
            Row(children: [
              label('Repetir'),
              DropdownButton<String?>(
                value: repeatOptions.containsKey(e.rrule) ? e.rrule : '__custom',
                items: [
                  for (final o in repeatOptions.entries) DropdownMenuItem(value: o.key, child: Text(o.value)),
                  if (!repeatOptions.containsKey(e.rrule)) DropdownMenuItem(value: '__custom', child: Text(describeRule(e.rrule))),
                ],
                onChanged: readonly ? null : (v) => setState(() => e.rrule = v == '__custom' ? e.rrule : v),
              ),
            ]),
            if (!e.allDay)
              Row(children: [
                label('Aviso'),
                DropdownButton<int?>(
                  value: e.alarms.isEmpty ? null : (alarmOptions.containsKey(e.alarms.first) ? e.alarms.first : null),
                  items: [for (final o in alarmOptions.entries) DropdownMenuItem(value: o.key, child: Text(o.value))],
                  onChanged: readonly ? null : (v) => setState(() => e.alarms = v == null ? [] : [v]),
                ),
              ]),
            Row(children: [
              label('Calendario'),
              DropdownButton<String>(
                value: cals.any((c) => c.id == e.calendarId) ? e.calendarId : null,
                hint: Text(cal?.name ?? ''),
                items: [
                  for (final c in cals)
                    DropdownMenuItem(
                      value: c.id,
                      child: Row(children: [CircleAvatar(radius: 5, backgroundColor: c.colorValue), const SizedBox(width: 8), Text(c.name)]),
                    ),
                ],
                onChanged: readonly ? null : (v) => setState(() => e.calendarId = v ?? e.calendarId),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(controller: location, readOnly: readonly, decoration: const InputDecoration(hintText: 'Ubicación', prefixIcon: Icon(Icons.place_outlined, size: 17))),
            const SizedBox(height: 8),
            TextField(controller: notes, readOnly: readonly, minLines: 2, maxLines: 6, decoration: const InputDecoration(hintText: 'Notas')),
            const SizedBox(height: 12),
            AttachmentsSection(store: widget.store, ownerKind: 'event', ownerId: isNew ? null : e.id, pending: pendingAttachments, readonly: readonly),
            const SizedBox(height: 16),
            if (widget.fullScreen)
              Row(children: [
                if (!isNew && !readonly) TextButton.icon(onPressed: _delete, icon: Icon(Icons.delete_outline_rounded, color: t.danger), label: Text('Eliminar evento', style: TextStyle(color: t.danger))),
              ])
            else
              Row(children: [
                if (!isNew && !readonly) TextButton(onPressed: _delete, child: Text('Eliminar', style: TextStyle(color: t.danger))),
                const Spacer(),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
                const SizedBox(width: 6),
                if (!readonly) FilledButton(onPressed: _save, child: const Text('Guardar')),
              ]),
          ]);
    // Móvil: pantalla completa, con «Guardar» en la barra superior.
    if (widget.fullScreen) {
      return Scaffold(
        backgroundColor: t.window,
        appBar: AppBar(
          backgroundColor: t.window,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(tooltip: 'Cancelar', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
          title: Text(isNew ? 'Nuevo evento' : 'Editar evento', style: const TextStyle(fontWeight: FontWeight.w700)),
          actions: [
            if (!readonly)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton(onPressed: _save, child: const Text('Guardar')),
              ),
          ],
        ),
        body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), child: content)),
      );
    }
    return Dialog(
      child: SizedBox(
        width: 520,
        child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(22, 20, 22, 16), child: content),
      ),
    );
  }
}
