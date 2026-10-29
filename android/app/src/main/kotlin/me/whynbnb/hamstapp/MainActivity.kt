package me.whynbnb.hamstapp

import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.DragEvent
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val channelName = "hamstapp/apps"
    private var plugin: PackageScannerPlugin? = null
    private var channel: MethodChannel? = null

    /** When true the status bar is kept hidden; re-applied on every refocus. */
    private var statusBarHidden = false

    /**
     * Shortcut tapped before Dart was listening (cold start). Dart pulls it with
     * `consumeShortcut` once it is up; while running the same action is pushed.
     */
    private var pendingShortcut: String? = null

    /** Extra the static shortcuts carry; see res/xml/shortcuts.xml. */
    private val shortcutExtra = "hamstapp.action"

    /** Action carried by every 囤囤 shortcut intent, static or dynamic. */
    private val shortcutAction = "me.whynbnb.hamstapp.action.SHORTCUT"

    /**
     * Set once the engine is configured, so a shortcut tapped while the app is
     * alive reaches Dart immediately; null before that (cold start), when the
     * action waits in [pendingShortcut] for Dart to pull it.
     */
    private var shortcutSink: ((String) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        val p = PackageScannerPlugin(applicationContext, ch)
        plugin = p
        // Forward notification-listener updates to Dart while this engine lives.
        NotificationStore.sink = { counts ->
            runCatching { ch.invokeMethod("notificationsChanged", mapOf("counts" to counts)) }
        }
        // Forward native events into the in-app log (only while it is on).
        NotificationStore.logSink = { module, level, text ->
            runCatching {
                ch.invokeMethod(
                    "nativeLog",
                    mapOf("module" to module, "level" to level, "text" to text),
                )
            }
        }
        // A shortcut tapped while the app is already running: hand it to Dart.
        shortcutSink = { id -> runCatching { ch.invokeMethod("shortcut", mapOf("id" to id)) } }
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "setStatusBarHidden" -> {
                    statusBarHidden = call.arguments as? Boolean ?: false
                    applyStatusBarVisibility()
                    result.success(null)
                }
                // The apps launched most recently, published as dynamic
                // shortcuts so a long press on 囤囤's icon starts them directly.
                "updateShortcuts" -> {
                    val items = call.argument<List<Map<String, Any?>>>("shortcuts")
                    result.success(publishShortcuts(items ?: emptyList()))
                }
                // The action of the shortcut that started this process, if any.
                "consumeShortcut" -> {
                    val id = pendingShortcut
                    pendingShortcut = null
                    result.success(id)
                }
                else -> p.onMethodCall(call, result)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingShortcut = shortcutFrom(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val id = shortcutFrom(intent) ?: return
        val sink = shortcutSink
        if (sink != null) sink(id) else pendingShortcut = id
    }

    /**
     * Publishes the most recently launched apps as dynamic shortcuts. Their
     * rank starts at 0, so a launcher that has to choose between these and the
     * static ones (res/xml/shortcuts.xml) lists the recent apps first — which
     * is the point of having them.
     */
    private fun publishShortcuts(items: List<Map<String, Any?>>): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return false
        val manager = getSystemService(ShortcutManager::class.java) ?: return false
        return runCatching {
            if (items.isEmpty()) {
                manager.removeAllDynamicShortcuts()
                return@runCatching true
            }
            // The platform caps how many dynamic shortcuts may be published.
            val limit = manager.maxShortcutCountPerActivity.coerceAtLeast(1)
            val infos = ArrayList<ShortcutInfo>()
            for ((index, item) in items.take(limit).withIndex()) {
                val pkg = item["packageName"] as? String ?: continue
                if (pkg.isEmpty()) continue
                val label = (item["label"] as? String).orEmpty().ifEmpty { pkg }
                val intent = Intent(this, MainActivity::class.java)
                    .setAction(shortcutAction)
                    .putExtra(shortcutExtra, "app:$pkg")
                val builder = ShortcutInfo.Builder(this, "recent-$index")
                    .setShortLabel(label.take(10))
                    .setLongLabel(label.take(25))
                    .setRank(index)
                    .setIntent(intent)
                appIcon(pkg)?.let { builder.setIcon(it) }
                infos.add(builder.build())
            }
            if (infos.isEmpty()) {
                manager.removeAllDynamicShortcuts()
            } else {
                // Some launchers allow fewer dynamic shortcuts than others; the
                // newest ones are the ones worth keeping.
                runCatching { manager.setDynamicShortcuts(infos) }
                    .onFailure { manager.setDynamicShortcuts(infos.take(2)) }
            }
            true
        }.getOrDefault(false)
    }

    /** The app's own launcher icon, drawn into the bitmap a shortcut needs. */
    private fun appIcon(packageName: String): Icon? = runCatching {
        val drawable = packageManager.getApplicationIcon(packageName)
        val size = (48 * resources.displayMetrics.density).toInt().coerceAtLeast(48)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(Canvas(bitmap))
        Icon.createWithBitmap(bitmap)
    }.getOrNull()

    /** The shortcut id carried by [intent], if it is one of ours. */
    private fun shortcutFrom(intent: Intent?): String? {
        val id = intent?.getStringExtra(shortcutExtra) ?: return null
        return id.takeIf { it.isNotEmpty() }
    }

    /**
     * Hide the status bar (revealed only transiently by a top swipe) or show it.
     *
     * Uses the window insets controller instead of Flutter's fullscreen flags so
     * the hidden state survives the notification shade: [onWindowFocusChanged]
     * re-applies it as soon as the window regains focus.
     */
    private fun applyStatusBarVisibility() {
        runCatching {
            val controller = WindowInsetsControllerCompat(window, window.decorView)
            if (statusBarHidden) {
                controller.systemBarsBehavior =
                    WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsetsCompat.Type.statusBars())
            } else {
                controller.show(WindowInsetsCompat.Type.statusBars())
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applyStatusBarVisibility()
    }

    override fun onPostResume() {
        super.onPostResume()
        applyStatusBarVisibility()
        attachDropListener()
    }

    /**
     * Best-effort OS drag-and-drop: files dragged onto the window (e.g. from a
     * split-screen file manager) are copied into the cache and forwarded to Dart
     * as an `apkDropped` call. Everything is wrapped so a device/ROM that does
     * not deliver drag events simply does nothing.
     */
    private fun attachDropListener() {
        runCatching {
            window.decorView.setOnDragListener { _, event ->
                when (event.action) {
                    DragEvent.ACTION_DRAG_STARTED -> true
                    DragEvent.ACTION_DRAG_ENTERED -> {
                        notify("apkDragEntered")
                        true
                    }
                    DragEvent.ACTION_DRAG_EXITED -> {
                        notify("apkDragEnded")
                        true
                    }
                    DragEvent.ACTION_DRAG_ENDED -> {
                        notify("apkDragEnded")
                        true
                    }
                    DragEvent.ACTION_DROP -> {
                        notify("apkDragEnded")
                        handleDrop(event)
                        true
                    }
                    else -> false
                }
            }
        }
    }

    private fun handleDrop(event: DragEvent) {
        val clip = event.clipData ?: return
        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
            val path = copyUriToCache(uri) ?: continue
            runCatching { channel?.invokeMethod("apkDropped", mapOf("path" to path)) }
            return
        }
    }

    private fun copyUriToCache(uri: Uri): String? = runCatching {
        val dir = File(cacheDir, "dropped").apply { mkdirs() }
        val name = queryDisplayName(uri) ?: "dropped.apk"
        val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val out = File(dir, "${System.currentTimeMillis()}_$safe")
        contentResolver.openInputStream(uri)?.use { input ->
            out.outputStream().use { output -> input.copyTo(output) }
        } ?: return@runCatching null
        out.absolutePath
    }.getOrNull()

    private fun queryDisplayName(uri: Uri): String? = runCatching {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
        }
    }.getOrNull()

    private fun notify(method: String) {
        runCatching { channel?.invokeMethod(method, null) }
    }

    override fun onDestroy() {
        plugin = null
        channel = null
        shortcutSink = null
        NotificationStore.sink = null
        NotificationStore.logSink = null
        super.onDestroy()
    }
}
