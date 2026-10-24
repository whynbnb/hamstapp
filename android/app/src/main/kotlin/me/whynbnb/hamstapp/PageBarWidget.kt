package me.whynbnb.hamstapp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * A 4x1 strip with the tile board's page tabs.
 *
 * Tapping a tab opens 囤囤 on that page (the normal launcher-shortcut plumbing
 * in MainActivity -> Dart). The page list only changes while the app is
 * running, so there is no periodic update: Dart pushes a new document and the
 * widgets are rebuilt once.
 */
object PageBarRenderer {
    private const val CHIPS = 8

    private val chipIds = intArrayOf(
        R.id.pagebar_0,
        R.id.pagebar_1,
        R.id.pagebar_2,
        R.id.pagebar_3,
        R.id.pagebar_4,
        R.id.pagebar_5,
        R.id.pagebar_6,
        R.id.pagebar_7,
    )

    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context) ?: return
        val ids = runCatching {
            manager.getAppWidgetIds(
                ComponentName(context, PageBarWidgetProvider::class.java),
            )
        }.getOrDefault(IntArray(0))
        for (id in ids) update(context, manager, id)
    }

    fun update(context: Context, manager: AppWidgetManager, widgetId: Int) {
        runCatching {
            val options = manager.getAppWidgetOptions(widgetId)
            manager.updateAppWidget(widgetId, build(context, widgetId, options))
        }
    }

    private fun build(
        context: Context,
        widgetId: Int,
        options: Bundle,
    ): RemoteViews {
        val data = WidgetStore.readPageData(context)
        val pages = data?.optJSONArray("pages")
        val total = pages?.length() ?: 0
        val current = data?.optInt("current", -1) ?: -1
        // The current page is marked with a pill by default; the `dot` style
        // only puts a small dot underneath it.
        val dotMarker = data?.optString("marker") == "dot"
        // The portrait size: the row must fit what is actually on screen. The
        // landscape maximum is wider, but using it would overflow in portrait.
        val widthDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
            .takeIf { it > 0 } ?: 250
        val available = (widthDp - 8).coerceAtLeast(40)

        if (total == 0) {
            val views = RemoteViews(context.packageName, R.layout.widget_pagebar)
            views.setViewVisibility(chipIds[0], View.VISIBLE)
            views.setTextViewText(
                chipIds[0],
                context.getString(R.string.pagebar_widget_empty),
            )
            views.setInt(
                chipIds[0],
                "setBackgroundResource",
                R.drawable.page_chip,
            )
            views.setTextColor(
                chipIds[0],
                context.getColor(R.color.widget_text_dim),
            )
            views.setOnClickPendingIntent(
                chipIds[0],
                target(context, widgetId, 0, "tiles"),
            )
            for (i in 1 until CHIPS) {
                views.setViewVisibility(chipIds[i], View.GONE)
            }
            return views
        }

        // Prefer pills that hug their label and sit centred, so two or three
        // pages do not turn into wide stretched bars. The text shrinks a
        // little first; the equal-width layout is only the last resort.
        val density = context.resources.displayMetrics.density
        val paint = Paint().apply { typeface = Typeface.DEFAULT }
        fun chipSize(name: String): Boolean = isShortName(name)
        // Pages whose name is a single emoji (or one or two characters) get a
        // much larger glyph; text pages stay at a readable size. Candidate
        // pairs shrink together only as far as the row needs.
        val candidates = intArrayOf(
            30, 15,
            28, 15,
            26, 14,
            24, 14,
            22, 13,
            20, 13,
            18, 12,
            16, 12,
            14, 11,
            12, 10,
        )
        var shortSp = 0f
        var longSp = 0f
        if (total <= CHIPS) {
            var i = 0
            while (i < candidates.size) {
                val candidateShort = candidates[i].toFloat()
                val candidateLong = candidates[i + 1].toFloat()
                var width = 0f
                for (p in 0 until total) {
                    val name = pageName(pages!!.optJSONObject(p))
                    paint.textSize = (
                        if (chipSize(name)) candidateShort else candidateLong
                        ) * density
                    width += paint.measureText(name) +
                        // 8dp padding each side + 2dp margins each side, plus
                        // a small safety margin.
                        24f * density
                }
                if (width <= available * density) {
                    shortSp = candidateShort
                    longSp = candidateLong
                    break
                }
                i += 2
            }
        }
        var allShort = true
        for (p in 0 until total) {
            if (!chipSize(pageName(pages!!.optJSONObject(p)))) {
                allShort = false
                break
            }
        }

        // Two possible layouts: content-sized pills (nice for a short list,
        // lets the current-page pill hug its label) or equal cells (keeps every
        // page visible and allows larger glyphs when there are more). Pick the
        // one that draws the labels bigger; if equal cells would have to hide
        // pages, stay with the pills and show everything.
        val maxSlots = (available / 38).coerceIn(1, CHIPS)
        val fillSlots = minOf(total, maxSlots)
        val fillChipWidth =
            ((available - 4 * fillSlots).coerceAtLeast(1)) / maxOf(fillSlots, 1)
        val fillShortSp = when {
            fillChipWidth >= 44 -> 28f
            fillChipWidth >= 36 -> 24f
            fillChipWidth >= 30 -> 20f
            else -> 16f
        }
        val fillLongSp = when {
            fillChipWidth >= 46 -> 14f
            fillChipWidth >= 38 -> 13f
            fillChipWidth >= 32 -> 12f
            else -> 11f
        }
        val fillShowsAll = total <= maxSlots
        val useFill = when {
            shortSp <= 0f -> true
            !fillShowsAll -> false
            allShort -> fillShortSp > shortSp
            else -> fillLongSp > longSp
        }
        val natural = !useFill

        val views = RemoteViews(
            context.packageName,
            if (natural) R.layout.widget_pagebar else R.layout.widget_pagebar_fill,
        )

        val overflow = useFill && total > maxSlots
        val shownPages = if (overflow) {
            (fillSlots - 1).coerceAtLeast(0)
        } else {
            total
        }
        val moreSlot = if (overflow) shownPages else -1

        for (i in 0 until CHIPS) {
            val chip = chipIds[i]
            val isPage = i < shownPages
            val isMore = i == moreSlot
            if (!isPage && !isMore) {
                views.setViewVisibility(chip, View.GONE)
                continue
            }
            views.setViewVisibility(chip, View.VISIBLE)
            if (isPage) {
                val page = pages!!.optJSONObject(i) ?: continue
                val name = pageName(page)
                val size = if (natural) {
                    if (chipSize(name)) shortSp else longSp
                } else {
                    if (chipSize(name)) fillShortSp else fillLongSp
                }
                views.setTextViewTextSize(
                    chip,
                    TypedValue.COMPLEX_UNIT_SP,
                    size,
                )
                val active = i == current
                views.setTextViewText(chip, name)
                views.setContentDescription(chip, name)
                views.setInt(
                    chip,
                    "setBackgroundResource",
                    when {
                        !active -> R.drawable.page_chip_empty
                        dotMarker -> R.drawable.page_chip_dot
                        else -> R.drawable.page_chip_active
                    },
                )
                views.setTextColor(
                    chip,
                    context.getColor(
                        if (active) R.color.widget_text else R.color.widget_text_dim,
                    ),
                )
                views.setOnClickPendingIntent(
                    chip,
                    target(context, widgetId, i, "page:" + page.optString("id")),
                )
            } else {
                views.setTextViewTextSize(
                    chip,
                    TypedValue.COMPLEX_UNIT_SP,
                    if (natural) longSp else fillLongSp,
                )
                views.setTextViewText(chip, "…")
                views.setContentDescription(
                    chip,
                    context.getString(R.string.pagebar_widget_label),
                )
                views.setInt(
                    chip,
                    "setBackgroundResource",
                    R.drawable.page_chip_empty,
                )
                views.setTextColor(
                    chip,
                    context.getColor(R.color.widget_text_dim),
                )
                views.setOnClickPendingIntent(
                    chip,
                    target(context, widgetId, i, "tiles"),
                )
            }
        }
        return views
    }

    private fun pageName(page: JSONObject?): String {
        if (page == null) return ""
        return page.optString("n").ifEmpty { page.optString("id") }
    }

    /**
     * True for a single emoji (or one or two characters), which the strip draws
     * much larger than a text label. Emoji names contain no letters or digits.
     */
    private fun isShortName(name: String): Boolean {
        val text = name.trim()
        if (text.isEmpty()) return false
        if (text.length <= 2) return true
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            if (Character.isLetterOrDigit(cp) || Character.isWhitespace(cp)) {
                return false
            }
            i += Character.charCount(cp)
        }
        return true
    }

    /**
     * Opens 囤囤 with a launcher-shortcut action; MainActivity reads the same
     * extra the long-press shortcuts use, so Dart already knows what to do.
     */
    private fun target(
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
            widgetId * 8 + slot,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

class PageBarWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            PageBarRenderer.update(context, appWidgetManager, id)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle?,
    ) {
        PageBarRenderer.update(context, appWidgetManager, appWidgetId)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        // Rebuild with the current code after installing an update.
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            PageBarRenderer.updateAll(context)
        }
    }
}
