// Estado de la aplicación: bóveda abierta, calendarios, vista actual, sincronización y avisos.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'bridge.dart';
import 'dates.dart';
import 'models.dart';
import 'platform.dart';
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
  List<ZkAccount> zkAccounts = [];

  /// Hay algo con qué sincronizar (CalDAV o servidor zero-knowledge).
  bool get hasRemote => accounts.isNotEmpty || zkAccounts.isNotEmpty;
  Counts counts = Counts();

  AppMode mode = AppMode.calendar;
  CalView view = CalView.week;
  DateTime anchor = DateTime.now();

  TaskScope taskScope = const TaskScope.smart('today');
  String? selectedTaskId;
  bool showCompleted = false;

  /// Día para el que hay que abrir el formulario de nuevo evento (doble clic en un widget).
  DateTime? pendingNewEvent;
  /// Crear una tarea nueva al mostrar la ventana (menú de la bandeja).
  bool requestNewTask = false;

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

  // Android: la contraseña se recuerda en el almacén seguro de Android (en escritorio, en el llavero del sistema vía Rust).
  static const _secure = FlutterSecureStorage();
  String get _secureKey => 'vault:${settings.vaultPath}';
  bool _rememberedMobile = false;

  /// Actualiza si hay contraseña guardada (en Android la consulta es asíncrona).
  Future<void> refreshRemembered() async {
    if (!isMobile) return;
    try {
      _rememberedMobile = (await _secure.read(key: _secureKey)) != null;
    } catch (_) {
      _rememberedMobile = false;
    }
  }

  Future<void> create(String password, {bool remember = false}) async {
    await Core.callAsync('vault.create', {'path': settings.vaultPath, 'password': password, 'remember': remember && !isMobile});
    if (isMobile && remember) await _secure.write(key: _secureKey, value: password);
    _sessionPassword = password;
    _afterUnlock();
  }

  Future<void> open({String? password, bool remember = false}) async {
    var pw = password;
    if (isMobile && pw == null) {
      pw = await _secure.read(key: _secureKey);
      if (pw == null) throw CoreError('No hay contraseña guardada en este dispositivo', 'keyring');
    }
    await Core.callAsync('vault.open', {
      'path': settings.vaultPath,
      if (pw != null) 'password': pw,
      'remember': remember && !isMobile,
    });
    if (isMobile && remember && pw != null) await _secure.write(key: _secureKey, value: pw);
    if (pw != null) _sessionPassword = pw;
    _afterUnlock();
  }

  bool get remembered {
    if (isMobile) return _rememberedMobile;
    try {
      return Core.call('vault.remembered', {'path': settings.vaultPath}) as bool;
    } catch (_) {
      return false;
    }
  }

  /// Activa o desactiva «Recordar en este equipo».
  Future<void> setRemember(bool on) async {
    if (isMobile) {
      if (on) {
        if (_sessionPassword == null) throw CoreError('Vuelve a abrir la app con la contraseña para poder recordarla', 'invalid');
        await _secure.write(key: _secureKey, value: _sessionPassword);
      } else {
        await _secure.delete(key: _secureKey);
      }
      _rememberedMobile = on;
    } else {
      on ? Core.call('vault.remember') : Core.call('vault.forget', {'path': settings.vaultPath});
    }
    notifyListeners();
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
      if (hasRemote) syncNow(quiet: true);
    }
    notifyListeners();
  }

  /// Ventana principal: deja señal de vida y atiende las peticiones de los widgets (también con la bóveda bloqueada).
  void startAppHeartbeat() {
    _appBeat = Timer.periodic(const Duration(seconds: 1), (_) => _appTick());
    _appTick();
  }

  Timer? _appBeat;
  int _beats = 0;
  /// Se llama cuando un widget pide traer la ventana al frente.
  VoidCallback? onBringToFront;

  void _appTick() {
    try {
      if (_beats++ % 4 == 0) appHeartbeatFile().writeAsStringSync('$pid');
      final f = requestFile();
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      f.deleteSync();
      final at = DateTime.tryParse(j['at'] as String? ?? '');
      if (at == null || DateTime.now().difference(at).inSeconds > 60) return;
      if (j['action'] == 'newEvent') {
        final day = DateTime.tryParse(j['date'] as String? ?? '');
        if (day != null) requestNewEvent(day);
      } else if (j['action'] == 'newTask') {
        requestTask();
      }
      onBringToFront?.call();
    } catch (_) {}
  }

  /// Tarea nueva (widget de tareas o bandeja): se crea en «Hoy» y se abre su detalle.
  void requestTask() {
    taskScope = const TaskScope.smart('today');
    selectedTaskId = null;
    mode = AppMode.tasks;
    requestNewTask = true;
    notifyListeners();
  }

  void requestNewEvent(DateTime day) {
    pendingNewEvent = day;
    mode = AppMode.calendar;
    anchor = day;
    view = CalView.day;
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
    zkAccounts = (Core.call('zk.accounts') as List).map((a) => ZkAccount.fromJson(a as Map<String, dynamic>)).toList();
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
    if (!hasRemote || syncState == SyncState.syncing) return;
    syncState = SyncState.syncing;
    syncMessage = 'Sincronizando…';
    notifyListeners();
    final failures = <String>[];
    // Servidor zero-knowledge primero (datos locales) y luego CalDAV.
    for (final (method, has) in [('zk.sync', zkAccounts.isNotEmpty), ('caldav.sync', accounts.isNotEmpty)]) {
      if (!has) continue;
      try {
        final res = (await Core.callAsync(method)) as List;
        for (final r in res.cast<Map>()) {
          if (r['ok'] != true) failures.add(r['error'] as String? ?? 'error');
        }
      } on CoreError catch (e) {
        failures.add(e.message);
      }
    }
    if (failures.isEmpty) {
      syncState = SyncState.idle;
      syncMessage = 'Sincronizado ${fmtTime(DateTime.now())}';
    } else {
      final offline = failures.every((m) => m.contains('red') || m.contains('responde'));
      syncState = offline ? SyncState.offline : SyncState.error;
      syncMessage = offline ? 'Sin conexión' : failures.first;
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
      settings.customFolder = folder != appDataDir();
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
    settings.customFolder = folder != appDataDir();
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
    if (isMobile) return; // los widgets de escritorio no existen en Android
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
    _appBeat?.cancel();
    super.dispose();
  }
}
