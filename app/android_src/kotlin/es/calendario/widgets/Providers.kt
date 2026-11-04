// Los tres widgets: «Calendario», «Calendario y eventos» y «Tareas».
package es.calendario.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.calendario.calendario.R

private val RED = Color.parseColor("#FF3B30")
private val BLUE = Color.parseColor("#007AFF")

/** Solo calendario. */
class CalendarWidget : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, m: AppWidgetManager, ids: IntArray) {
        val d = Widgets.data(ctx)
        for (id in ids) {
            val v = RemoteViews(ctx.packageName, R.layout.widget_calendar)
            Widgets.background(v, ctx, d)
            val accent = Widgets.accent(d, RED)
            v.setTextViewText(R.id.title, d?.optJSONObject("month")?.optString("title") ?: "Abre Calendario y Tareas")
            v.setTextColor(R.id.title, accent)
            Widgets.sp(v, R.id.title, 14f, Widgets.scale(d, "calendar.title"))
            v.setOnClickPendingIntent(R.id.title, Widgets.openApp(ctx, "open"))
            Widgets.fillMonth(ctx, v, d, Widgets.scale(d, "calendar.body"), accent)
            m.updateAppWidget(id, v)
        }
    }
}

/** Configura una lista con scroll (eventos o tareas) servida por ListService. */
private fun setList(ctx: Context, v: RemoteViews, widgetId: Int, kind: String) {
    val svc = Intent(ctx, ListService::class.java).putExtra("kind", kind)
    svc.data = Uri.parse("calendario://lista/$kind/$widgetId") // una lista distinta por widget
    @Suppress("DEPRECATION")
    v.setRemoteAdapter(R.id.list, svc)
    v.setEmptyView(R.id.list, R.id.list_empty)
    v.setPendingIntentTemplate(R.id.list, Widgets.template(ctx, kind.hashCode()))
}

/** Calendario y eventos. */
class AgendaWidget : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, m: AppWidgetManager, ids: IntArray) {
        val d = Widgets.data(ctx)
        val dark = Widgets.isDark(ctx, d)
        for (id in ids) {
            val v = RemoteViews(ctx.packageName, R.layout.widget_agenda)
            Widgets.background(v, ctx, d)
            val accent = Widgets.accent(d, RED)
            v.setTextViewText(R.id.cal_title, d?.optJSONObject("month")?.optString("title") ?: "")
            v.setTextColor(R.id.cal_title, accent)
            Widgets.sp(v, R.id.cal_title, 13f, Widgets.scale(d, "agenda.calTitle"))
            Widgets.fillMonth(ctx, v, d, Widgets.scale(d, "agenda.calBody"), accent)
            v.setTextViewText(R.id.title, d?.optJSONObject("agenda")?.optString("title") ?: "Abre Calendario y Tareas")
            v.setTextColor(R.id.title, Widgets.text(dark))
            Widgets.sp(v, R.id.title, 15f, Widgets.scale(d, "agenda.listTitle"))
            v.setOnClickPendingIntent(R.id.title, Widgets.openApp(ctx, "open"))
            Widgets.tint(v, R.id.add, Widgets.accent(d, BLUE))
            v.setOnClickPendingIntent(R.id.add, Widgets.openApp(ctx, "newEvent:" + (d?.optString("today") ?: "")))
            v.setTextViewText(R.id.list_empty, "Sin eventos")
            v.setTextColor(R.id.list_empty, Widgets.faint(dark))
            setList(ctx, v, id, "agenda")
            m.updateAppWidget(id, v)
        }
        m.notifyAppWidgetViewDataChanged(ids, R.id.list)
    }
}

/** Tareas. */
class TasksWidget : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, m: AppWidgetManager, ids: IntArray) {
        val d = Widgets.data(ctx)
        val dark = Widgets.isDark(ctx, d)
        val tasks = d?.optJSONObject("tasks")
        for (id in ids) {
            val v = RemoteViews(ctx.packageName, R.layout.widget_tasks)
            Widgets.background(v, ctx, d)
            val accent = Widgets.accent(d, BLUE)
            val scale = Widgets.scale(d, "tasks.title")
            v.setTextViewText(R.id.title, tasks?.optString("title") ?: "Abre Calendario y Tareas")
            v.setTextColor(R.id.title, Widgets.text(dark))
            Widgets.sp(v, R.id.title, 15f, scale)
            v.setTextViewText(R.id.count, if (tasks == null) "" else tasks.optInt("count").toString())
            v.setTextColor(R.id.count, accent)
            Widgets.sp(v, R.id.count, 18f, scale)
            v.setOnClickPendingIntent(R.id.title, Widgets.openApp(ctx, "tasks"))
            Widgets.tint(v, R.id.add, accent)
            v.setOnClickPendingIntent(R.id.add, Widgets.openApp(ctx, "newTask"))
            v.setTextViewText(R.id.list_empty, "Nada pendiente")
            v.setTextColor(R.id.list_empty, Widgets.faint(dark))
            v.setViewVisibility(R.id.list_empty, if (tasks == null) View.GONE else View.VISIBLE)
            setList(ctx, v, id, "tasks")
            m.updateAppWidget(id, v)
        }
        m.notifyAppWidgetViewDataChanged(ids, R.id.list)
    }
}
