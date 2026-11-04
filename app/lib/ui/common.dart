// Componentes de interfaz compartidos (estilo macOS).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/bridge.dart';
import '../core/dates.dart';
import 'theme.dart';

const calendarPalette = [
  Color(0xFFFF9500), Color(0xFF007AFF), Color(0xFF34C759), Color(0xFFAF52DE),
  Color(0xFFFFCC00), Color(0xFFFF3B30), Color(0xFFFF2D55), Color(0xFF5AC8FA), Color(0xFF8E8E93),
];

/// Botón circular con borde y sombra suave (barra de herramientas).
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.onTap, this.tooltip, this.size = 36, this.active = false});
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final btn = Material(
      color: active ? t.accent : t.glass,
      shape: CircleBorder(side: BorderSide(color: t.border)),
      elevation: 0,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: size, height: size, child: Icon(icon, size: size * .47, color: active ? Colors.white : t.text)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Selector en píldora (Día / Semana / Mes / Año…).
class PillSegmented<T> extends StatelessWidget {
  const PillSegmented({super.key, required this.values, required this.labels, required this.selected, required this.onChanged, this.compact = false});
  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: compact ? t.pill : t.glass,
        borderRadius: BorderRadius.circular(999),
        border: compact ? null : Border.all(color: t.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < values.length; i++)
          GestureDetector(
            onTap: () => onChanged(values[i]),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 17, vertical: compact ? 5 : 7),
                decoration: BoxDecoration(
                  color: values[i] == selected ? (compact ? t.pillSel : t.pill) : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(labels[i],
                    style: TextStyle(fontSize: 13, color: t.text, fontWeight: values[i] == selected ? FontWeight.w600 : FontWeight.w500)),
              ),
            ),
          ),
      ]),
    );
  }
}

class SmallPill extends StatelessWidget {
  const SmallPill({super.key, this.label, this.icon, required this.onTap, this.tooltip});
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final w = Material(
      color: t.pill,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 28,
          constraints: const BoxConstraints(minWidth: 28),
          padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 13),
          alignment: Alignment.center,
          child: label != null
              ? Text(label!, style: TextStyle(fontWeight: FontWeight.w500, color: t.text))
              : Icon(icon, size: 16, color: t.text),
        ),
      ),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

/// Casilla redonda de tarea (estilo Recordatorios).
class CheckCircle extends StatelessWidget {
  const CheckCircle({super.key, required this.color, required this.done, required this.onTap, this.size = 20, this.label});
  final Color color;
  final bool done;
  final VoidCallback onTap;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      checked: done,
      label: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? color : Colors.transparent,
              border: Border.all(color: done ? color : color.withValues(alpha: .9), width: 1.6),
            ),
            child: done ? Icon(Icons.check_rounded, size: size * .65, color: Colors.white) : null,
          ),
        ),
      ),
    );
  }
}

/// Semáforo de ventana. En macOS lo dibuja el sistema; en Windows y Linux es funcional.
class TrafficLights extends StatelessWidget {
  const TrafficLights({super.key});

  @override
  Widget build(BuildContext context) {
    if (Platform.isMacOS) return const SizedBox(width: 70, height: 14);
    Widget dot(Color c, IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: _Dot(color: c, icon: icon, onTap: onTap),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      dot(const Color(0xFFFF5F57), Icons.close_rounded, 'Cerrar', () => windowManager.close()),
      const SizedBox(width: 8),
      dot(const Color(0xFFFEBC2E), Icons.remove_rounded, 'Minimizar', () => windowManager.minimize()),
      const SizedBox(width: 8),
      dot(const Color(0xFF28C840), Icons.open_in_full_rounded, 'Maximizar', () async {
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      }),
    ]);
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color, required this.icon, required this.onTap});
  final Color color;
  final IconData icon;
  final VoidCallback onTap;
  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
            child: hover ? Icon(widget.icon, size: 9, color: Colors.black54) : null,
          ),
        ),
      );
}

/// Panel lateral flotante con bordes redondeados.
class FloatingPanel extends StatelessWidget {
  const FloatingPanel({super.key, required this.child, this.width, this.padding = const EdgeInsets.fromLTRB(12, 14, 12, 12)});
  final Widget child;
  final double? width;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Container(
      width: width,
      margin: const EdgeInsets.all(8),
      padding: padding,
      decoration: BoxDecoration(
        color: t.sidebar,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: t.sideBorder),
      ),
      child: child,
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 4, 4),
      child: Row(children: [
        Expanded(child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: t.sec), overflow: TextOverflow.ellipsis)),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// Mini calendario mensual (barra lateral, selector de fecha y widgets).
class MiniMonth extends StatelessWidget {
  const MiniMonth({
    super.key,
    required this.month,
    required this.onPick,
    this.selected,
    this.onMonth,
    this.dots = const {},
    this.cell = 26,
    this.highlightWeek = false,
    this.showHeader = true,
    this.onDoubleTap,
    this.todayColor = const Color(0xFFFF3B30),
  });
  /// Color del círculo de «hoy» (los widgets usan su color de acento).
  final Color todayColor;
  final DateTime month;
  /// Doble clic en un día (widgets: abre la app con el formulario de nuevo evento).
  final ValueChanged<DateTime>? onDoubleTap;
  final DateTime? selected;
  final ValueChanged<DateTime> onPick;
  final ValueChanged<DateTime>? onMonth;
  /// Días (yyyy-mm-dd) con un punto de color.
  final Map<String, Color> dots;
  final double cell;
  final bool highlightWeek;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final start = monthGridStart(month);
    final today = DateTime.now();
    final selWeek = selected == null ? null : startOfWeek(selected!);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (showHeader)
        Row(children: [
          if (onMonth != null)
            _arrow(context, Icons.chevron_left_rounded, 'Mes anterior', () => onMonth!(addMonths(month, -1))),
          Expanded(
            child: Text('${capitalize(monthNames[month.month - 1])} ${month.year}',
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (onMonth != null)
            _arrow(context, Icons.chevron_right_rounded, 'Mes siguiente', () => onMonth!(addMonths(month, 1))),
        ]),
      const SizedBox(height: 6),
      Row(children: [
        for (final l in weekdayLetter)
          SizedBox(width: cell, child: Text(l, textAlign: TextAlign.center, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: t.sec))),
      ]),
      for (var w = 0; w < 6; w++)
        Row(children: [
          for (var d = 0; d < 7; d++)
            Builder(builder: (context) {
              final day = DateTime(start.year, start.month, start.day + w * 7 + d);
              final isToday = sameDay(day, today);
              final isSel = selected != null && sameDay(day, selected!);
              final inMonth = day.month == month.month;
              final inWeek = highlightWeek && selWeek != null && sameDay(startOfWeek(day), selWeek);
              final dot = dots[fmtCoreDate(day)];
              return GestureDetector(
                onTap: () => onPick(day),
                onDoubleTap: onDoubleTap == null ? null : () => onDoubleTap!(day),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    width: cell,
                    height: cell + (dots.isEmpty ? 0 : 5),
                    color: inWeek ? t.sel : Colors.transparent,
                    alignment: Alignment.topCenter,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: cell - 3,
                        height: cell - 3,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isToday ? todayColor : (isSel ? t.pill : Colors.transparent),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('${day.day}',
                            style: TextStyle(
                              fontSize: cell * .43,
                              fontWeight: isToday || isSel ? FontWeight.w700 : FontWeight.w400,
                              color: isToday ? Colors.white : (inMonth ? t.text : t.faint),
                            )),
                        ),
                      ),
                      if (dots.isNotEmpty)
                        Container(width: 4, height: 4, margin: const EdgeInsets.only(top: 1), decoration: BoxDecoration(shape: BoxShape.circle, color: dot ?? Colors.transparent)),
                    ]),
                  ),
                ),
              );
            }),
        ]),
    ]);
  }

  Widget _arrow(BuildContext context, IconData i, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(borderRadius: BorderRadius.circular(6), onTap: onTap, child: Padding(padding: const EdgeInsets.all(3), child: Icon(i, size: 18, color: context.tk.sec))),
      );
}

/// Campo de fecha con calendario emergente.
class DateField extends StatelessWidget {
  const DateField({super.key, required this.value, required this.onChanged});
  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final d = await showDialog<DateTime>(context: context, builder: (_) => _DatePickerDialog(initial: value));
        if (d != null) onChanged(DateTime(d.year, d.month, d.day, value.hour, value.minute));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: t.pill, borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.calendar_today_rounded, size: 14, color: t.sec),
          const SizedBox(width: 6),
          Text('${shortDate(value)} ${value.year}'),
        ]),
      ),
    );
  }
}

class _DatePickerDialog extends StatefulWidget {
  const _DatePickerDialog({required this.initial});
  final DateTime initial;
  @override
  State<_DatePickerDialog> createState() => _DatePickerDialogState();
}

class _DatePickerDialogState extends State<_DatePickerDialog> {
  late DateTime month = startOfMonth(widget.initial);
  @override
  Widget build(BuildContext context) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: 7 * 34,
            child: MiniMonth(
              month: month,
              selected: widget.initial,
              cell: 34,
              onMonth: (m) => setState(() => month = m),
              onPick: (d) => Navigator.pop(context, d),
            ),
          ),
        ),
      );
}

/// Campo de hora: lista en pasos de 15 minutos y escritura libre (HH:MM).
class TimeField extends StatefulWidget {
  const TimeField({super.key, required this.value, required this.onChanged});
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  @override
  State<TimeField> createState() => _TimeFieldState();
}

class _TimeFieldState extends State<TimeField> {
  late final TextEditingController c = TextEditingController(text: fmtTime(widget.value));

  @override
  void didUpdateWidget(TimeField old) {
    super.didUpdateWidget(old);
    final s = fmtTime(widget.value);
    if (c.text != s) c.text = s;
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void _commit(String s) {
    final m = RegExp(r'^(\d{1,2})(?::|\.|h)?(\d{2})?$').firstMatch(s.trim());
    if (m == null) {
      c.text = fmtTime(widget.value);
      return;
    }
    final h = int.parse(m.group(1)!);
    final mi = int.tryParse(m.group(2) ?? '0') ?? 0;
    if (h > 23 || mi > 59) {
      c.text = fmtTime(widget.value);
      return;
    }
    final v = widget.value;
    widget.onChanged(DateTime(v.year, v.month, v.day, h, mi));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return SizedBox(
      width: 96,
      child: TextField(
        controller: c,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          prefixIcon: Icon(Icons.schedule_rounded, size: 15, color: t.sec),
          prefixIconConstraints: const BoxConstraints(minWidth: 30),
          suffixIcon: PopupMenuButton<int>(
            tooltip: 'Elegir hora',
            icon: Icon(Icons.expand_more_rounded, size: 16, color: t.sec),
            padding: EdgeInsets.zero,
            itemBuilder: (_) => [
              for (var q = 0; q < 96; q++)
                PopupMenuItem(value: q * 15, height: 30, child: Text('${q ~/ 4}:${((q % 4) * 15).toString().padLeft(2, '0')}')),
            ],
            onSelected: (mins) {
              final v = widget.value;
              widget.onChanged(DateTime(v.year, v.month, v.day, mins ~/ 60, mins % 60));
            },
          ),
          suffixIconConstraints: const BoxConstraints(minWidth: 28, maxHeight: 30),
        ),
        onSubmitted: _commit,
        onTapOutside: (_) => _commit(c.text),
      ),
    );
  }
}

/// Fila de colores para calendarios y listas.
class ColorRow extends StatelessWidget {
  const ColorRow({super.key, required this.value, required this.onChanged});
  final Color value;
  final ValueChanged<Color> onChanged;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in calendarPalette)
          GestureDetector(
            onTap: () => onChanged(c),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(color: c.toARGB32() == value.toARGB32() ? context.tk.text : Colors.transparent, width: 2),
              ),
            ),
          ),
      ]);
}

// ------------------------------------------------------------------ diálogos

void showError(BuildContext context, Object e) {
  final msg = e is CoreError ? e.message : e.toString();
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, width: 420));
}

void showInfo(BuildContext context, String msg) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, width: 420));
}

Future<bool> confirm(BuildContext context, String title, String message, {String ok = 'Eliminar', bool danger = true}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: context.tk.danger) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Para eventos recurrentes: «solo este», «este y los siguientes» o «todos». Devuelve null si se cancela.
Future<String?> askScope(BuildContext context, {required bool deleting}) => showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(deleting ? 'Eliminar evento recurrente' : 'Cambiar evento recurrente', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(deleting ? '¿Qué ocurrencias quieres eliminar?' : '¿A qué ocurrencias se aplica el cambio?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(c, 'all'), child: const Text('Todas')),
          TextButton(onPressed: () => Navigator.pop(c, 'future'), child: const Text('Esta y las siguientes')),
          FilledButton(onPressed: () => Navigator.pop(c, 'this'), child: const Text('Solo esta')),
        ],
      ),
    );

Future<String?> promptText(BuildContext context, String title, {String label = '', String initial = '', bool obscure = false, String ok = 'Aceptar'}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: 340,
        child: TextField(
          controller: ctl,
          autofocus: true,
          obscureText: obscure,
          decoration: InputDecoration(hintText: label),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(ok)),
      ],
    ),
  );
}

/// Diálogo nativo de archivos (vía núcleo Rust). Devuelve null si se cancela.
Future<String?> pickFile({String mode = 'open', String title = '', List<String> extensions = const [], String filterName = 'Archivos', String? defaultName}) async {
  final r = await Core.callAsync('sys.pickFile', {
    'mode': mode,
    'title': title,
    'extensions': extensions,
    'filterName': filterName,
    if (defaultName != null) 'defaultName': defaultName,
  });
  return r as String?;
}

/// Etiqueta #tag.
class TagChip extends StatelessWidget {
  const TagChip(this.tag, {super.key, this.onTap, this.onDelete});
  final String tag;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Material(
      color: t.tag,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(8, 2, onDelete == null ? 8 : 4, 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(tag, style: TextStyle(fontSize: 12, color: t.text)),
            if (onDelete != null)
              GestureDetector(onTap: onDelete, child: Padding(padding: const EdgeInsets.only(left: 2), child: Icon(Icons.close_rounded, size: 12, color: t.sec))),
          ]),
        ),
      ),
    );
  }
}
