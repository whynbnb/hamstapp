package me.whynbnb.hamstapp

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Records which apps currently have **unread** notifications so the launcher can
 * draw a bubble on their icons.
 *
 * Unlike the notification shade this is not cleared when a notification is
 * dismissed: see [NotificationStore]. Counts are pushed to Dart through
 * [NotificationStore.sink], which MainActivity points at the `hamstapp/apps`
 * method channel, and can also be read on demand.
 *
 * The system only hands out notifications while this listener is bound, so
 * everything still in the shade is imported when the listener connects
 * ([importActive]) — otherwise notifications that predate the connection would
 * never get a badge.
 *
 * Which notifications count follows what the system launchers do (as documented
 * by Xiaomi for HyperOS, and nubia matches): every shade notification except
 * **media**, **progress** and **ongoing** ones, each contributing its declared
 * `messageCount` (`Notification.getNumber()`, default 1). Group summaries are
 * kept and counted too — they are notifications in the shade as well.
 *
 * Note: [getActiveNotifications] is only called from `onListenerConnected`,
 * never from the posted/removed callbacks, where re-entering the system service
 * can stall the listener.
 *
 * Notification-listener access is a special, user-granted permission (it cannot
 * be requested with a runtime dialog); until the user enables it the system
 * never binds this service and no counts are produced.
 */
class NotifListenerService : NotificationListenerService() {

    /**
     * A count the app itself printed, e.g. "6条新消息" / "6 unread". Only used
     * when the notification sets no `number`; deliberately no bare-number match
     * so a message body like "2" is never mistaken for a count.
     */
    private val COUNT_PATTERNS = listOf(
        Regex("""(\d{1,3})\s*条\s*(新消息|未读消息|未读|新信息)"""),
        Regex("""(\d{1,3})\s*new\s+messages?""", RegexOption.IGNORE_CASE),
        Regex("""(\d{1,3})\s*unread""", RegexOption.IGNORE_CASE),
    )

    override fun onListenerConnected() {
        super.onListenerConnected()
        NotificationStore.init(applicationContext)
        NotificationStore.noteConnected(true)
        importActive()
        NotificationStore.emit()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        NotificationStore.noteConnected(false)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        val posted = sbn ?: return
        val pkg = posted.packageName ?: return
        if (pkg == packageName) return
        NotificationStore.init(applicationContext)
        NotificationStore.noteEvent()
        val ignored = isIgnored(posted)
        val declared = declaredOf(posted)
        NotificationStore.addEvent(
            describe("POST", posted, if (ignored) "IGNORED" else "d=$declared"),
        )
        if (!ignored) {
            NotificationStore.markUnread(pkg, storeKey(posted), now(), declared)
        }
        NotificationStore.emit()
    }

    override fun onNotificationRemoved(
        sbn: StatusBarNotification?,
        rankingMap: RankingMap?,
        reason: Int,
    ) {
        super.onNotificationRemoved(sbn, rankingMap, reason)
        val removed = sbn ?: return
        val pkg = removed.packageName ?: return
        if (pkg == packageName) return
        // Only an explicit user action (tapping the notification) or the app
        // itself withdrawing it means "read". Everything else — user swipes,
        // "clear all", and the system's group-summary churn (REASON_GROUP_
        // SUMMARY_CANCELED, which fires right after many updates) — must keep
        // the notification unread, otherwise the count flickers or collapses.
        val read = reason == REASON_CLICK ||
            reason == REASON_APP_CANCEL ||
            reason == REASON_APP_CANCEL_ALL
        NotificationStore.init(applicationContext)
        NotificationStore.noteEvent()
        NotificationStore.addEvent(
            describe("REMOVE", removed, "reason=$reason ${if (read) "drop" else "KEEP"}"),
        )
        if (!read) return
        NotificationStore.markRead(pkg, storeKey(removed))
        NotificationStore.emit()
    }

    /** One compact line describing an event, for the diagnostics dialog. */
    private fun describe(action: String, sbn: StatusBarNotification, extra: String): String {
        val n = sbn.notification
        val flags = n?.flags ?: 0
        val extras = n?.extras
        return buildString {
            append(action).append(' ').append(sbn.packageName)
            val number = n?.number ?: 0
            if (number > 0) append(" n=").append(number)
            if ((flags and Notification.FLAG_GROUP_SUMMARY) != 0) append(" SUM")
            if ((flags and Notification.FLAG_ONGOING_EVENT) != 0) append(" ONG")
            if ((flags and Notification.FLAG_FOREGROUND_SERVICE) != 0) append(" FGS")
            if (extras?.containsKey(Notification.EXTRA_MEDIA_SESSION) == true) append(" MEDIA")
            if ((extras?.getInt(Notification.EXTRA_PROGRESS_MAX, 0) ?: 0) > 0) append(" PROG")
            extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.let {
                if (it.isNotEmpty()) append(" [").append(it.take(20)).append(']')
            }
            extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.let {
                if (it.isNotEmpty()) append(" {").append(it.take(28)).append('}')
            }
            append(" key=").append(sbn.key)
            if (extra.isNotEmpty()) append(' ').append(extra)
        }
    }

    /** Imports every notification currently in the shade as unread. */
    private fun importActive() {
        val active: Array<StatusBarNotification> = try {
            activeNotifications ?: emptyArray()
        } catch (_: Throwable) {
            emptyArray()
        }
        val now = now()
        val entries = ArrayList<UnreadEntry>()
        for (sbn in active) {
            val pkg = sbn.packageName ?: continue
            if (pkg == packageName || isIgnored(sbn)) continue
            entries.add(UnreadEntry(pkg, storeKey(sbn), now, declaredOf(sbn)))
        }
        NotificationStore.markUnreadAll(entries)
    }

    /**
     * Store key for one notification: summaries get one key per group, real
     * notifications keep their unique key but carry their group so the summary
     * can be matched to its children.
     */
    private fun storeKey(sbn: StatusBarNotification): String =
        if (isGroupSummary(sbn)) {
            "#s:${sbn.groupKey ?: ""}"
        } else {
            "#g:${sbn.groupKey ?: ""}|${sbn.key}"
        }

    /** The count this notification declares for itself (0 when it declares none). */
    private fun declaredOf(sbn: StatusBarNotification): Int {
        val n = sbn.notification ?: return 0
        if (n.number > 0) return n.number.coerceAtMost(999)
        // Some chat apps never set `number` but print the total themselves
        // ("鱼板敲好吃(6条新消息)"); that text is the only generic source left.
        val title = n.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = n.extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        for (source in listOf(title, text)) {
            val value = parseCount(source)
            if (value > 0) return value
        }
        return 0
    }

    private fun parseCount(raw: String): Int {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return 0
        for (pattern in COUNT_PATTERNS) {
            val match = pattern.find(trimmed) ?: continue
            val value = match.groupValues.getOrNull(1)?.toIntOrNull() ?: continue
            if (value in 1..999) return value
        }
        return 0
    }

    private fun isGroupSummary(sbn: StatusBarNotification): Boolean =
        ((sbn.notification?.flags ?: 0) and Notification.FLAG_GROUP_SUMMARY) != 0

    /**
     * Notifications the system launchers leave out of the badge: ongoing /
     * foreground-service, media and progress ones are not "unread messages".
     */
    private fun isIgnored(sbn: StatusBarNotification): Boolean {
        val n = sbn.notification ?: return false
        val flags = n.flags
        if ((flags and (Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE)) != 0) {
            return true
        }
        val extras = n.extras
        if (extras.containsKey(Notification.EXTRA_MEDIA_SESSION)) return true
        return extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0) > 0
    }

    private fun now(): Long = System.currentTimeMillis()
}
