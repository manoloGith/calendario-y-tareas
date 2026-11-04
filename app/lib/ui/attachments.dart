// Adjuntos de eventos y tareas: documentos (copiados y cifrados), enlaces y carpetas.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/bridge.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'common.dart';
import 'theme.dart';

/// Abre una ruta o una URL con la aplicación predeterminada del sistema.
Future<void> openExternal(String target) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final uri = Uri.tryParse(target);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'mailto')) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      final r = await OpenFilex.open(target);
      if (r.type != ResultType.done) throw CoreError(r.type == ResultType.noAppToOpen ? 'No hay ninguna app para abrir este archivo' : r.message, 'error');
    }
    return;
  }
  if (Platform.isWindows) {
    await Process.start('explorer', [target], mode: ProcessStartMode.detached);
  } else {
    await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [target], mode: ProcessStartMode.detached);
  }
}

String _size(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// Pide al usuario un documento, una carpeta o un enlace. Devuelve (tipo, destino) o null.
Future<(String, String)?> pickAttachment(BuildContext context, String kind) async {
  switch (kind) {
    case 'file':
      final p = await pickFile(title: 'Adjuntar documento');
      return p == null ? null : ('file', p);
    case 'folder':
      final p = await pickFile(mode: 'folder', title: 'Adjuntar carpeta');
      return p == null ? null : ('folder', p);
    default:
      final u = await promptText(context, 'Añadir enlace', label: 'https://…', ok: 'Añadir');
      return (u == null || u.trim().isEmpty) ? null : ('link', u.trim());
  }
}

class AttachmentsSection extends StatefulWidget {
  const AttachmentsSection({super.key, required this.store, required this.ownerKind, this.ownerId, this.pending, this.readonly = false});
  final AppStore store;
  /// "event" o "task"
  final String ownerKind;
  /// null mientras el evento no se ha guardado: los adjuntos se guardan en `pending`.
  final String? ownerId;
  final List<Attachment>? pending;
  final bool readonly;

  @override
  State<AttachmentsSection> createState() => _AttachmentsSectionState();
}

class _AttachmentsSectionState extends State<AttachmentsSection> {
  List<Attachment> items = [];
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    if (widget.ownerId == null) {
      items = widget.pending ?? [];
      return;
    }
    items = (Core.call('attachments.list', {'ownerId': widget.ownerId}) as List).map((a) => Attachment.fromJson(a as Map<String, dynamic>)).toList();
  }

  Future<void> _add(String kind) async {
    final r = await pickAttachment(context, kind);
    if (r == null || !mounted) return;
    if (widget.ownerId == null) {
      final name = r.$1 == 'link' ? r.$2 : r.$2.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;
      setState(() => widget.pending!.add(Attachment.pending(r.$1, r.$2, name)));
      return;
    }
    setState(() => busy = true);
    try {
      await Core.callAsync('attachments.add', {'ownerKind': widget.ownerKind, 'ownerId': widget.ownerId, 'kind': r.$1, if (r.$1 == 'link') 'url': r.$2 else 'path': r.$2});
      widget.store.reload();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted) setState(_load);
  }

  Future<void> _open(Attachment a) async {
    try {
      final target = a.id.isEmpty ? a.target : (await Core.callAsync('attachments.open', {'id': a.id})) as String;
      await openExternal(target);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _saveCopy(Attachment a) async {
    final p = await pickFile(mode: 'save', title: 'Guardar una copia', defaultName: a.name);
    if (p == null) return;
    try {
      await Core.callAsync('attachments.export', {'id': a.id, 'path': p});
      if (!await finishSave(p)) return;
      if (mounted) showInfo(context, Platform.isAndroid ? 'Copia guardada' : 'Copia guardada en $p');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _delete(Attachment a) {
    if (a.id.isEmpty) {
      setState(() => widget.pending!.remove(a));
      return;
    }
    widget.store.mutate('attachments.delete', {'id': a.id});
    setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    IconData icon(String k) => switch (k) { 'file' => Icons.description_outlined, 'folder' => Icons.folder_outlined, _ => Icons.link_rounded };
    String sub(Attachment a) => switch (a.kind) {
          'file' => a.id.isEmpty ? 'Se copiará cifrado al guardar' : '${_size(a.size)} · copia cifrada',
          'folder' => a.target,
          _ => a.target,
        };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(
        'Adjuntos',
        trailing: widget.readonly
            ? null
            : busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : PopupMenuButton<String>(
                    tooltip: 'Adjuntar',
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.attach_file_rounded, color: t.sec),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'file', child: Text('Documento…')),
                      const PopupMenuItem(value: 'link', child: Text('Enlace…')),
                      if (!Platform.isAndroid) const PopupMenuItem(value: 'folder', child: Text('Carpeta…')),
                    ],
                    onSelected: _add,
                  ),
      ),
      if (items.isEmpty)
        Padding(padding: const EdgeInsets.only(left: 6, bottom: 4), child: Text('Sin adjuntos', style: TextStyle(fontSize: 12, color: t.faint))),
      for (final a in items)
        Container(
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(color: t.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: t.border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _open(a),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
              child: Row(children: [
                Icon(icon(a.kind), size: 18, color: t.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    Text(sub(a), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: t.sec)),
                  ]),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Opciones',
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_horiz_rounded, color: t.faint),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'open', child: Text('Abrir')),
                    if (a.kind == 'file' && a.id.isNotEmpty) const PopupMenuItem(value: 'save', child: Text('Guardar una copia…')),
                    if (!widget.readonly) PopupMenuItem(value: 'delete', child: Text('Quitar', style: TextStyle(color: t.danger))),
                  ],
                  onSelected: (v) => switch (v) { 'open' => _open(a), 'save' => _saveCopy(a), _ => _delete(a) },
                ),
              ]),
            ),
          ),
        ),
    ]);
  }
}
