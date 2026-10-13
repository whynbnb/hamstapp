package me.whynbnb.hamstapp

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** One stored notification: when it arrived and how much it is worth. */
class UnreadEntry(val pkg: String, val key: String, val at: Long, val declared: Int)

/**
 * Persisted set of **unread** notifications, grouped by package.
 *
 * The launcher's badges use "unread" semantics rather than mirroring the
 * notification shade: a notification stays unread after the user dismisses it
 * (or clears the whole shade) and only becomes read when the user opens it, the
 * owning app withdraws it, or the app is launched from the launcher.
 *
 * The count follows the algorithm the system launchers use (documented by
 * Xiaomi for HyperOS, and nubia behaves the same): every notification in the
 * shade contributes its declared `messageCount`
 * ([android.app.Notification.getNumber], e.g. "5 unread messages"), defaulting
 * to 1, and the per-app total is their sum — group summaries included, since a
 * summary is itself a notification in the shade.
 *
 * State is kept in memory and mirrored to [SharedPreferences] so badges survive
 * restarts. Keys come from [StatusBarNotification.getKey] (so updates do not
 * inflate the count); summaries use a synthetic per-group key.
 */
object NotificationStore {
    private const val PREFS = "hamstapp_notifications"
    private const val KEY = "unread"

    /** Hard cap per package; the oldest marks are dropped first. */
    private const val MAX_PER_PACKAGE = 199

    /** Safety valve so a badge an app never clears cannot live forever. */
    private const val MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000

    /** One stored notification: when it arrived, its declared count and how
     *  many times it has been posted since it became unread. */
    private class Mark(val at: Long, val declared: Int, val posts: Int)

    private var prefs: SharedPreferences? = null

    /** package -> (notification key -> mark) */
    private val unread = HashMap<String, MutableMap<String, Mark>>()

    /** Set by MainActivity to forward updates to the Dart channel. */
    @Volatile
    var sink: ((Map<String, Int>) -> Unit)? = null

    /** Diagnostics for the settings screen. */
    @Volatile
    var listenerConnected = false

    @Volatile
    var lastEventAt = 0L

    @Volatile
    var eventCount = 0L

    /** Recent notification events, newest last; flushed to the log when it is
     *  switched on so the history right before is not lost. */
    private const val MAX_EVENTS = 50

    private val events = ArrayDeque<String>()

    /** Set by MainActivity to forward log lines to Dart. */
    @Volatile
    var logSink: ((String, String) -> Unit)? = null

    /** Whether the user turned the in-app log on. */
    @Volatile
    var loggingEnabled = false

    fun noteConnected(connected: Boolean) {
        listenerConnected = connected
    }

    fun noteEvent() {
        lastEventAt = System.currentTimeMillis()
        eventCount++
    }

    fun addEvent(line: String, level: String = "info") {
        events.addLast(line)
        while (events.size > MAX_EVENTS) events.removeFirst()
        if (loggingEnabled) logSink?.invoke(level, line)
    }

    /** Re-sends the buffered events; called right after logging is switched on. */
    fun flushEvents() {
        if (!loggingEnabled) return
        events.toList().forEach { logSink?.invoke("info", it) }
    }

    @Synchronized
    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs = p
        load(p)
    }

    /**
     * Unread count per package.
     *
     * Each notification contributes its declared `messageCount`
     * ([android.app.Notification.getNumber], e.g. "5 unread messages"). Apps
     * that declare nothing (QQ does this) instead contribute **how many times
     * they reposted that notification** while it stayed unread — chat apps push
     * a fresh post per message, which is exactly how the vendor launchers end up
     * with a count. A key posted once is worth 1.
     */
    @Synchronized
    fun counts(): Map<String, Int> {
        val out = HashMap<String, Int>(unread.size)
        unread.forEach { (pkg, marks) ->
            if (marks.isEmpty()) return@forEach
            var total = 0
            marks.values.forEach { total += if (it.declared > 0) it.declared else it.posts }
            if (total > 0) out[pkg] = total
        }
        return out
    }

    @Synchronized
    fun markUnread(pkg: String, key: String, at: Long, declared: Int) {
        val marks = unread.getOrPut(pkg) { HashMap() }
        val existing = marks[key]
        // A newer declared count replaces the old one (a chat total can go
        // down after reading elsewhere); a post that declares nothing keeps it.
        val next = if (declared > 0) declared else existing?.declared ?: 0
        marks[key] = if (existing == null) {
            Mark(at, next, 1)
        } else {
            Mark(at, next, existing.posts + 1)
        }
        trim(pkg)
        persist()
    }

    /**
     * [markUnread] for many entries, persisting once. Used when importing the
     * shade: it does not bump [Mark.posts], so re-importing on every reconnect
     * cannot inflate the count.
     */
    @Synchronized
    fun markUnreadAll(entries: List<UnreadEntry>) {
        if (entries.isEmpty()) return
        val touched = HashSet<String>()
        entries.forEach { entry ->
            val marks = unread.getOrPut(entry.pkg) { HashMap() }
            val existing = marks[entry.key]
            val next = if (entry.declared > 0) entry.declared else existing?.declared ?: 0
            marks[entry.key] = if (existing == null) {
                Mark(entry.at, next, 1)
            } else {
                Mark(entry.at, next, existing.posts)
            }
            touched.add(entry.pkg)
        }
        touched.forEach { trim(it) }
        persist()
    }

    @Synchronized
    fun markRead(pkg: String, key: String) {
        val marks = unread[pkg] ?: return
        if (marks.remove(key) == null) return
        if (marks.isEmpty()) unread.remove(pkg)
        persist()
    }

    @Synchronized
    fun markAllRead(pkg: String) {
        if (unread.remove(pkg) != null) persist()
    }

    /** Pushes the current counts to Dart (no-op when no engine is attached). */
    fun emit() {
        sink?.invoke(counts())
    }

    private fun trim(pkg: String) {
        val marks = unread[pkg] ?: return
        if (marks.size <= MAX_PER_PACKAGE) return
        marks.entries
            .sortedBy { it.value.at }
            .take(marks.size - MAX_PER_PACKAGE)
            .forEach { marks.remove(it.key) }
    }

    private fun load(p: SharedPreferences) {
        val raw = p.getString(KEY, null) ?: return
        val now = System.currentTimeMillis()
        runCatching {
            val root = JSONObject(raw)
            root.keys().forEach { pkg ->
                val obj = root.optJSONObject(pkg) ?: return@forEach
                val marks = LinkedHashMap<String, Mark>()
                obj.keys().forEach { k ->
                    val (at, declared, posts) = readMark(obj, k)
                    if (at > 0 && now - at <= MAX_AGE_MS) {
                        marks[k] = Mark(at, declared, posts)
                    }
                }
                if (marks.isEmpty()) return@forEach
                unread[pkg] = if (marks.size > MAX_PER_PACKAGE) {
                    HashMap(
                        marks.entries
                            .sortedByDescending { it.value.at }
                            .take(MAX_PER_PACKAGE)
                            .associate { it.key to it.value },
                    )
                } else {
                    HashMap(marks)
                }
            }
        }
    }

    /** Reads one mark, tolerating the older `key -> timestamp` format. */
    private fun readMark(obj: JSONObject, key: String): Triple<Long, Int, Int> {
        val array = obj.optJSONArray(key)
        if (array is JSONArray && array.length() >= 1) {
            val at = array.optLong(0, 0L)
            val declared = if (array.length() >= 2) array.optInt(1, 0) else 0
            val posts = if (array.length() >= 3) array.optInt(2, 1) else 1
            return Triple(at, declared.coerceAtLeast(0), posts.coerceAtLeast(1))
        }
        return Triple(obj.optLong(key, 0L), 0, 1)
    }

    private fun persist() {
        val p = prefs ?: return
        runCatching {
            val root = JSONObject()
            unread.forEach { (pkg, marks) ->
                if (marks.isEmpty()) return@forEach
                val obj = JSONObject()
                marks.forEach { (key, mark) ->
                    obj.put(key, JSONArray().put(mark.at).put(mark.declared).put(mark.posts))
                }
                root.put(pkg, obj)
            }
            p.edit().putString(KEY, root.toString()).apply()
        }
    }
}
