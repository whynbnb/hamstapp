package me.whynbnb.hamstapp

import android.app.Activity
import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.util.Base64
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * State the desktop widget needs while Flutter is not running.
 *
 * Two things live here:
 *
 * * the document Dart pushes after a scan / launch / setting change — the
 *   suggestions for every hour of the day, plus the labels and the wording, so
 *   the widget never has to compute a recommendation (or start the engine);
 * * a queue of launches made from the widget. Dart drains it the next time 囤囤
 *   comes to the foreground, which is what makes a widget tap count in the
 *   launch statistics and in future recommendations.
 */
object WidgetStore {
    private const val PREFS = "hamstapp_widget"
    private const val KEY_DATA = "data"
    private const val KEY_PAGES = "pages"
    private const val KEY_PENDING = "pending_launches"

    /** Enough for a busy month; the queue only drains when 囤囤 is opened. */
    private const val MAX_PENDING = 500

    private val lock = Any()

    fun writeData(context: Context, json: String): Boolean = runCatching {
        JSONObject(json) // reject malformed data instead of storing it
        prefs(context).edit().putString(KEY_DATA, json).apply()
        true
    }.getOrDefault(false)

    fun readData(context: Context): JSONObject? = runCatching {
        val raw = prefs(context).getString(KEY_DATA, null)
        if (raw.isNullOrEmpty()) null else JSONObject(raw)
    }.getOrNull()

    /** Page tabs for the 4x1 strip: what to show and which one is current. */
    fun writePageData(context: Context, json: String): Boolean = runCatching {
        JSONObject(json) // reject malformed data instead of storing it
        prefs(context).edit().putString(KEY_PAGES, json).apply()
        true
    }.getOrDefault(false)

    fun readPageData(context: Context): JSONObject? = runCatching {
        val raw = prefs(context).getString(KEY_PAGES, null)
        if (raw.isNullOrEmpty()) null else JSONObject(raw)
    }.getOrNull()

    /**
     * Remembers one launch. `commit` (not `apply`) on purpose: the launcher may
     * kill 囤囤's process while the tapped app is in front, and losing the tap
     * would silently break the count.
     */
    fun recordLaunch(context: Context, packageName: String, at: Long) {
        if (packageName.isEmpty()) return
        synchronized(lock) {
            val prefs = prefs(context)
            val queue = runCatching {
                JSONArray(prefs.getString(KEY_PENDING, null) ?: "[]")
            }.getOrElse { JSONArray() }
            val first = (queue.length() - MAX_PENDING + 1).coerceAtLeast(0)
            val trimmed = JSONArray()
            for (i in first until queue.length()) trimmed.put(queue.get(i))
            trimmed.put(JSONObject().put("p", packageName).put("t", at))
            prefs.edit().putString(KEY_PENDING, trimmed.toString()).commit()
        }
    }

    /** Pending launches, oldest first. Cleared atomically. */
    fun consumeLaunches(context: Context): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        synchronized(lock) {
            val prefs = prefs(context)
            val raw = prefs.getString(KEY_PENDING, null)
            if (raw.isNullOrBlank()) return out
            prefs.edit().remove(KEY_PENDING).commit()
            val queue = runCatching { JSONArray(raw) }.getOrNull() ?: return out
            for (i in 0 until queue.length()) {
                val o = queue.optJSONObject(i) ?: continue
                val pkg = o.optString("p")
                if (pkg.isEmpty()) continue
                out.add(mapOf("p" to pkg, "t" to o.optLong("t", 0L)))
            }
        }
        return out
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/**
 * Draws the widget with RemoteViews.
 *
 * The layout is a fixed 4x2 grid; cells the current size (or the current
 * suggestion list) does not fill are hidden, so one layout serves everything
 * from a 4x1 strip to a 4x2 card. Icons are loaded here rather than shipped
 * from Dart: PackageManager already has them and the widget can be refreshed
 * without waking the Flutter engine.
 */
object WidgetRenderer {
    private const val CELLS = 8
    private const val COLUMNS = 4

    private val cellIds = intArrayOf(
        R.id.widget_cell_0, R.id.widget_cell_1, R.id.widget_cell_2,
        R.id.widget_cell_3, R.id.widget_cell_4, R.id.widget_cell_5,
        R.id.widget_cell_6, R.id.widget_cell_7,
    )
    private val iconIds = intArrayOf(
        R.id.widget_icon_0, R.id.widget_icon_1, R.id.widget_icon_2,
        R.id.widget_icon_3, R.id.widget_icon_4, R.id.widget_icon_5,
        R.id.widget_icon_6, R.id.widget_icon_7,
    )
    private val labelIds = intArrayOf(
        R.id.widget_label_0, R.id.widget_label_1, R.id.widget_label_2,
        R.id.widget_label_3, R.id.widget_label_4, R.id.widget_label_5,
        R.id.widget_label_6, R.id.widget_label_7,
    )
    private val rowIds = intArrayOf(R.id.widget_row_0, R.id.widget_row_1)

    private class Entry(
        val packageName: String,
        val label: String,
        val icon: Bitmap,
        /** Launcher activity the user pinned, or '' for the app's default. */
        val activity: String,
        /** Web-app config as JSON, or '' for an Android app. */
        val web: String,
    )

    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context) ?: return
        val ids = runCatching {
            manager.getAppWidgetIds(
                ComponentName(context, HamstappWidgetProvider::class.java),
            )
        }.getOrDefault(IntArray(0))
        for (id in ids) update(context, manager, id)
        // The system's updatePeriodMillis is only a hint and some launchers
        // stop honouring it once the app process dies. Re-arm our own alarm on
        // every render (cancel it when the last widget is gone).
        WidgetScheduler.schedule(context)
    }

    fun update(context: Context, manager: AppWidgetManager, widgetId: Int) {
        runCatching {
            val options = manager.getAppWidgetOptions(widgetId)
            manager.updateAppWidget(widgetId, build(context, widgetId, options))
        }
    }

    private fun build(context: Context, widgetId: Int, options: Bundle): RemoteViews {
        val data = WidgetStore.readData(context)
        val style = data?.optString("layout").orEmpty()
        val views = RemoteViews(
            context.packageName,
            if (style == "edges") {
                R.layout.widget_hamstapp_edges
            } else {
                R.layout.widget_hamstapp
            },
        )
        // Hosts report the portrait size as MIN_* and the landscape size as
        // MAX_*; the larger one is the safe estimate for "how much room is
        // there", and a launcher that only fills one of them still works.
        val widthDp = maxOf(
            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH),
            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH),
        ).takeIf { it > 0 } ?: 250
        val heightDp = maxOf(
            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT),
            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT),
        ).takeIf { it > 0 } ?: 150
        val columns = ((widthDp - 20) / 52).coerceIn(2, COLUMNS)

        views.setOnClickPendingIntent(R.id.widget_header, openApp(context, widgetId))
        // Quick actions on the right of the header.
        views.setOnClickPendingIntent(
            R.id.widget_quick_apps,
            shortcut(context, widgetId, 20, "apps"),
        )
        views.setOnClickPendingIntent(
            R.id.widget_quick_recent,
            shortcut(context, widgetId, 21, "recent"),
        )
        views.setOnClickPendingIntent(
            R.id.widget_quick_search,
            shortcut(context, widgetId, 22, "search"),
        )

        val title = slotFor(data)?.optString("title").orEmpty()
            .ifEmpty { data?.optString("title").orEmpty() }
            .ifEmpty { context.getString(R.string.widget_title) }
        views.setTextViewText(R.id.widget_title, title)
        val showLabels = data?.optBoolean("showLabels", true) ?: true
        val roundedIcons = data?.optBoolean("roundedIcons", false) ?: false

        val entries = loadEntries(context, data, columns * 2, roundedIcons)

        if (entries.isEmpty()) {
            views.setViewVisibility(R.id.widget_rows, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setTextViewText(
                R.id.widget_empty,
                data?.optString("empty").orEmpty()
                    .ifEmpty { context.getString(R.string.widget_empty_default) },
            )
            views.setOnClickPendingIntent(R.id.widget_empty, openApp(context, widgetId))
            return views
        }

        views.setViewVisibility(R.id.widget_rows, View.VISIBLE)
        views.setViewVisibility(R.id.widget_empty, View.GONE)

        // How a row that is not full is arranged. `spread` (the default)
        // shares it out evenly, `left` keeps the normal grid positions so the
        // icons stay packed to the left, and `edges` pushes the row's first
        // icon to the left edge and its last icon to the right edge. A really
        // short widget (4x1) only has room for the first row.
        val cols = if (style != "left" && style != "edges" &&
            entries.size < columns
        ) {
            entries.size
        } else {
            columns
        }
        val rows = if (entries.size > cols && heightDp >= 70) 2 else 1

        for (r in 0 until 2) {
            val used = r < rows && r * cols < entries.size
            views.setViewVisibility(rowIds[r], if (used) View.VISIBLE else View.GONE)
        }

        for (i in 0 until CELLS) {
            val row = i / COLUMNS
            val col = i % COLUMNS
            val slot = appIndexFor(style, row, col, rows, cols, entries.size)
            // With the `left` style an unused cell keeps its place instead of
            // collapsing, which leaves the icons at their normal grid slots.
            val placeholder = style == "left" && row < rows && slot < 0 && col < cols
            views.setViewVisibility(
                cellIds[i],
                when {
                    slot >= 0 -> View.VISIBLE
                    placeholder -> View.INVISIBLE
                    else -> View.GONE
                },
            )
            if (slot < 0) {
                // A hidden cell must not keep a PendingIntent from the previous
                // update: a later resize could reveal a stale app. Point it at
                // the app instead of clearing it, which older RemoteViews
                // implementations do not support for click actions.
                views.setOnClickPendingIntent(
                    cellIds[i],
                    openApp(context, widgetId),
                )
                continue
            }
            val entry = entries[slot]
            views.setImageViewBitmap(iconIds[i], entry.icon)
            views.setTextViewText(labelIds[i], entry.label)
            views.setViewVisibility(
                labelIds[i],
                if (showLabels) View.VISIBLE else View.GONE,
            )
            views.setContentDescription(cellIds[i], entry.label)
            views.setOnClickPendingIntent(
                cellIds[i],
                tap(context, widgetId, i, entry),
            )
        }
        return views
    }

    /**
     * Which suggestion a grid cell holds, or -1 when the cell stays empty.
     * The cell ids are fixed, so this only decides content and visibility.
     */
    private fun appIndexFor(
        style: String,
        row: Int,
        col: Int,
        rows: Int,
        cols: Int,
        count: Int,
    ): Int {
        if (row >= rows || col >= cols) return -1
        return when (style) {
            "edges" -> {
                val rowCount = (count - row * cols).coerceIn(0, cols)
                val slot = when {
                    rowCount <= 0 -> -1
                    // A single icon sits in the middle of the row.
                    rowCount == 1 -> if (col == cols / 2) 0 else -1
                    col == cols - 1 -> rowCount - 1
                    col < rowCount - 1 -> col
                    else -> -1
                }
                if (slot < 0) -1 else row * cols + slot
            }
            "left" -> {
                val index = row * cols + col
                if (index < count) index else -1
            }
            else -> {
                val rowCount = (count - row * cols).coerceIn(0, cols)
                if (col < rowCount) row * cols + col else -1
            }
        }
    }

    /** The slot for the current hour, falling back to the first one. */
    private fun slotFor(data: JSONObject?): JSONObject? {
        val slots = data?.optJSONArray("slots") ?: return null
        if (slots.length() == 0) return null
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        for (i in 0 until slots.length()) {
            val slot = slots.optJSONObject(i) ?: continue
            if (slot.optInt("h", -1) == hour) return slot
        }
        return slots.optJSONObject(0)
    }

    private fun loadEntries(
        context: Context,
        data: JSONObject?,
        capacity: Int,
        roundedIcons: Boolean,
    ): List<Entry> {
        val apps = slotFor(data)?.optJSONArray("apps")
            ?: data?.optJSONArray("fallback")
            ?: return emptyList()
        val pm = context.packageManager
        val size = iconSizePx(context)
        val out = ArrayList<Entry>(capacity)
        for (i in 0 until apps.length()) {
            if (out.size >= capacity) break
            val item = apps.optJSONObject(i) ?: continue
            val pkg = item.optString("p")
            if (pkg.isEmpty()) continue
            val label = item.optString("n").ifEmpty { appLabel(pm, pkg) }

            // A hand-added web app: PackageManager knows nothing about it, so
            // everything (icon, URL, window settings) comes from the payload.
            val web = item.optJSONObject("w")
            if (web != null) {
                if (web.optString("url").isEmpty()) continue
                val icon = (
                    bitmapFromData(context, data, pkg)
                        ?: letterIcon(label, size)
                    )
                    .let { if (roundedIcons) roundIcon(it) else it }
                    // A web app is a website behind an icon, so it gets a small
                    // globe in the corner — the widget has no room for the
                    // name tag the app list uses.
                    .let { withPwaBadge(context, it) }
                val config = JSONObject(web.toString())
                data?.optJSONObject("icons")?.optString(pkg)
                    ?.takeIf { it.isNotEmpty() }
                    ?.let { config.put("icon", it) }
                out.add(Entry(pkg, label.ifEmpty { pkg }, icon, "", config.toString()))
                continue
            }

            val activity = item.optString("a")
            if (!isLaunchable(pm, pkg, activity)) continue
            // An icon sent by Dart (a custom icon) wins over the system one,
            // matching what the tile board shows.
            val icon = (
                bitmapFromData(context, data, pkg)
                    ?: systemIcon(context, pm, pkg, activity, size)
                )?.let { if (roundedIcons) roundIcon(it) else it }
                ?: continue
            out.add(Entry(pkg, label.ifEmpty { pkg }, icon, activity, ""))
        }
        return out
    }

    private fun iconSizePx(context: Context): Int =
        (44 * context.resources.displayMetrics.density).toInt().coerceAtLeast(48)

    private fun isLaunchable(
        pm: PackageManager,
        pkg: String,
        activity: String,
    ): Boolean = runCatching {
        val info = pm.getApplicationInfo(pkg, 0)
        if (!info.enabled) return@runCatching false
        if (activity.isNotEmpty() &&
            runCatching {
                pm.getActivityInfo(ComponentName(pkg, activity), 0)
            }.isSuccess
        ) {
            return@runCatching true
        }
        pm.getLaunchIntentForPackage(pkg) != null
    }.getOrDefault(false)

    private fun appLabel(pm: PackageManager, pkg: String): String = runCatching {
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    }.getOrDefault(pkg)

    /** The pinned entry's icon when there is one, else the app's own. */
    private fun systemIcon(
        context: Context,
        pm: PackageManager,
        pkg: String,
        activity: String,
        size: Int,
    ): Bitmap? = runCatching {
        val drawable = (
            if (activity.isNotEmpty()) {
                runCatching {
                    pm.getActivityIcon(ComponentName(pkg, activity))
                }.getOrNull()
            } else {
                null
            }
            ) ?: pm.getApplicationIcon(pkg)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        bitmap
    }.getOrNull()

    /** Decodes an icon Dart sent for a custom icon or a web app. */
    private fun bitmapFromData(
        context: Context,
        data: JSONObject?,
        pkg: String,
    ): Bitmap? {
        val encoded = data?.optJSONObject("icons")?.optString(pkg)
        if (encoded.isNullOrEmpty()) return null
        val bytes = runCatching {
            Base64.decode(encoded, Base64.DEFAULT)
        }.getOrNull() ?: return null
        val source = runCatching {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }.getOrNull() ?: return null
        val size = iconSizePx(context)
        return if (source.width == size && source.height == size) {
            source
        } else {
            Bitmap.createScaledBitmap(source, size, size, true)
        }
    }

    /**
     * Draws a small globe badge in the bottom-right corner, marking a web app
     * (PWA). Colours follow the widget theme, so the badge reads on both the
     * light and the dark backdrop.
     */
    private fun withPwaBadge(context: Context, source: Bitmap): Bitmap {
        val output = Bitmap.createBitmap(
            source.width,
            source.height,
            Bitmap.Config.ARGB_8888,
        )
        val canvas = Canvas(output)
        canvas.drawBitmap(source, 0f, 0f, null)

        val size = minOf(source.width, source.height).toFloat()
        val badge = size * 0.38f
        val margin = size * 0.01f
        val cx = source.width - badge / 2f - margin
        val cy = source.height - badge / 2f - margin
        val back = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = context.getColor(R.color.widget_surface)
        }
        canvas.drawCircle(cx, cy, badge / 2f, back)

        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = badge * 0.085f
            strokeCap = Paint.Cap.ROUND
            color = context.getColor(R.color.widget_text_dim)
        }
        val r = badge * 0.27f
        canvas.drawCircle(cx, cy, r, stroke)
        // The meridian (a narrow ellipse) and the equator.
        canvas.drawOval(RectF(cx - r * 0.5f, cy - r, cx + r * 0.5f, cy + r), stroke)
        canvas.drawLine(cx - r, cy, cx + r, cy, stroke)
        return output
    }

    /**
     * Clips [source] to the rounded-square silhouette the home screen uses.
     * Only enabled from the widget options; apps keep their own icon shape by
     * default.
     */
    private fun roundIcon(source: Bitmap): Bitmap {
        val size = minOf(source.width, source.height)
        if (size <= 0) return source
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val radius = size * 0.22f
        canvas.drawRoundRect(
            0f,
            0f,
            size.toFloat(),
            size.toFloat(),
            radius,
            radius,
            paint,
        )
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(
            source,
            (size - source.width) / 2f,
            (size - source.height) / 2f,
            paint,
        )
        return output
    }

    /** Placeholder for a web app that has no cached icon yet. */
    private fun letterIcon(label: String, size: Int): Bitmap {
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        var hash = 0
        for (c in label) hash = hash * 31 + c.code
        val hue = ((hash % 360) + 360) % 360
        val background = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.HSVToColor(floatArrayOf(hue.toFloat(), 0.55f, 0.55f))
        }
        val radius = size * 0.26f
        canvas.drawRoundRect(
            0f,
            0f,
            size.toFloat(),
            size.toFloat(),
            radius,
            radius,
            background,
        )
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = size * 0.45f
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
        val baseline = size / 2f - (text.descent() + text.ascent()) / 2f
        canvas.drawText(
            label.trim().take(1).ifEmpty { "?" },
            size / 2f,
            baseline,
            text,
        )
        return out
    }

    /** Opens 囤囤 on a screen; MainActivity forwards the action to Dart. */
    private fun shortcut(
        context: Context,
        widgetId: Int,
        slot: Int,
        action: String,
    ): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            this.action = "me.whynbnb.hamstapp.action.SHORTCUT"
            putExtra("hamstapp.action", action)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context,
            widgetId * 32 + slot,
            intent,
            flags(),
        )
    }

    private fun openApp(context: Context, widgetId: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(context, 900_000 + widgetId, intent, flags())
    }

    private fun tap(
        context: Context,
        widgetId: Int,
        index: Int,
        entry: Entry,
    ): PendingIntent {
        val intent = Intent(context, WidgetTapActivity::class.java).apply {
            action = WidgetTapActivity.ACTION_TAP
            putExtra(WidgetTapActivity.EXTRA_PACKAGE, entry.packageName)
            if (entry.activity.isNotEmpty()) {
                putExtra(WidgetTapActivity.EXTRA_ACTIVITY, entry.activity)
            }
            if (entry.web.isNotEmpty()) {
                putExtra(WidgetTapActivity.EXTRA_WEB, entry.web)
            }
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION
        }
        return PendingIntent.getActivity(
            context,
            widgetId * 16 + index,
            intent,
            flags(),
        )
    }

    private fun flags(): Int =
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
}

/**
 * Keeps the widget ticking while 囤囤 is not running.
 *
 * `updatePeriodMillis` is only a hint; many launchers/OEMs throttle it (or stop
 * delivering it) once the app process is gone, which leaves the widget on the
 * slot from the last time the app ran. An inexact alarm wakes the provider,
 * repaints from the stored document (it already has one entry per hour) and
 * re-arms itself. No service and no wake lock: a few RemoteViews every half
 * hour, roughly one alarm per doze window.
 */
object WidgetScheduler {
    private const val ACTION = "me.whynbnb.hamstapp.action.WIDGET_REFRESH"
    private const val REQUEST_CODE = 0x77A1
    private const val INTERVAL_MS = 30 * 60 * 1000L

    fun schedule(context: Context) {
        val manager = AppWidgetManager.getInstance(context) ?: return
        val ids = runCatching {
            manager.getAppWidgetIds(
                ComponentName(context, HamstappWidgetProvider::class.java),
            )
        }.getOrDefault(IntArray(0))
        if (ids.isEmpty()) {
            cancel(context)
            return
        }
        val alarms = context.getSystemService(Context.ALARM_SERVICE)
            as? AlarmManager ?: return
        val now = System.currentTimeMillis()
        val next = now - now % INTERVAL_MS + INTERVAL_MS
        runCatching {
            // Inexact on purpose: exact alarms need a special permission on
            // Android 12+ and the widget only needs the current hour, not a
            // millisecond-precise tick.
            alarms.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                next,
                pending(context),
            )
        }
    }

    fun cancel(context: Context) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE)
            as? AlarmManager ?: return
        runCatching { alarms.cancel(pending(context)) }
    }

    private fun pending(context: Context): PendingIntent {
        val intent = Intent(context, WidgetRefreshReceiver::class.java)
            .setAction(ACTION)
        return PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

/** Alarm target: repaint the stored document and keep the chain going. */
class WidgetRefreshReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        WidgetRenderer.updateAll(context)
        WidgetScheduler.schedule(context)
    }
}

/**
 * The widget itself. It only rebuilds a handful of RemoteViews on the
 * platform's tick, on resize, on our own alarm and when Dart pushes new
 * suggestions; there is no service and no wake lock.
 */
class HamstappWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) WidgetRenderer.update(context, appWidgetManager, id)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle?,
    ) {
        WidgetRenderer.update(context, appWidgetManager, appWidgetId)
    }

    override fun onEnabled(context: Context) {
        WidgetScheduler.schedule(context)
    }

    override fun onDisabled(context: Context) {
        WidgetScheduler.cancel(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            // A widget keeps the RemoteViews the old build produced until
            // someone repaints it. Installing an update must not leave the old
            // layout on the home screen.
            Intent.ACTION_MY_PACKAGE_REPLACED,
            // Alarms do not survive a reboot; start the chain again. The clock
            // or timezone moving also changes which hourly slot is current.
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED -> {
                WidgetRenderer.updateAll(context)
                WidgetScheduler.schedule(context)
            }
        }
    }
}

/**
 * Invisible trampoline behind every widget icon.
 *
 * Widget clicks must launch another app and still be counted, but a
 * BroadcastReceiver cannot reliably start an activity on recent Android
 * versions. A transparent activity launched by the PendingIntent is always
 * allowed to start the target, records the tap first, and finishes before it
 * would ever draw. It also knows how to open a hand-added web app, whose window
 * host is [WebAppActivity].
 */
class WidgetTapActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            if (intent?.action == ACTION_TAP) {
                val pkg = intent.getStringExtra(EXTRA_PACKAGE).orEmpty()
                if (pkg.isNotEmpty()) {
                    // Count it before launching: the tap happened even if the
                    // target refuses to start (disabled or just uninstalled).
                    WidgetStore.recordLaunch(this, pkg, System.currentTimeMillis())
                    // Launching from the widget reads that app's notifications,
                    // exactly like a launch started inside 囤囤.
                    runCatching {
                        NotificationStore.init(applicationContext)
                        NotificationStore.markAllRead(pkg)
                        NotificationStore.emit()
                    }
                    val web = intent.getStringExtra(EXTRA_WEB)
                    if (!web.isNullOrEmpty()) {
                        launchWeb(JSONObject(web))
                    } else {
                        launchApp(
                            pkg,
                            intent.getStringExtra(EXTRA_ACTIVITY).orEmpty(),
                        )?.let { startActivity(it) }
                    }
                }
            }
        } catch (_: Throwable) {
            // An invisible helper must never stay on screen, so failures here
            // simply mean "nothing launched".
        } finally {
            finish()
        }
    }

    /**
     * The chosen launcher entry when it still exists, else whatever the system
     * would open for the package. Several entries of one package can look and
     * launch differently (contacts and the dialer, say).
     */
    private fun launchApp(packageName: String, activity: String): Intent? {
        val pm = packageManager
        if (activity.isNotEmpty()) {
            val explicit = Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setComponent(ComponentName(packageName, activity))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (pm.resolveActivity(explicit, 0) != null) return explicit
        }
        return runCatching {
            val base = pm.getLaunchIntentForPackage(packageName)
                ?: run {
                    val probe = Intent(Intent.ACTION_MAIN)
                        .addCategory(Intent.CATEGORY_LAUNCHER)
                        .setPackage(packageName)
                    val info = pm.queryIntentActivities(probe, 0)
                        .firstOrNull()?.activityInfo ?: return null
                    Intent(probe).setComponent(
                        ComponentName(info.packageName, info.name),
                    )
                }
            base.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            base
        }.getOrNull()
    }

    /** A hand-added web app: its own window when asked for, else a browser. */
    private fun launchWeb(config: JSONObject) {
        val url = config.optString("url")
        if (url.isEmpty()) return
        val mode = config.optString("mode", "standalone")
        if (mode != "browser" && startWebWindow(url, config)) return
        openInBrowser(url, config.optString("browser"))
    }

    private fun startWebWindow(url: String, config: JSONObject): Boolean =
        runCatching {
            val intent = Intent(this, WebAppActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_NEW_DOCUMENT,
                )
                data = Uri.parse(url)
                putExtra(WebAppActivity.EXTRA_URL, url)
                putExtra(WebAppActivity.EXTRA_NAME, config.optString("name"))
                putExtra(
                    WebAppActivity.EXTRA_DISPLAY,
                    config.optString("display", "standalone"),
                )
                putExtra(WebAppActivity.EXTRA_SCOPE, config.optString("scope"))
                putExtra(
                    WebAppActivity.EXTRA_BROWSER,
                    config.optString("browser"),
                )
                putExtra(
                    WebAppActivity.EXTRA_HIDE_STATUS_BAR,
                    config.optBoolean("hide"),
                )
                putExtra(
                    WebAppActivity.EXTRA_THEME_COLOR,
                    config.optInt("theme"),
                )
                putExtra(
                    WebAppActivity.EXTRA_BACKGROUND_COLOR,
                    config.optInt("bg"),
                )
                val icon = config.optString("icon")
                if (icon.isNotEmpty()) {
                    val bytes = runCatching {
                        Base64.decode(icon, Base64.DEFAULT)
                    }.getOrNull()
                    if (bytes != null && bytes.isNotEmpty()) {
                        putExtra(WebAppActivity.EXTRA_ICON, bytes)
                    }
                }
            }
            startActivity(intent)
            true
        }.getOrDefault(false)

    private fun openInBrowser(url: String, browser: String) {
        val base = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (browser.isNotEmpty()) {
            val picked = Intent(base).setPackage(browser)
            if (picked.resolveActivity(packageManager) != null &&
                runCatching { startActivity(picked) }.isSuccess
            ) {
                return
            }
        }
        runCatching { startActivity(base) }
    }

    companion object {
        const val ACTION_TAP = "me.whynbnb.hamstapp.action.WIDGET_TAP"
        const val EXTRA_PACKAGE = "me.whynbnb.hamstapp.extra.WIDGET_PACKAGE"
        const val EXTRA_ACTIVITY = "me.whynbnb.hamstapp.extra.WIDGET_ACTIVITY"
        const val EXTRA_WEB = "me.whynbnb.hamstapp.extra.WIDGET_WEB"
    }
}
