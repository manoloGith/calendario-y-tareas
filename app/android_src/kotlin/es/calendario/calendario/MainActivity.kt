// Actividad principal: además de Flutter, comunica la app con los widgets de la pantalla de inicio.
package es.calendario.calendario

import android.content.Intent
import es.calendario.widgets.Widgets
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingAction: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingAction = intent?.getStringExtra(Widgets.EXTRA_ACTION)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "calendario/widgets")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    Widgets.updateAll(applicationContext)
                    result.success(true)
                }
                "initialAction" -> {
                    result.success(pendingAction)
                    pendingAction = null
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    // La app ya estaba abierta y se ha tocado un widget.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = intent.getStringExtra(Widgets.EXTRA_ACTION) ?: return
        channel?.invokeMethod("action", action)
    }
}
