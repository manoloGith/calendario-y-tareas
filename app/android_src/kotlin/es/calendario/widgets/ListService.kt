// Contenido de las listas con scroll de los widgets (eventos y tareas).
package es.calendario.widgets

import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.calendario.calendario.R
import org.json.JSONArray
import org.json.JSONObject

class ListService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        ListFactory(applicationContext, intent.getStringExtra("kind") ?: "tasks")
}

class ListFactory(private val ctx: Context, private val kind: String) : RemoteViewsService.RemoteViewsFactory {
    private var data: JSONObject? = null
    private var items = JSONArray()

    override fun onCreate() {}
    override fun onDestroy() {}

    override fun onDataSetChanged() {
        data = Widgets.data(ctx)
        items = data?.optJSONObject(kind)?.optJSONArray("items") ?: JSONArray()
    }

    override fun getCount(): Int = items.length()
    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 3
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false

    override fun getViewAt(position: Int): RemoteViews {
        val it = items.optJSONObject(position) ?: JSONObject()
        val dark = Widgets.isDark(ctx, data)
        val scale = Widgets.scale(data, if (kind == "agenda") "agenda.listBody" else "tasks.body")
        // Cabecera de día («HOY», «MAÑANA», «JUE 6 NOV»)
        if (it.has("h")) {
            val v = RemoteViews(ctx.packageName, R.layout.widget_list_header)
            v.setTextViewText(R.id.header, it.optString("h"))
            v.setTextColor(R.id.header, Widgets.sec(dark))
            Widgets.sp(v, R.id.header, 11f, scale)
            return v
        }
        if (kind == "agenda") {
            val v = RemoteViews(ctx.packageName, R.layout.widget_event_item)
            v.setInt(R.id.dot, "setColorFilter", Widgets.parse(it.optString("c"), Widgets.sec(dark)))
            v.setTextViewText(R.id.title, it.optString("t"))
            v.setTextColor(R.id.title, Widgets.text(dark))
            Widgets.sp(v, R.id.title, 13f, scale)
            v.setTextViewText(R.id.time, it.optString("time"))
            v.setTextColor(R.id.time, Widgets.sec(dark))
            Widgets.sp(v, R.id.time, 12f, scale)
            v.setViewVisibility(R.id.clip, if (it.optBoolean("clip")) View.VISIBLE else View.GONE)
            v.setInt(R.id.clip, "setColorFilter", Widgets.sec(dark))
            v.setOnClickFillInIntent(R.id.item_root, Widgets.fillIn("day:" + it.optString("date")))
            return v
        }
        val v = RemoteViews(ctx.packageName, R.layout.widget_task_item)
        v.setInt(R.id.ring, "setColorFilter", Widgets.parse(it.optString("c"), Widgets.sec(dark)))
        v.setTextViewText(R.id.title, it.optString("t"))
        v.setTextColor(R.id.title, Widgets.text(dark))
        Widgets.sp(v, R.id.title, 13f, scale)
        v.setTextViewText(R.id.meta, it.optString("meta"))
        v.setTextColor(R.id.meta, if (it.optBoolean("overdue")) Widgets.danger(dark) else Widgets.sec(dark))
        Widgets.sp(v, R.id.meta, 11f, scale)
        v.setViewVisibility(R.id.clip, if (it.optBoolean("clip")) View.VISIBLE else View.GONE)
        v.setInt(R.id.clip, "setColorFilter", Widgets.sec(dark))
        v.setOnClickFillInIntent(R.id.item_root, Widgets.fillIn("task:" + it.optString("id")))
        return v
    }
}
