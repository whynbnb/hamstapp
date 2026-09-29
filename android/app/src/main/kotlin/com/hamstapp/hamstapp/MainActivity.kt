package com.hamstapp.hamstapp

import android.net.Uri
import android.provider.OpenableColumns
import android.view.DragEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val channelName = "hamstapp/apps"
    private var plugin: PackageScannerPlugin? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        plugin = PackageScannerPlugin(applicationContext, ch)
        ch.setMethodCallHandler(plugin)
    }

    override fun onPostResume() {
        super.onPostResume()
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
        super.onDestroy()
    }
}
