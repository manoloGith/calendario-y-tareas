// Estado de la aplicación: bóveda abierta, calendarios, vista actual, sincronización y avisos.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'bridge.dart';
import 'dates.dart';
import 'models.dart';
import 'settings.dart';

enum AppMode { calendar, tasks }

enum CalView { day, week, month, year }

enum SyncState { idle, syncing, offline, error }

/// Qué lista de tareas se está mostrando.
class TaskScope {
  const TaskScope.smart(this.smart)
      : listId = null,
        tag = null;
  const TaskScope.list(this.listId)
      : smart = null,
        tag = null;
  const TaskScope.tag(this.tag)
      : smart = null,
        listId = null;
  final String? smart;
  final String? listId;
  final String? tag;

  Map<String, dynamic> toFilter({bool includeCompleted = false}) => {
        if (smart != null) 'smart': smart,
        if (listId != null) 'listId': listId,
        if (tag != null) 'tag': tag,
        'includeCompleted': includeCompleted,
      };

  @override
  bool operator ==(Object other) => other is TaskScope && other.smart == smart && other.listId == listId && other.tag == tag;
  @override
  int get hashCode => Object.hash(smart, listId, tag);
}

class AppStore extends ChangeNotifier {
  AppStore(this.settings, {this.isWidget = false});

  Settings settings;
  final bool isWidget;

  bool unlocked = false;
  List<Calendar> calendars = [];
  List<Account> accounts = [];
  Counts counts = Counts();

  AppMode mode = AppMode.calendar;
  CalView view = CalView.week;
  DateTime anchor = DateTime.now();

  TaskScope taskScope = const TaskScope.smart('today');
  String? selectedTaskId;
  bool showCompleted = false;

  SyncState syncState = SyncState.idle;
  String syncMessage = '';
  int pending = 0;

  /// Aumenta cada vez que cambian los datos (en este proceso o en otro): las vistas se recalculan.
  int revision = 0;
  int _dataVersion = -1;

  Timer? _poll;
  Timer? _syncTimer;
  Timer? _alarmTimer;
  DateTime _lastAlarmCheck = DateTime.now();
  int _ticks = 0;

  // ---------------------------------------------------------------- bóveda

  bool get vaultExists => Core.call('vault.exists', {'path': settings.vaultPath}) as bool;

  Future<void> create(String password, {bool remember = false}) async {
    await Core.callAsync('vault.create', {'path': settings.vaultPath, 'password': password, 'remember': remember});
    _afterUnlock();
  }

  Future<void> open({String? password, bool remember = false}) async {
    await Core.callAsync('vault.open', {
      'path': settings.vaultPath,
      if (password != null) 'password': password,
      'remember': remember,
    });
    _afterUnlock();
  }

  bool get remembered {
    try {
      return Core.call('vault.remembered', {'path': settings.vaultPath}) as bool;
    } catch (_) {
      return false;
    }
  }

  void lock() {
    Core.call('vault.lock');
    unlocked = false;
    _poll?.cancel();
    _syncTimer?.cancel();
    _alarmTimer?.cancel();
    notifyListeners();
  }

  void _afterUnlock() {
    unlocked = true;
    reload();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    if (!isWidget) {
      _alarmTimer = Timer.periodic(const Duration(seconds: 20), (_) => _checkAlarms());
      _syncTimer = Timer.periodic(Duration(minutes: settings.syncMinutes.clamp(1, 120)), (_) => syncNow(quiet: true));
      if (accounts.isNotEmpty) syncNow(quiet: true);
    }
    notifyListeners();
  }

  void _tick() {
    if (!unlocked) return;
    _ticks++;
    try {
      // Archivos .ics enlazados modificados por otros programas (cada 10 s).
      if (!isWidget && _ticks % 5 == 0) Core.call('ics.refresh');
      final v = Core.call('vault.dataVersion') as int;
      if (v != _dataVersion) {
        _dataVersion = v;
        reload();
      }
    } catch (_) {}
  }

  /// Relee calendarios y recuentos y repinta todo.
  void reload() {
    if (!unlocked) return;
    calendars = (Core.call('calendars.list') as List).map((c) => Calendar.fromJson(c as Map<String, dynamic>)).toList();
    accounts = (Core.call('caldav.accounts') as List).map((a) => Account.fromJson(a as Map<String, dynamic>)).toList();
    counts = Counts.fromJson(Core.call('tasks.counts') as Map<String, dynamic>);
    final info = Core.call('vault.info') as Map<String, dynamic>;
    pending = (info['pending'] as num).toInt();
    _dataVersion = (info['dataVersion'] as num).toInt();
    revision++;
    notifyListeners();
  }

  /// Ejecuta un cambio y refresca. Devuelve el resultado del núcleo.
  dynamic mutate(String method, Map<String, dynamic> params) {
    final r = Core.call(method, params);
    reload();
    return r;
  }

  // ---------------------------------------------------------------- consultas

  Calendar? calendar(String id) {
    for (final c in calendars) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<Calendar> get writableEventCalendars => calendars.where((c) => !c.readonly && c.hasEvents).toList();
  List<Calendar> get writableTaskLists => calendars.where((c) => !c.readonly && c.hasTasks).toList();

  String? get defaultCalendarId {
    final w = writableEventCalendars;
    if (w.isEmpty) return null;
    return w.any((c) => c.id == settings.defaultCalendarId) ? settings.defaultCalendarId : w.first.id;
  }

  String? get defaultListId {
    final w = writableTaskLists;
    if (w.isEmpty) return null;
    if (taskScope.listId != null && w.any((c) => c.id == taskScope.listId)) return taskScope.listId;
    return w.any((c) => c.id == settings.defaultListId) ? settings.defaultListId : w.first.id;
  }

  List<Occurrence> occurrences(DateTime from, DateTime to) {
    if (!unlocked) return [];
    final r = Core.call('events.range', {'from': fmtCore(from), 'to': fmtCore(to)}) as List;
    return r.map((o) => Occurrence.fromJson(o as Map<String, dynamic>)).toList();
  }

  List<TaskNode> tasksInRange(DateTime from, DateTime to) {
    if (!unlocked) return [];
    final r = Core.call('tasks.range', {'from': fmtCoreDate(from), 'to': fmtCoreDate(to)}) as List;
    return r.map((o) => TaskNode.fromJson(o as Map<String, dynamic>)).toList();
  }

  List<TaskNode> tasks(TaskScope scope, {bool includeCompleted = false}) {
    if (!unlocked) return [];
    final r = Core.call('tasks.list', {'filter': scope.toFilter(includeCompleted: includeCompleted)}) as List;
    return r.map((o) => TaskNode.fromJson(o as Map<String, dynamic>)).toList();
  }

  EventData event(String id) => EventData.fromJson(Core.call('events.get', {'id': id}) as Map<String, dynamic>);
  TaskData task(String id) => TaskData.fromJson(Core.call('tasks.get', {'id': id}) as Map<String, dynamic>);

  // ---------------------------------------------------------------- navegación

  void setMode(AppMode m) {
    mode = m;
    notifyListeners();
  }

  void setView(CalView v) {
    view = v;
    notifyListeners();
  }

  void goTo(DateTime d, {CalView? view}) {
    anchor = d;
    if (view != null) this.view = view;
    notifyListeners();
  }

  void today() => goTo(DateTime.now());

  void step(int dir) {
    switch (view) {
      case CalView.day:
        anchor = addDays(anchor, dir);
      case CalView.week:
        anchor = addDays(anchor, 7 * dir);
      case CalView.month:
        anchor = addMonths(anchor, dir);
      case CalView.year:
        anchor = DateTime(anchor.year + dir, anchor.month, 1);
    }
    notifyListeners();
  }

  void selectScope(TaskScope s) {
    taskScope = s;
    selectedTaskId = null;
    mode = AppMode.tasks;
    notifyListeners();
  }

  void selectTask(String? id) {
    selectedTaskId = id;
    notifyListeners();
  }

  void toggleShowCompleted() {
    showCompleted = !showCompleted;
    notifyListeners();
  }

  // ---------------------------------------------------------------- sincronización

  Future<void> syncNow({bool quiet = false}) async {
    if (accounts.isEmpty || syncState == SyncState.syncing) return;
    syncState = SyncState.syncing;
    syncMessage = 'Sincronizando…';
    notifyListeners();
    try {
      final res = (await Core.callAsync('caldav.sync')) as List;
      final failed = res.where((r) => (r as Map)['ok'] != true).toList();
      if (failed.isEmpty) {
        syncState = SyncState.idle;
        syncMessage = 'Sincronizado ${fmtTime(DateTime.now())}';
      } else {
        final msg = (failed.first as Map)['error'] as String? ?? '';
        final offline = msg.contains('red');
        syncState = offline ? SyncState.offline : SyncState.error;
        syncMessage = offline ? 'Sin conexión' : msg;
      }
    } on CoreError catch (e) {
      syncState = e.isOffline ? SyncState.offline : SyncState.error;
      syncMessage = e.isOffline ? 'Sin conexión' : e.message;
    }
    reload();
  }

  // ---------------------------------------------------------------- avisos

  final Set<String> _notified = {};

  Future<void> _checkAlarms() async {
    if (!unlocked) return;
    final now = DateTime.now();
    try {
      final list = Core.call('alarms.between', {'from': fmtCore(_lastAlarmCheck), 'to': fmtCore(now.add(const Duration(seconds: 1)))}) as List;
      _lastAlarmCheck = now;
      for (final a in list.cast<Map<String, dynamic>>()) {
        final key = '${a['id']}@${a['at']}';
        if (!_notified.add(key)) continue;
        final starts = DateTime.tryParse(a['starts'] as String? ?? '');
        final body = starts == null ? '' : (a['kind'] == 'task' ? 'Vence a las ${fmtTime(starts)}' : 'Empieza a las ${fmtTime(starts)}');
        await Core.callAsync('sys.notify', {'title': a['title'], 'body': body});
      }
    } catch (e) {
      debugPrint('avisos: $e');
    }
  }

  // ---------------------------------------------------------------- carpeta de datos

  String get dataFolder => File(settings.vaultPath).parent.path;

  /// Mueve los datos a otra carpeta. Los widgets se cierran durante el traslado y se vuelven a abrir.
  Future<void> moveDataTo(String folder) async {
    final target = joinPath(folder, 'datos.calendario');
    await stopWidgets();
    try {
      await Core.callAsync('vault.relocate', {'path': target});
      settings.vaultPath = target;
      settings.save();
    } finally {
      reload();
      await launchWidgets();
    }
  }

  /// Usa unos datos que ya existen en otra carpeta (se pedirá su contraseña).
  Future<void> useDataAt(String folder) async {
    await stopWidgets();
    if (unlocked) lock();
    settings.vaultPath = joinPath(folder, 'datos.calendario');
    settings.save();
    notifyListeners();
  }

  /// Cierra los widgets en marcha (su PID está en el archivo de señal de vida).
  Future<void> stopWidgets() async {
    var killed = false;
    for (final kind in Settings.widgetKinds) {
      final f = heartbeatFile(kind);
      if (!f.existsSync()) continue;
      final pid = int.tryParse(f.readAsStringSync().trim());
      if (pid != null && widgetAlive(kind)) killed = Process.killPid(pid) || killed;
      try {
        f.deleteSync();
      } catch (_) {}
    }
    if (killed) await Future<void>.delayed(const Duration(milliseconds: 900));
  }

  // ---------------------------------------------------------------- widgets de escritorio

  /// Arranca los widgets activados que no estén ya en marcha. La contraseña viaja por stdin si no está en el llavero.
  Future<void> launchWidgets({String? password}) async {
    for (final kind in Settings.widgetKinds) {
      if (settings.widgets[kind]!.enabled && !widgetAlive(kind)) {
        await launchWidget(kind, password: password);
      }
    }
  }

  String? _sessionPassword;
  void rememberSessionPassword(String? pw) => _sessionPassword = pw;

  Future<void> launchWidget(String kind, {String? password}) async {
    try {
      final p = await Process.start(
        Platform.resolvedExecutable,
        ['--widget=$kind', '--vault=${settings.vaultPath}'],
        mode: ProcessStartMode.detachedWithStdio,
      );
      p.stdin.writeln(password ?? _sessionPassword ?? '');
      await p.stdin.flush();
      await p.stdin.close();
    } catch (e) {
      debugPrint('no se pudo abrir el widget $kind: $e');
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _syncTimer?.cancel();
    _alarmTimer?.cancel();
    super.dispose();
  }
}
