// Utilidades comunes de los widgets de la pantalla de inicio.
// Los datos los escribe la app en widgets.json (carpeta privada); aquí solo se dibujan.
package es.calendario.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import es.calendario.calendario.R
import org.json.JSONObject
import java.io.File

object Widgets {
    const val EXTRA_ACTION = "calendario_action"
    private val WEEKDAYS = listOf("L", "M", "X", "J", "V", "S", "D")

    /** Instantánea escrita por la app, o null si aún no la hay. */
    fun data(ctx: Context): JSONObject? = try {
        val f = File(ctx.getDir("flutter", Context.MODE_PRIVATE), "widgets.json")
        if (f.exists()) JSONObject(f.readText()) else null
    } catch (e: Exception) {
        null
    }

    fun isDark(ctx: Context, d: JSONObject?): Boolean {
        if (d != null && d.has("dark") && !d.isNull("dark")) return d.optBoolean("dark")
        return (ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    }

    fun text(dark: Boolean) = if (dark) Color.parseColor("#F2F2F7") else Color.parseColor("#1D1D1F")
    fun sec(dark: Boolean) = if (dark) Color.parseColor("#A8A8AE") else Color.parseColor("#626267")
    fun faint(dark: Boolean) = if (dark) Color.parseColor("#6E6E73") else Color.parseColor("#9A9AA0")
    fun danger(dark: Boolean) = if (dark) Color.parseColor("#FF6961") else Color.parseColor("#C4281C")

    fun parse(hex: String?, fallback: Int): Int = try {
        if (hex.isNullOrEmpty() || hex == "null") fallback else Color.parseColor(hex)
    } catch (e: Exception) {
        fallback
    }

    fun accent(d: JSONObject?, fallback: Int): Int =
        if (d == null || d.isNull("accent")) fallback else parse(d.optString("accent"), fallback)

    /** Tamaño de texto de una parte (Ajustes › Widgets), 1.0 = normal. */
    fun scale(d: JSONObject?, key: String): Float =
        (d?.optJSONObject("text")?.optDouble(key, 1.0) ?: 1.0).toFloat().coerceIn(0.7f, 2.0f)

    fun sp(v: RemoteViews, id: Int, base: Float, scale: Float) =
        v.setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_SP, base * scale)

    /** Fondo redondeado claro u oscuro con la transparencia elegida. */
    fun background(v: RemoteViews, ctx: Context, d: JSONObject?) {
        v.setImageViewResource(R.id.bg, if (isDark(ctx, d)) R.drawable.widget_bg_dark else R.drawable.widget_bg_light)
        val transparency = (d?.optInt("transparency", 10) ?: 10).coerceIn(0, 90)
        v.setInt(R.id.bg, "setImageAlpha", (100 - transparency) * 255 / 100)
    }

    /** Tinte del círculo de «hoy» y del botón «+» (Android 12 o posterior). */
    fun tint(v: RemoteViews, id: Int, color: Int) {
        if (Build.VERSION.SDK_INT >= 31) v.setColorStateList(id, "setBackgroundTintList", ColorStateList.valueOf(color))
    }

    private fun launch(ctx: Context): Intent =
        (ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: Intent()).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

    /** Abre la app con una acción («day:…», «newEvent:…», «newTask», «task:…», «open»). */
    fun openApp(ctx: Context, action: String): PendingIntent {
        val i = launch(ctx).apply {
            putExtra(EXTRA_ACTION, action)
            data = Uri.parse("calendario://accion/" + Uri.encode(action)) // distinto por acción
        }
        return PendingIntent.getActivity(ctx, action.hashCode(), i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Plantilla para los elementos de las listas (cada uno completa su acción). */
    fun template(ctx: Context, code: Int): PendingIntent {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        return PendingIntent.getActivity(ctx, code, launch(ctx), flags)
    }

    fun fillIn(action: String): Intent =
        Intent().putExtra(EXTRA_ACTION, action).setData(Uri.parse("calendario://accion/" + Uri.encode(action)))

    /** Mes en la cuadrícula: letras de los días y 6 semanas con número, «hoy» y punto si hay eventos. */
    fun fillMonth(ctx: Context, v: RemoteViews, d: JSONObject?, scale: Float, accent: Int) {
        val dark = isDark(ctx, d)
        v.removeAllViews(R.id.weekdays)
        v.removeAllViews(R.id.grid)
        for (l in WEEKDAYS) {
            val c = RemoteViews(ctx.packageName, R.layout.widget_weekday)
            c.setTextViewText(R.id.wd, l)
            c.setTextColor(R.id.wd, sec(dark))
            sp(c, R.id.wd, 10f, scale)
            v.addView(R.id.weekdays, c)
        }
        val cells = d?.optJSONObject("month")?.optJSONArray("cells") ?: return
        for (r in 0 until 6) {
            val row = RemoteViews(ctx.packageName, R.layout.widget_row)
            for (k in 0 until 7) {
                val i = r * 7 + k
                if (i >= cells.length()) break
                val cell = cells.getJSONObject(i)
                val cv = RemoteViews(ctx.packageName, R.layout.widget_cell)
                val today = cell.optBoolean("today")
                val inMonth = cell.optBoolean("in")
                cv.setTextViewText(R.id.cell_text, cell.optInt("d").toString())
                cv.setTextColor(R.id.cell_text, if (today) Color.WHITE else if (inMonth) text(dark) else faint(dark))
                sp(cv, R.id.cell_text, 13f, scale)
                if (today) {
                    cv.setInt(R.id.cell_text, "setBackgroundResource", R.drawable.widget_today)
                    tint(cv, R.id.cell_text, accent)
                }
                val dot = if (cell.isNull("dot")) "" else cell.optString("dot")
                if (dot.isNotEmpty() && !today) {
                    cv.setViewVisibility(R.id.cell_dot, View.VISIBLE)
                    cv.setInt(R.id.cell_dot, "setColorFilter", parse(dot, accent))
                } else {
                    cv.setViewVisibility(R.id.cell_dot, View.INVISIBLE)
                }
                cv.setOnClickPendingIntent(R.id.cell, openApp(ctx, "day:" + cell.optString("date")))
                row.addView(R.id.row, cv)
            }
            v.addView(R.id.grid, row)
        }
    }

    /** Pide a los tres widgets que se redibujen (lo llama la app al cambiar los datos). */
    fun updateAll(ctx: Context) {
        val m = AppWidgetManager.getInstance(ctx)
        for (cls in listOf(CalendarWidget::class.java, AgendaWidget::class.java, TasksWidget::class.java)) {
            val ids = m.getAppWidgetIds(ComponentName(ctx, cls))
            if (ids.isEmpty()) continue
            ctx.sendBroadcast(
                Intent(ctx, cls).setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE).putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            )
            m.notifyAppWidgetViewDataChanged(ids, R.id.list)
        }
    }
}
