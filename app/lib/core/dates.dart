// Fechas: formato del núcleo ("YYYY-MM-DDTHH:MM:SS", hora local) y textos en español.

const monthNames = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];
const monthShort = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const weekdayShort = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
const weekdayLong = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
const weekdayLetter = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];

String _2(int n) => n.toString().padLeft(2, '0');

String fmtCore(DateTime d) => '${d.year}-${_2(d.month)}-${_2(d.day)}T${_2(d.hour)}:${_2(d.minute)}:${_2(d.second)}';
String fmtCoreDate(DateTime d) => '${d.year}-${_2(d.month)}-${_2(d.day)}';
String fmtTime(DateTime d) => '${d.hour}:${_2(d.minute)}';
String capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// Lunes de la semana de `d`.
DateTime startOfWeek(DateTime d) => dateOnly(d).subtract(Duration(days: d.weekday - 1));
DateTime startOfMonth(DateTime d) => DateTime(d.year, d.month, 1);
DateTime addMonths(DateTime d, int n) => DateTime(d.year, d.month + n, 1);
DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n, d.hour, d.minute);

/// Primer día de la cuadrícula mensual (6 semanas, empezando en lunes).
DateTime monthGridStart(DateTime month) => startOfWeek(startOfMonth(month));

String longDate(DateTime d) => '${weekdayLong[d.weekday - 1]}, ${d.day} de ${monthNames[d.month - 1]}';
String shortDate(DateTime d) => '${weekdayShort[d.weekday - 1]} ${d.day} ${monthShort[d.month - 1]}';

/// Texto relativo para vencimientos: «Hoy», «Mañana», «Ayer», «jue 12 nov» y la hora si la tiene.
String relativeDue(String due) {
  final d = DateTime.tryParse(due);
  if (d == null) return due;
  final today = dateOnly(DateTime.now());
  final diff = dateOnly(d).difference(today).inDays;
  String day;
  if (diff == 0) {
    day = 'Hoy';
  } else if (diff == 1) {
    day = 'Mañana';
  } else if (diff == -1) {
    day = 'Ayer';
  } else if (d.year == today.year) {
    day = shortDate(d);
  } else {
    day = '${shortDate(d)} ${d.year}';
  }
  return due.contains('T') ? '$day, ${fmtTime(d)}' : day;
}

/// Descripción breve de una regla RRULE común.
String describeRule(String? rule) {
  if (rule == null || rule.isEmpty) return 'Nunca';
  final parts = {for (final p in rule.split(';')) if (p.contains('=')) p.split('=')[0]: p.split('=')[1]};
  final freq = parts['FREQ'];
  final interval = int.tryParse(parts['INTERVAL'] ?? '1') ?? 1;
  final byday = parts['BYDAY'];
  if (freq == 'WEEKLY' && byday == 'MO,TU,WE,TH,FR') return 'Días laborables';
  const units = {'DAILY': ['día', 'días'], 'WEEKLY': ['semana', 'semanas'], 'MONTHLY': ['mes', 'meses'], 'YEARLY': ['año', 'años']};
  final u = units[freq];
  if (u == null) return 'Personalizada';
  var s = interval == 1 ? 'Cada ${u[0]}' : 'Cada $interval ${u[1]}';
  if (freq == 'WEEKLY' && byday != null) {
    const codes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
    final names = byday.split(',').map((c) => codes.indexOf(c)).where((i) => i >= 0).map((i) => weekdayLong[i]).join(', ');
    if (names.isNotEmpty) s += ' ($names)';
  }
  if (parts.containsKey('UNTIL')) s += ', con fin';
  return s;
}

/// Opciones de repetición que ofrece la interfaz.
const repeatOptions = <String?, String>{
  null: 'Nunca',
  'FREQ=DAILY': 'Cada día',
  'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR': 'Días laborables',
  'FREQ=WEEKLY': 'Cada semana',
  'FREQ=WEEKLY;INTERVAL=2': 'Cada 2 semanas',
  'FREQ=MONTHLY': 'Cada mes',
  'FREQ=YEARLY': 'Cada año',
};

const alarmOptions = <int?, String>{
  null: 'Sin aviso',
  0: 'Al empezar',
  5: '5 minutos antes',
  10: '10 minutos antes',
  15: '15 minutos antes',
  30: '30 minutos antes',
  60: '1 hora antes',
  1440: '1 día antes',
};
