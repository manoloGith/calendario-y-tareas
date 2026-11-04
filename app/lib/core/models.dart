// Modelos que reflejan el JSON del núcleo Rust (camelCase).
import 'dart:ui' show Color;

Color parseHex(String? hex, [Color fallback = const Color(0xFF007AFF)]) {
  if (hex == null) return fallback;
  var h = hex.replaceAll('#', '').trim();
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(v);
}

String toHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

class Calendar {
  Calendar({
    this.id = '',
    required this.name,
    this.color = '#007AFF',
    this.kind = 'both',
    this.source = 'local',
    this.visible = true,
    this.position = 0,
    this.icsPath,
    this.accountId,
    this.remoteUrl,
    this.readonly = false,
  });

  factory Calendar.fromJson(Map<String, dynamic> j) => Calendar(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        color: j['color'] as String? ?? '#007AFF',
        kind: j['kind'] as String? ?? 'both',
        source: j['source'] as String? ?? 'local',
        visible: j['visible'] as bool? ?? true,
        position: (j['position'] as num?)?.toInt() ?? 0,
        icsPath: j['icsPath'] as String?,
        accountId: j['accountId'] as String?,
        remoteUrl: j['remoteUrl'] as String?,
        readonly: j['readonly'] as bool? ?? false,
      );

  String id;
  String name;
  String color;
  String kind;
  String source;
  bool visible;
  int position;
  String? icsPath;
  String? accountId;
  String? remoteUrl;
  bool readonly;

  Color get colorValue => parseHex(color);
  bool get hasEvents => kind != 'tasks';
  bool get hasTasks => kind != 'events';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'kind': kind,
        'source': source,
        'visible': visible,
        'position': position,
        'icsPath': icsPath,
        'accountId': accountId,
        'remoteUrl': remoteUrl,
        'readonly': readonly,
      };
}

class Account {
  Account({required this.id, required this.name, required this.baseUrl, required this.username, this.altUrls = const [], this.activeUrl, this.lastSync, this.lastError});
  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        baseUrl: j['baseUrl'] as String? ?? '',
        altUrls: (j['altUrls'] as List?)?.cast<String>() ?? const [],
        activeUrl: j['activeUrl'] as String?,
        username: j['username'] as String? ?? '',
        lastSync: j['lastSync'] as String?,
        lastError: j['lastError'] as String?,
      );
  final String id;
  final String name;
  /// Dirección principal (p. ej. IP local) y alternativas (p. ej. VPN/Tailscale).
  final String baseUrl;
  final List<String> altUrls;
  /// Última dirección que respondió.
  final String? activeUrl;
  final String username;
  final String? lastSync;
  final String? lastError;

  List<String> get urls => [baseUrl, ...altUrls];
}

class EventData {
  EventData({
    this.id = '',
    required this.calendarId,
    this.title = '',
    this.notes = '',
    this.location = '',
    this.allDay = false,
    required this.start,
    required this.end,
    this.tzid = '',
    this.rrule,
    List<String>? exdates,
    List<int>? alarms,
  })  : exdates = exdates ?? [],
        alarms = alarms ?? [];

  factory EventData.fromJson(Map<String, dynamic> j) => EventData(
        id: j['id'] as String? ?? '',
        calendarId: j['calendarId'] as String,
        title: j['title'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
        location: j['location'] as String? ?? '',
        allDay: j['allDay'] as bool? ?? false,
        start: j['start'] as String,
        end: j['end'] as String,
        tzid: j['tzid'] as String? ?? '',
        rrule: j['rrule'] as String?,
        exdates: (j['exdates'] as List?)?.cast<String>(),
        alarms: (j['alarms'] as List?)?.map((e) => (e as num).toInt()).toList(),
      );

  String id;
  String calendarId;
  String title;
  String notes;
  String location;
  bool allDay;
  String start;
  String end;
  String tzid;
  String? rrule;
  List<String> exdates;
  List<int> alarms;

  bool get recurring => rrule != null && rrule!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'calendarId': calendarId,
        'title': title,
        'notes': notes,
        'location': location,
        'allDay': allDay,
        'start': start,
        'end': end,
        'tzid': tzid,
        'rrule': rrule,
        'exdates': exdates,
        'alarms': alarms,
      };
}

class Occurrence {
  Occurrence.fromJson(Map<String, dynamic> j)
      : eventId = j['eventId'] as String,
        calendarId = j['calendarId'] as String,
        color = j['color'] as String? ?? '#007AFF',
        title = j['title'] as String? ?? '',
        location = j['location'] as String? ?? '',
        notes = j['notes'] as String? ?? '',
        allDay = j['allDay'] as bool? ?? false,
        start = DateTime.parse(j['start'] as String),
        end = DateTime.parse(j['end'] as String),
        originalStart = j['originalStart'] as String,
        recurring = j['recurring'] as bool? ?? false,
        attachments = (j['attachments'] as num?)?.toInt() ?? 0;

  final String eventId;
  final String calendarId;
  final String color;
  final String title;
  final String location;
  final String notes;
  final bool allDay;
  final DateTime start;
  final DateTime end;
  final String originalStart;
  final bool recurring;
  final int attachments;

  Color get colorValue => parseHex(color);
}

class TaskData {
  TaskData({
    this.id = '',
    required this.listId,
    this.parentId,
    this.title = '',
    this.notes = '',
    this.start,
    this.due,
    this.tzid = '',
    this.priority = 0,
    this.flagged = false,
    List<String>? tags,
    this.rrule,
    this.completed = false,
    this.completedAt,
    this.section = '',
    this.position = 0,
    this.alarm,
  }) : tags = tags ?? [];

  factory TaskData.fromJson(Map<String, dynamic> j) => TaskData(
        id: j['id'] as String? ?? '',
        listId: j['listId'] as String,
        parentId: j['parentId'] as String?,
        title: j['title'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
        start: j['start'] as String?,
        due: j['due'] as String?,
        tzid: j['tzid'] as String? ?? '',
        priority: (j['priority'] as num?)?.toInt() ?? 0,
        flagged: j['flagged'] as bool? ?? false,
        tags: (j['tags'] as List?)?.cast<String>(),
        rrule: j['rrule'] as String?,
        completed: j['completed'] as bool? ?? false,
        completedAt: j['completedAt'] as String?,
        section: j['section'] as String? ?? '',
        position: (j['position'] as num?)?.toInt() ?? 0,
        alarm: (j['alarm'] as num?)?.toInt(),
      );

  String id;
  String listId;
  String? parentId;
  String title;
  String notes;
  /// Fecha de inicio (opcional) y de fin/vencimiento.
  String? start;
  String? due;
  String tzid;
  int priority;
  bool flagged;
  List<String> tags;
  String? rrule;
  bool completed;
  String? completedAt;
  String section;
  int position;
  int? alarm;

  bool get hasTime => due != null && due!.contains('T');
  bool get startHasTime => start != null && start!.contains('T');
  DateTime? get dueDate => due == null ? null : DateTime.tryParse(due!);
  DateTime? get startDate => start == null ? null : DateTime.tryParse(start!);
  bool get recurring => rrule != null && rrule!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'listId': listId,
        'parentId': parentId,
        'title': title,
        'notes': notes,
        'start': start,
        'due': due,
        'tzid': tzid,
        'priority': priority,
        'flagged': flagged,
        'tags': tags,
        'rrule': rrule,
        'completed': completed,
        'completedAt': completedAt,
        'section': section,
        'position': position,
        'alarm': alarm,
      };
}

class TaskNode {
  TaskNode.fromJson(Map<String, dynamic> j)
      : task = TaskData.fromJson(j),
        children = ((j['children'] as List?) ?? []).map((c) => TaskData.fromJson(c as Map<String, dynamic>)).toList(),
        subTotal = (j['subTotal'] as num?)?.toInt() ?? 0,
        subDone = (j['subDone'] as num?)?.toInt() ?? 0,
        listName = j['listName'] as String? ?? '',
        listColor = j['listColor'] as String? ?? '#007AFF',
        overdue = j['overdue'] as bool? ?? false,
        attachments = (j['attachments'] as num?)?.toInt() ?? 0;

  final TaskData task;
  final List<TaskData> children;
  final int subTotal;
  final int subDone;
  final String listName;
  final String listColor;
  final bool overdue;
  final int attachments;

  Color get color => parseHex(listColor);
}

class Counts {
  Counts({this.today = 0, this.scheduled = 0, this.all = 0, this.flagged = 0, this.completed = 0, Map<String, int>? lists, List<MapEntry<String, int>>? tags})
      : lists = lists ?? {},
        tags = tags ?? [];

  factory Counts.fromJson(Map<String, dynamic> j) => Counts(
        today: (j['today'] as num).toInt(),
        scheduled: (j['scheduled'] as num).toInt(),
        all: (j['all'] as num).toInt(),
        flagged: (j['flagged'] as num).toInt(),
        completed: (j['completed'] as num).toInt(),
        lists: {for (final l in (j['lists'] as List)) (l as List)[0] as String: (l[1] as num).toInt()},
        tags: [for (final t in (j['tags'] as List)) MapEntry((t as List)[0] as String, (t[1] as num).toInt())],
      );

  final int today;
  final int scheduled;
  final int all;
  final int flagged;
  final int completed;
  final Map<String, int> lists;
  final List<MapEntry<String, int>> tags;
}

class QuickParse {
  QuickParse.fromJson(Map<String, dynamic> j)
      : title = j['title'] as String? ?? '',
        date = j['date'] as String?,
        hasTime = j['hasTime'] as bool? ?? false,
        durationMin = (j['durationMin'] as num?)?.toInt() ?? 60,
        tags = (j['tags'] as List?)?.cast<String>() ?? [],
        priority = (j['priority'] as num?)?.toInt() ?? 0,
        rrule = j['rrule'] as String?;
  final String title;
  final String? date;
  final bool hasTime;
  final int durationMin;
  final List<String> tags;
  final int priority;
  final String? rrule;
}

/// Adjunto: documento (copia cifrada), enlace o carpeta.
class Attachment {
  Attachment.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String? ?? '',
        ownerKind = j['ownerKind'] as String? ?? '',
        ownerId = j['ownerId'] as String? ?? '',
        kind = j['kind'] as String,
        name = j['name'] as String? ?? '',
        target = j['target'] as String? ?? '',
        size = (j['size'] as num?)?.toInt() ?? 0;

  /// Adjunto aún no guardado (evento nuevo).
  Attachment.pending(this.kind, this.target, this.name)
      : id = '',
        ownerKind = '',
        ownerId = '',
        size = 0;

  final String id;
  final String ownerKind;
  final String ownerId;
  final String kind;
  final String name;
  final String target;
  final int size;
}

/// Cuenta del servidor de sincronización zero-knowledge.
class ZkAccount {
  ZkAccount.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String? ?? '',
        urls = (j['urls'] as List?)?.cast<String>() ?? const [],
        activeUrl = j['activeUrl'] as String?,
        username = j['username'] as String? ?? '',
        lastSync = j['lastSync'] as String?,
        lastError = j['lastError'] as String?;
  final String id;
  final String name;
  final List<String> urls;
  final String? activeUrl;
  final String username;
  final String? lastSync;
  final String? lastError;
}
