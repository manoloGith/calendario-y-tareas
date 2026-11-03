// Ajustes: general, cuentas CalDAV, archivos .ics, seguridad, copias de seguridad y widgets.
import 'package:flutter/material.dart';

import '../core/bridge.dart';
import '../core/dates.dart';
import '../core/models.dart';
import 'dart:io';

import '../core/settings.dart';
import '../core/store.dart';
import 'common.dart';
import 'sidebar.dart';
import 'theme.dart';

Future<void> showSettings(BuildContext context, AppStore store, {int tab = 0}) =>
    showDialog(context: context, builder: (_) => SettingsDialog(store: store, initialTab: tab));

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.store, this.initialTab = 0});
  final AppStore store;
  final int initialTab;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late int tab = widget.initialTab;
  AppStore get store => widget.store;

  static const tabs = [
    (Icons.tune_rounded, 'General'),
    (Icons.cloud_outlined, 'Cuentas'),
    (Icons.lock_outline_rounded, 'Seguridad'),
    (Icons.archive_outlined, 'Copias'),
    (Icons.widgets_outlined, 'Widgets'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 540,
        child: Row(children: [
          Container(
            width: 190,
            decoration: BoxDecoration(color: t.sidebar, borderRadius: const BorderRadius.horizontal(left: Radius.circular(16))),
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Padding(padding: EdgeInsets.fromLTRB(8, 6, 8, 14), child: Text('Ajustes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
              for (var i = 0; i < tabs.length; i++)
                Material(
                  color: tab == i ? t.pill : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => tab = i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(children: [Icon(tabs[i].$1, size: 17, color: t.sec), const SizedBox(width: 10), Text(tabs[i].$2)]),
                    ),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: Column(children: [
              Align(alignment: Alignment.topRight, child: IconButton(tooltip: 'Cerrar', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, size: 18))),
              Expanded(
                child: ListenableBuilder(
                  listenable: store,
                  builder: (context, _) => SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: [_general, _accounts, _security, _backups, _widgets][tab](context),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _title(String s, [String? sub]) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          if (sub != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(sub, style: TextStyle(color: context.tk.sec, fontSize: 12.5))),
        ]),
      );

  Widget _row(String label, Widget control) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [SizedBox(width: 190, child: Text(label)), Expanded(child: Align(alignment: Alignment.centerLeft, child: control))]),
      );

  // ---------------------------------------------------------------- general

  Widget _general(BuildContext context) {
    final s = store.settings;
    final info = Core.call('vault.info') as Map;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title('General'),
      _row(
        'Apariencia',
        PillSegmented<String>(
          compact: true,
          values: const ['system', 'light', 'dark'],
          labels: const ['Sistema', 'Claro', 'Oscuro'],
          selected: s.themeMode,
          onChanged: (v) {
            s.themeMode = v;
            s.save();
            store.reload();
          },
        ),
      ),
      _row(
        'Calendario por defecto',
        DropdownButton<String>(
          value: store.defaultCalendarId,
          items: [for (final c in store.writableEventCalendars) DropdownMenuItem(value: c.id, child: Text(c.name))],
          onChanged: (v) {
            s.defaultCalendarId = v;
            s.save();
            store.reload();
          },
        ),
      ),
      _row(
        'Lista de tareas por defecto',
        DropdownButton<String>(
          value: store.writableTaskLists.any((c) => c.id == s.defaultListId) ? s.defaultListId : store.writableTaskLists.firstOrNull?.id,
          items: [for (final c in store.writableTaskLists) DropdownMenuItem(value: c.id, child: Text(c.name))],
          onChanged: (v) {
            s.defaultListId = v;
            s.save();
            store.reload();
          },
        ),
      ),
      _row('Zona horaria', Text('${info['tz']}', style: TextStyle(color: context.tk.sec))),
      _row(
        'Carpeta de datos',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(store.dataFolder, style: TextStyle(color: context.tk.sec, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: () => changeDataFolder(context, store), child: const Text('Cambiar carpeta…')),
            TextButton(onPressed: () => openFolder(store.dataFolder), child: const Text('Abrir carpeta')),
          ]),
        ]),
      ),
      const SizedBox(height: 18),
      _title('Archivos .ics', 'Un archivo enlazado se mantiene sincronizado: los cambios se escriben en él y se releen si otro programa lo modifica.'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: () => addSource(context, store, 'link'), icon: const Icon(Icons.link_rounded, size: 16), label: const Text('Enlazar archivo…')),
        OutlinedButton.icon(onPressed: () => addSource(context, store, 'import'), icon: const Icon(Icons.file_download_outlined, size: 16), label: const Text('Importar una copia…')),
      ]),
      const SizedBox(height: 8),
      for (final c in store.calendars.where((c) => c.source == 'ics'))
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(radius: 6, backgroundColor: c.colorValue),
          title: Text(c.name),
          subtitle: Text(c.icsPath ?? '', style: const TextStyle(fontSize: 11)),
        ),
    ]);
  }

  // ---------------------------------------------------------------- cuentas

  Widget _accounts(BuildContext context) {
    final t = context.tk;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title('Cuentas CalDAV',
          'Nextcloud, iCloud (contraseña de app), Fastmail, Radicale, Baïkal… Puedes indicar una dirección local y otra por VPN (p. ej. Tailscale): se usa la que responda. Todo se guarda primero en local; sin red, los cambios esperan y se suben al reconectar.'),
      for (final a in store.accounts)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: t.sidebar, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.cloud_outlined, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('${a.username} · ${a.urls.map(_host).join('  |  ')}', style: TextStyle(fontSize: 11.5, color: t.sec), overflow: TextOverflow.ellipsis),
                if (a.activeUrl != null)
                  Text('Conectada por ${_host(a.activeUrl!)}${a.urls.length > 1 ? (a.activeUrl == a.baseUrl ? ' (principal)' : ' (alternativa)') : ''}',
                      style: TextStyle(fontSize: 11.5, color: t.ok)),
                Text(
                  a.lastError != null ? 'Último error: ${a.lastError}' : (a.lastSync != null ? 'Sincronizada: ${_ago(a.lastSync!)}' : 'Aún sin sincronizar'),
                  style: TextStyle(fontSize: 11.5, color: a.lastError != null ? t.danger : t.sec),
                ),
              ]),
            ),
            TextButton(onPressed: () => showCalDavDialog(context, store, edit: a), child: const Text('Editar')),
            TextButton(onPressed: store.syncState == SyncState.syncing ? null : () => store.syncNow(), child: const Text('Sincronizar')),
            TextButton(
              onPressed: () async {
                if (await confirm(context, 'Quitar cuenta', 'Se quitarán de este equipo «${a.name}» y sus calendarios. Los datos del servidor no se borran.', ok: 'Quitar')) {
                  store.mutate('caldav.remove', {'id': a.id});
                }
              },
              child: Text('Quitar', style: TextStyle(color: t.danger)),
            ),
          ]),
        ),
      const SizedBox(height: 6),
      FilledButton.icon(onPressed: () => showCalDavDialog(context, store), icon: const Icon(Icons.add_rounded, size: 16), label: const Text('Añadir cuenta CalDAV')),
      const SizedBox(height: 22),
      _title('Servidor zero-knowledge', 'Próximamente: sincronización entre tus dispositivos con cifrado de extremo a extremo y servidor propio.'),
      const OutlinedButton(onPressed: null, child: Text('Añadir servidor (próximamente)')),
      const SizedBox(height: 18),
      _row(
        'Sincronizar cada',
        DropdownButton<int>(
          value: store.settings.syncMinutes,
          items: [for (final m in [1, 5, 15, 30, 60]) DropdownMenuItem(value: m, child: Text('$m min'))],
          onChanged: (v) {
            store.settings.syncMinutes = v ?? 5;
            store.settings.save();
            store.reload();
            showInfo(context, 'Se aplicará la próxima vez que abras la app.');
          },
        ),
      ),
    ]);
  }

  String _host(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return url;
    return u.hasPort ? '${u.host}:${u.port}' : u.host;
  }

  String _ago(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    return '${shortDate(d)} ${fmtTime(d)}';
  }

  // ---------------------------------------------------------------- seguridad

  Widget _security(BuildContext context) {
    final remembered = store.remembered;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title('Seguridad', 'Tus datos se guardan en una base de datos cifrada (SQLCipher). Sin la contraseña no se pueden leer.'),
      _row(
        'Recordar en este equipo',
        Switch(
          value: remembered,
          onChanged: (v) {
            try {
              if (v) {
                Core.call('vault.remember');
              } else {
                Core.call('vault.forget', {'path': store.settings.vaultPath});
              }
              setState(() {});
            } catch (e) {
              showError(context, e);
            }
          },
        ),
      ),
      _row(
        'Contraseña',
        OutlinedButton(
          onPressed: () async {
            final old = await promptText(context, 'Contraseña actual', obscure: true);
            if (old == null || !context.mounted) return;
            final nw = await promptText(context, 'Nueva contraseña (mínimo 8 caracteres)', obscure: true);
            if (nw == null || !context.mounted) return;
            final again = await promptText(context, 'Repite la nueva contraseña', obscure: true);
            if (!context.mounted) return;
            if (again != nw) return showError(context, 'Las contraseñas no coinciden');
            try {
              Core.call('vault.changePassword', {'old': old, 'new': nw});
              store.rememberSessionPassword(nw);
              showInfo(context, 'Contraseña cambiada.');
            } catch (e) {
              showError(context, e);
            }
          },
          child: const Text('Cambiar contraseña…'),
        ),
      ),
      _row(
        'Bloquear',
        OutlinedButton(
          onPressed: () {
            Navigator.pop(context);
            store.lock();
          },
          child: const Text('Bloquear ahora (Ctrl+L)'),
        ),
      ),
    ]);
  }

  // ---------------------------------------------------------------- copias

  Widget _backups(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title('Copias de seguridad cifradas',
          'Un archivo .calbak con todos tus calendarios, eventos, tareas y cuentas, cifrado con la contraseña que elijas (XChaCha20-Poly1305 + Argon2id). Guárdalo donde quieras: un disco, una carpeta de Nextcloud o Dropbox…'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: () async {
            final name = 'calendario-${fmtCoreDate(DateTime.now())}.calbak';
            final p = await pickFile(mode: 'save', title: 'Guardar copia de seguridad', extensions: ['calbak'], filterName: 'Copia cifrada', defaultName: name);
            if (p == null || !context.mounted) return;
            final pw = await promptText(context, 'Contraseña de la copia (mínimo 8 caracteres)', obscure: true);
            if (pw == null || !context.mounted) return;
            try {
              final r = await Core.callAsync('backup.create', {'path': p, 'password': pw}) as Map;
              if (context.mounted) showInfo(context, 'Copia verificada: ${r['events']} eventos y ${r['tasks']} tareas.');
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          icon: const Icon(Icons.save_alt_rounded, size: 16),
          label: const Text('Crear copia…'),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final p = await pickFile(title: 'Restaurar copia de seguridad', extensions: ['calbak'], filterName: 'Copia cifrada');
            if (p == null || !context.mounted) return;
            final pw = await promptText(context, 'Contraseña de la copia', obscure: true);
            if (pw == null || !context.mounted) return;
            try {
              final info = await Core.callAsync('backup.inspect', {'path': p, 'password': pw}) as Map;
              if (!context.mounted) return;
              final replace = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Restaurar copia', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  content: Text('La copia contiene ${info['calendars']} calendarios, ${info['events']} eventos y ${info['tasks']} tareas.\n\n'
                      '«Fusionar» añade y actualiza sin borrar nada. «Reemplazar» borra antes todos los datos de este equipo.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
                    TextButton(onPressed: () => Navigator.pop(c, true), child: Text('Reemplazar', style: TextStyle(color: context.tk.danger))),
                    FilledButton(onPressed: () => Navigator.pop(c, false), child: const Text('Fusionar')),
                  ],
                ),
              );
              if (replace == null) return;
              await Core.callAsync('backup.restore', {'path': p, 'password': pw, 'replace': replace});
              store.reload();
              if (context.mounted) showInfo(context, 'Copia restaurada.');
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          icon: const Icon(Icons.restore_rounded, size: 16),
          label: const Text('Restaurar…'),
        ),
      ]),
      const SizedBox(height: 18),
      Text('Para migrar a otra app, cada calendario se puede exportar a .ics estándar (sin cifrar) desde su menú «…».',
          style: TextStyle(color: context.tk.sec, fontSize: 12.5)),
    ]);
  }

  // ---------------------------------------------------------------- widgets

  static const _fonts = [
    'Segoe UI', 'Arial', 'Calibri', 'Verdana', 'Tahoma', 'Trebuchet MS', 'Georgia', 'Cambria',
    'Times New Roman', 'Consolas', 'Helvetica Neue', 'Avenir Next', 'Inter', 'Roboto', 'Ubuntu', 'DejaVu Sans',
  ];

  Widget _fontPicker(BuildContext context) {
    final s = store.settings;
    final current = s.widgetFont;
    final items = <String?>[null, ..._fonts, if (current != null && !_fonts.contains(current)) current, '__otra'];
    return DropdownButton<String?>(
      value: current,
      items: [
        for (final f in items)
          DropdownMenuItem(
            value: f,
            child: Text(f == null ? 'Del sistema' : (f == '__otra' ? 'Otra (escribir nombre)…' : f), style: TextStyle(fontFamily: f == '__otra' ? null : f)),
          ),
      ],
      onChanged: (v) async {
        if (v == '__otra') {
          final name = await promptText(context, 'Nombre de la fuente instalada', label: 'p. ej. Segoe UI Variable', initial: current ?? '');
          if (name == null || name.trim().isEmpty) return;
          v = name.trim();
        }
        setState(() => s.widgetFont = v);
        s.save();
      },
    );
  }

  Widget _widgets(BuildContext context) {
    const names = {'calendar': 'Solo calendario', 'agenda': 'Calendario y eventos', 'tasks': 'Tareas'};
    final s = store.settings;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title('Widgets de escritorio',
          'Ventanas ligeras ancladas al escritorio: siguen visibles con Win+D o «Mostrar escritorio». Arrástralos por la cabecera para moverlos.'),
      for (final k in Settings.widgetKinds)
        _row(
          names[k]!,
          Switch(
            value: s.widgets[k]!.enabled,
            onChanged: (v) async {
              s.widgets[k]!.enabled = v;
              s.save();
              setState(() {});
              if (v && !widgetAlive(k)) await store.launchWidget(k);
            },
          ),
        ),
      const SizedBox(height: 18),
      _title('Texto de los widgets', 'Los cambios se aplican en unos segundos a los widgets abiertos.'),
      _row('Fuente', _fontPicker(context)),
      _row(
        'Tamaño del texto',
        Row(children: [
          Expanded(
            child: Slider(
              value: s.widgetFontScale.clamp(0.7, 1.6),
              min: 0.7,
              max: 1.6,
              divisions: 18,
              label: '${(s.widgetFontScale * 100).round()} %',
              onChanged: (v) => setState(() => s.widgetFontScale = (v * 20).round() / 20),
              onChangeEnd: (_) => s.save(),
            ),
          ),
          SizedBox(width: 48, child: Text('${(s.widgetFontScale * 100).round()} %', textAlign: TextAlign.right)),
        ]),
      ),
      Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: context.tk.sidebar, borderRadius: BorderRadius.circular(14)),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(s.widgetFontScale)),
          child: DefaultTextStyle.merge(
            style: TextStyle(fontFamily: s.widgetFont),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('NOVIEMBRE  2026', style: TextStyle(color: Color(0xFFFF3B30), fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 6),
              const Text('Revisión de sprint', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              Text('10:00 · Trabajo', style: TextStyle(fontSize: 11, color: context.tk.sec)),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 10),
      if (!store.remembered)
        Text('Consejo: activa «Recordar en este equipo» (Seguridad) para que los widgets se puedan abrir sin la app principal.',
            style: TextStyle(color: context.tk.sec, fontSize: 12.5)),
    ]);
  }
}

/// Compatibilidad: alta de cuenta desde otros menús.
Future<void> showAddCalDav(BuildContext context, AppStore store) => showCalDavDialog(context, store);

/// Alta o edición de una cuenta CalDAV con dirección principal y alternativa, y prueba de conexión.
Future<void> showCalDavDialog(BuildContext context, AppStore store, {Account? edit}) async {
  final url = TextEditingController(text: edit?.baseUrl ?? 'https://');
  final alt = TextEditingController(text: edit == null || edit.altUrls.isEmpty ? '' : edit.altUrls.join(', '));
  final user = TextEditingController(text: edit?.username ?? '');
  final pass = TextEditingController();
  final name = TextEditingController(text: edit?.name ?? '');
  var busy = false;
  String? error;
  List<Map<String, dynamic>>? probes;
  List<String> urls() => [url.text.trim(), ...alt.text.split(RegExp(r'[,\s]+')).map((u) => u.trim())].where((u) => u.isNotEmpty && u != 'https://').toList();
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        Future<void> test() async {
          set(() {
            busy = true;
            error = null;
            probes = null;
          });
          try {
            final r = await Core.callAsync('caldav.test', {
              'urls': urls(),
              'username': user.text.trim(),
              'password': pass.text,
              if (edit != null) 'accountId': edit.id,
            }) as List;
            set(() => probes = r.cast<Map<String, dynamic>>());
          } catch (e) {
            set(() => error = e.toString());
          } finally {
            set(() => busy = false);
          }
        }

        Future<void> save() async {
          set(() {
            busy = true;
            error = null;
          });
          try {
            if (edit == null) {
              final r = await Core.callAsync('caldav.add', {'urls': urls(), 'username': user.text.trim(), 'password': pass.text, 'name': name.text.trim()}) as Map;
              store.reload();
              if (c.mounted) {
                Navigator.pop(c);
                showInfo(context, 'Cuenta añadida con ${(r['calendars'] as List).length} calendarios.');
              }
            } else {
              Core.call('caldav.update', {
                'id': edit.id,
                'name': name.text.trim(),
                'urls': urls(),
                'username': user.text.trim(),
                if (pass.text.isNotEmpty) 'password': pass.text,
              });
              store.reload();
              if (c.mounted) Navigator.pop(c);
              await store.syncNow();
            }
          } catch (e) {
            set(() {
              busy = false;
              error = e.toString();
            });
          }
        }

        final t = c.tk;
        return AlertDialog(
          title: Text(edit == null ? 'Añadir cuenta CalDAV' : 'Editar «${edit.name}»', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(controller: url, decoration: const InputDecoration(labelText: 'Dirección principal', hintText: 'p. ej. http://192.168.1.10:5232/usuario/')),
                const SizedBox(height: 8),
                TextField(
                  controller: alt,
                  decoration: const InputDecoration(labelText: 'Dirección alternativa (opcional)', hintText: 'p. ej. https://nas.tu-red.ts.net:5232/usuario/ (VPN, Tailscale…)'),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Text('Se prueba primero la última que funcionó. Puedes poner varias separadas por comas.', style: TextStyle(fontSize: 11, color: t.sec)),
                ),
                const SizedBox(height: 8),
                TextField(controller: user, decoration: const InputDecoration(labelText: 'Usuario')),
                const SizedBox(height: 8),
                TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: InputDecoration(labelText: edit == null ? 'Contraseña (o contraseña de aplicación)' : 'Contraseña (déjala vacía para no cambiarla)'),
                ),
                const SizedBox(height: 8),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre de la cuenta (opcional)')),
                if (probes != null) ...[
                  const SizedBox(height: 12),
                  for (final p in probes!)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(p['ok'] == true ? Icons.check_circle_rounded : Icons.cancel_rounded, size: 16, color: p['ok'] == true ? t.ok : t.danger),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            p['ok'] == true ? '${p['url']} · responde en ${p['ms']} ms' : '${p['url']} · ${p['error'] ?? 'no responde'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ]),
                    ),
                ],
                if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: TextStyle(color: t.danger, fontSize: 12.5))),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(c), child: const Text('Cancelar')),
            OutlinedButton(onPressed: busy ? null : test, child: const Text('Probar conexión')),
            FilledButton(
              onPressed: busy ? null : save,
              child: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(edit == null ? 'Conectar' : 'Guardar'),
            ),
          ],
        );
      },
    ),
  );
}

/// Abre una carpeta en el explorador del sistema.
Future<void> openFolder(String dir) async {
  final cmd = Platform.isWindows ? 'explorer' : (Platform.isMacOS ? 'open' : 'xdg-open');
  await Process.start(cmd, [dir], mode: ProcessStartMode.detached);
}

/// Elige otra carpeta para los datos: si ya contiene datos, se pueden usar; si no, se mueven allí los actuales.
Future<void> changeDataFolder(BuildContext context, AppStore store) async {
  final dir = await pickFile(mode: 'folder', title: 'Elige la carpeta para tus datos');
  if (dir == null || !context.mounted) return;
  final target = joinPath(dir, 'datos.calendario');
  if (target == store.settings.vaultPath) return;
  try {
    if (File(target).existsSync()) {
      final ok = await confirm(context, 'Ya hay datos en esa carpeta',
          '¿Quieres usar los datos de «$dir»? Se pedirá su contraseña. Los datos actuales se quedan donde están.',
          ok: 'Usar esos datos', danger: false);
      if (!ok || !context.mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      await store.useDataAt(dir);
    } else if (!store.unlocked) {
      // Antes de crear o abrir la bóveda: solo se cambia la ubicación.
      store.settings.customFolder = dir != appDataDir();
      store.settings.vaultPath = target;
      store.settings.save();
      store.reload();
    } else {
      final ok = await confirm(context, 'Mover los datos', 'Tus datos cifrados se moverán a «$dir». Los widgets se cerrarán un momento.', ok: 'Mover', danger: false);
      if (!ok) return;
      await store.moveDataTo(dir);
      if (context.mounted) showInfo(context, 'Datos movidos a $dir');
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
