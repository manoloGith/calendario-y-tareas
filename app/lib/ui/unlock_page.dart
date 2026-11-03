// Primera ejecución (crear bóveda) y desbloqueo.
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/bridge.dart';
import '../core/store.dart';
import 'common.dart';
import 'settings_dialog.dart';
import 'theme.dart';

class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key, required this.store});
  final AppStore store;
  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final pw = TextEditingController();
  final pw2 = TextEditingController();
  bool remember = false;
  bool busy = false;
  String? error;
  bool get creating => !widget.store.vaultExists;

  @override
  void initState() {
    super.initState();
    // Si la contraseña está en el llavero del sistema, se abre directamente.
    if (!creating && widget.store.remembered) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit(useKeyring: true));
    }
  }

  @override
  void dispose() {
    pw.dispose();
    pw2.dispose();
    super.dispose();
  }

  Future<void> _submit({bool useKeyring = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (creating) {
        if (pw.text.length < 8) throw CoreError('La contraseña debe tener al menos 8 caracteres', 'invalid');
        if (pw.text != pw2.text) throw CoreError('Las contraseñas no coinciden', 'invalid');
        await widget.store.create(pw.text, remember: remember);
      } else if (useKeyring) {
        await widget.store.open();
      } else {
        await widget.store.open(password: pw.text, remember: remember);
      }
      widget.store.rememberSessionPassword(useKeyring ? null : pw.text);
      await widget.store.launchWidgets();
    } on CoreError catch (e) {
      setState(() => error = useKeyring ? null : e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Scaffold(
      body: Column(children: [
        const DragToMoveArea(
          child: SizedBox(
            height: 44,
            child: Row(children: [SizedBox(width: 16), TrafficLights(), Spacer()]),
          ),
        ),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: Container(
                width: 380,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(color: t.sidebar, borderRadius: BorderRadius.circular(22), border: Border.all(color: t.sideBorder)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(child: Image.asset('assets/icon/app_icon.png', width: 84, height: 84, filterQuality: FilterQuality.medium)),
                  const SizedBox(height: 16),
                  Text(creating ? 'Bienvenido' : 'Calendario y Tareas',
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    creating
                        ? 'Tus eventos y tareas se guardan cifrados en este equipo. Elige una contraseña: sin ella nadie podrá leerlos (y no se puede recuperar).'
                        : 'Introduce tu contraseña para desbloquear tus datos.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.sec),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: pw,
                    obscureText: true,
                    autofocus: true,
                    enabled: !busy,
                    decoration: const InputDecoration(hintText: 'Contraseña', prefixIcon: Icon(Icons.lock_outline_rounded, size: 18)),
                    onSubmitted: (_) => creating ? null : _submit(),
                  ),
                  if (creating) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: pw2,
                      obscureText: true,
                      enabled: !busy,
                      decoration: const InputDecoration(hintText: 'Repite la contraseña', prefixIcon: Icon(Icons.lock_outline_rounded, size: 18)),
                      onSubmitted: (_) => _submit(),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(children: [
                    Checkbox(value: remember, onChanged: busy ? null : (v) => setState(() => remember = v ?? false)),
                    Expanded(
                      child: Text('Recordar en este equipo (llavero del sistema). Necesario para que los widgets se abran solos.',
                          style: TextStyle(fontSize: 12, color: t.sec)),
                    ),
                  ]),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!, style: TextStyle(color: t.danger, fontSize: 12.5), textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: busy ? null : () => _submit(),
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    child: busy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(creating ? 'Crear y empezar' : 'Desbloquear'),
                  ),
                  const SizedBox(height: 12),
                  Text(widget.store.dataFolder, textAlign: TextAlign.center, style: TextStyle(fontSize: 10.5, color: t.faint)),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            await changeDataFolder(context, widget.store);
                            if (mounted) setState(() => error = null);
                          },
                    child: Text(creating ? 'Guardar los datos en otra carpeta…' : 'Abrir datos de otra carpeta…', style: const TextStyle(fontSize: 12)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
