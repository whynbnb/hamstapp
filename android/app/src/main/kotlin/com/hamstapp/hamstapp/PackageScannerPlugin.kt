package com.hamstapp.hamstapp

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import jcifs.CIFSContext
import jcifs.config.PropertyConfiguration
import jcifs.context.BaseContext
import jcifs.smb.NtlmPasswordAuthenticator
import jcifs.smb.SmbException
import jcifs.smb.SmbFile
import org.apache.commons.net.ftp.FTPClient
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Properties
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Native bridge that scans installed packages on a background thread.
 *
 * Only lightweight metadata is returned in the bulk scan so that a device with
 * 1000+ installed packages finishes well within the 30s budget. Icons are
 * fetched lazily (only for rows that are actually rendered) and cached.
 */
class PackageScannerPlugin(
    private val context: Context,
    private val channel: MethodChannel
) : MethodChannel.MethodCallHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newFixedThreadPool(4)
    private val iconCache = ConcurrentHashMap<String, ByteArray>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInstalledApps" -> {
                val includeSystem = call.argument<Boolean>("includeSystem") ?: true
                executor.execute {
                    try {
                        val apps = scanApps(includeSystem)
                        mainHandler.post { result.success(apps) }
                    } catch (t: Throwable) {
                        mainHandler.post { result.error("SCAN_FAILED", t.message, null) }
                    }
                }
            }
            "getAppIcon" -> {
                val pkg = call.argument<String>("packageName")
                val size = call.argument<Int>("size") ?: 144
                if (pkg == null) {
                    result.error("BAD_ARGS", "packageName is required", null)
                    return
                }
                val cacheKey = "$pkg@$size"
                iconCache[cacheKey]?.let {
                    result.success(it)
                    return
                }
                executor.execute {
                    try {
                        val bytes = loadIcon(pkg, size)
                        if (bytes != null) iconCache[cacheKey] = bytes
                        mainHandler.post { result.success(bytes) }
                    } catch (t: Throwable) {
                        mainHandler.post { result.error("ICON_FAILED", t.message, null) }
                    }
                }
            }
            "launchApp" -> {
                val pkg = call.argument<String>("packageName")
                mainHandler.post { result.success(pkg != null && launchApp(pkg)) }
            }
            "openAppInfo" -> {
                val pkg = call.argument<String>("packageName")
                mainHandler.post { result.success(pkg != null && openAppInfo(pkg)) }
            }
            "uninstallApp" -> {
                val pkg = call.argument<String>("packageName")
                mainHandler.post { result.success(pkg != null && requestUninstall(pkg)) }
            }
            "vibrate" -> {
                val duration = call.argument<Int>("duration") ?: 30
                val amplitude = call.argument<Int>("amplitude") ?: -1
                mainHandler.post { result.success(vibrate(duration, amplitude)) }
            }
            "getDeviceInfo" -> {
                executor.execute {
                    val info = mapOf(
                        "model" to android.os.Build.MODEL,
                        "manufacturer" to android.os.Build.MANUFACTURER,
                        "androidVersion" to android.os.Build.VERSION.RELEASE,
                        "sdkInt" to android.os.Build.VERSION.SDK_INT
                    )
                    mainHandler.post { result.success(info) }
                }
            }
            "remoteTest" -> {
                val config = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                executor.execute {
                    try {
                        val list = listRemoteApks(config)
                        mainHandler.post {
                            result.success(mapOf("ok" to true, "count" to list.size))
                        }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.success(mapOf("ok" to false, "error" to describe(t)))
                        }
                    }
                }
            }
            "remoteList" -> {
                val config = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                executor.execute {
                    try {
                        val list = listRemoteApks(config)
                        mainHandler.post { result.success(list) }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error("REMOTE_FAILED", describe(t), null)
                        }
                    }
                }
            }
            "remoteDownload" -> {
                val config = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                executor.execute {
                    try {
                        val local = downloadRemoteFile(config)
                        mainHandler.post { result.success(local) }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error("DOWNLOAD_FAILED", describe(t), null)
                        }
                    }
                }
            }
            "apkInfo" -> {
                val path = call.argument<String>("path")
                executor.execute {
                    val info = runCatching { apkInfoMap(path) }.getOrNull()
                    mainHandler.post { result.success(info) }
                }
            }
            "cacheIndex" -> {
                val sourceId = call.argument<String>("sourceId") ?: "default"
                executor.execute {
                    val payload = runCatching { cacheIndexPayload(sourceId) }
                        .getOrElse { emptyMap<String, Any?>() }
                    mainHandler.post { result.success(payload) }
                }
            }
            "cachePrune" -> {
                val sourceId = call.argument<String>("sourceId") ?: "default"
                val entries = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                executor.execute {
                    val freed = runCatching { cachePrune(sourceId, entries) }.getOrDefault(0L)
                    mainHandler.post { result.success(freed) }
                }
            }
            "cacheDelete" -> {
                val sourceId = call.argument<String>("sourceId") ?: "default"
                val remotePath = call.argument<String>("remotePath") ?: ""
                executor.execute {
                    val freed = runCatching { cacheDelete(sourceId, remotePath) }
                        .getOrDefault(0L)
                    mainHandler.post { result.success(freed) }
                }
            }
            "cacheClear" -> executor.execute {
                val freed = runCatching { cacheClear() }.getOrDefault(0L)
                mainHandler.post { result.success(freed) }
            }
            "installApk" -> {
                val path = call.argument<String>("path")
                mainHandler.post { result.success(path != null && installApk(path)) }
            }
            "shareApk" -> {
                val path = call.argument<String>("path")
                val name = call.argument<String>("name") ?: ""
                executor.execute {
                    val ok = path != null &&
                        runCatching { shareApk(path, name) }.getOrDefault(false)
                    mainHandler.post { result.success(ok) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun scanApps(includeSystem: Boolean): List<Map<String, Any?>> {
        val pm = context.packageManager
        val packages: List<PackageInfo> = pm.getInstalledPackages(0)
        val out = ArrayList<Map<String, Any?>>(packages.size)
        for (info in packages) {
            val app = info.applicationInfo ?: continue
            val isSystem = (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (!includeSystem && isSystem) continue

            val label = runCatching { app.loadLabel(pm).toString() }.getOrDefault(info.packageName)
            val sourceDir = app.sourceDir
            val sizeBytes = if (sourceDir != null) File(sourceDir).length() else 0L

            out.add(
                mapOf(
                    "packageName" to info.packageName,
                    "appName" to label,
                    "versionName" to (info.versionName ?: ""),
                    "versionCode" to (if (android.os.Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()),
                    "firstInstallTime" to info.firstInstallTime,
                    "lastUpdateTime" to info.lastUpdateTime,
                    "isSystem" to isSystem,
                    "enabled" to app.enabled,
                    "apkPath" to (sourceDir ?: ""),
                    "sizeBytes" to sizeBytes,
                    "targetSdk" to app.targetSdkVersion,
                    "minSdk" to app.minSdkVersion,
                    "uid" to app.uid
                )
            )
        }
        return out
    }

    private fun loadIcon(packageName: String, sizePx: Int): ByteArray? {
        val pm = context.packageManager
        val drawable: Drawable = runCatching {
            pm.getApplicationIcon(packageName)
        }.getOrNull() ?: return null
        val bitmap = drawableToBitmap(drawable, sizePx)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        bitmap.recycle()
        return stream.toByteArray()
    }

    private fun drawableToBitmap(drawable: Drawable, sizePx: Int): Bitmap {
        val size = if (sizePx <= 0) 144 else sizePx
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            val src = drawable.bitmap
            if (src.width <= size && src.height <= size) return src
            return Bitmap.createScaledBitmap(src, size, size, true)
        }
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        return bitmap
    }

    private fun launchApp(packageName: String): Boolean {
        val intent = context.packageManager.getLaunchIntentForPackage(packageName) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return runCatching {
            context.startActivity(intent)
            true
        }.getOrDefault(false)
    }

    private fun openAppInfo(packageName: String): Boolean {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return runCatching {
            context.startActivity(intent)
            true
        }.getOrDefault(false)
    }

    private fun requestUninstall(packageName: String): Boolean {
        val intent = Intent(Intent.ACTION_DELETE).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return runCatching {
            context.startActivity(intent)
            true
        }.getOrDefault(false)
    }

    /**
     * Plays a one-shot vibration. [amplitude] is 1..255 (0/negative = device
     * default). Duration carries the strength when the device lacks amplitude
     * control, so the levels stay distinguishable on older hardware.
     */
    private fun vibrate(durationMs: Int, amplitude: Int): Boolean {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE)
                as? VibratorManager
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        } ?: return false
        if (!vibrator.hasVibrator()) return false
        val ms = durationMs.coerceIn(1, 1000).toLong()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val effect = if (amplitude > 0 && vibrator.hasAmplitudeControl()) {
                    VibrationEffect.createOneShot(
                        ms,
                        amplitude.coerceIn(1, 255)
                    )
                } else {
                    VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE)
                }
                vibrator.vibrate(effect)
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(ms)
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    // ---------------------------------------------------------------- remote

    private fun strArg(m: Map<*, *>, key: String, def: String = ""): String {
        val v = m[key]
        return if (v is String && v.isNotEmpty()) v else def
    }

    private fun intArg(m: Map<*, *>, key: String, def: Int): Int {
        val v = m[key]
        return if (v is Number) v.toInt() else def
    }

    private fun boolArg(m: Map<*, *>, key: String): Boolean =
        m[key] as? Boolean ?: false

    /**
     * Full cause chain plus any SMB NT status, joined with " | ".
     *
     * jcifs wraps the useful details: the outer message is often a generic
     * "Session setup failed" while the real NT status (LOGON_FAILURE, bad
     * password, ...) lives on a nested SmbException. Surfacing it makes the
     * error actionable.
     */
    private fun describe(t: Throwable): String {
        val parts = ArrayList<String>()
        var cur: Throwable? = t
        val seen = HashSet<Throwable>()
        while (cur != null && seen.add(cur)) {
            val m = cur.message
            if (!m.isNullOrBlank() && !parts.contains(m)) parts.add(m)
            if (cur is SmbException) {
                val code = runCatching { cur.ntStatus }.getOrDefault(0)
                if (code != 0) {
                    val hex = "0x" + Integer.toHexString(code).uppercase()
                    val hint = ntStatusHint(code)
                    val extra = if (hint.isEmpty()) hex else "$hex $hint"
                    if (!parts.contains(extra)) parts.add(extra)
                }
            }
            cur = cur.cause?.takeIf { it !== cur }
        }
        return if (parts.isEmpty()) t.javaClass.simpleName else parts.joinToString(" | ")
    }

    /** Friendly text for the SMB NT status codes users hit most often. */
    private fun ntStatusHint(code: Int): String =
        when (code.toLong() and 0xFFFFFFFFL) {
            0xC000006DL -> "账号或密码错误"
            0xC000006AL -> "密码错误"
            0xC0000064L -> "用户名不存在"
            0xC000006EL -> "账户限制"
            0xC000006FL, 0xC0000070L, 0xC0000072L -> "账户被禁用或锁定"
            0xC000015BL -> "登录类型不被允许"
            0xC0000071L -> "密码已过期"
            else -> ""
        }

    /** How many directory levels deep the APK scan will descend. */
    private val maxScanDepth = 6

    /**
     * Real APK files only: skip hidden/dot entries (`.thumbnails`, macOS `._`
     * resource forks, ...) and anything that is not an `.apk`.
     */
    private fun isApkName(name: String): Boolean =
        !name.startsWith(".") && name.lowercase().endsWith(".apk")

    private fun apkEntry(
        name: String,
        rel: String,
        path: String,
        size: Long,
        modified: Long
    ): Map<String, Any?> = mapOf(
        "name" to name,
        "rel" to rel,
        "path" to path,
        "size" to size,
        "modified" to modified
    )

    /** Lists `.apk` files from an FTP or SMB (Samba) source, recursively. */
    private fun listRemoteApks(config: Map<*, *>): List<Map<String, Any?>> {
        val protocol = strArg(config, "protocol", "ftp").lowercase()
        return if (protocol == "smb" || protocol == "samba") {
            listSmb(config)
        } else {
            listFtp(config)
        }
    }

    private fun listFtp(config: Map<*, *>): List<Map<String, Any?>> {
        val host = strArg(config, "host")
        require(host.isNotEmpty()) { "主机不能为空" }
        val port = intArg(config, "port", 21).let { if (it <= 0) 21 else it }
        val anonymous = boolArg(config, "anonymous")
        val user = if (anonymous) "anonymous" else strArg(config, "username")
        val pass = if (anonymous) "anonymous@" else strArg(config, "password")
        val dirInput = strArg(config, "path", "/").ifEmpty { "/" }
        val root = if (dirInput.endsWith("/")) dirInput else "$dirInput/"

        val ftp = FTPClient()
        ftp.connectTimeout = 10000
        ftp.defaultTimeout = 20000
        try {
            ftp.connect(host, port)
            if (!ftp.login(user, pass)) {
                throw IllegalStateException("FTP 登录失败，请检查账号或匿名设置")
            }
            ftp.enterLocalPassiveMode()
            ftp.setFileType(FTPClient.BINARY_FILE_TYPE)
            val out = ArrayList<Map<String, Any?>>()
            val visited = HashSet<String>()
            fun walk(current: String, rel: String, depth: Int) {
                if (depth > maxScanDepth || !visited.add(current)) return
                val files = runCatching { ftp.listFiles(current) }.getOrNull() ?: return
                for (f in files) {
                    if (f == null) continue
                    val name = f.name ?: continue
                    if (name == "." || name == ".." || name.startsWith(".")) continue
                    val full = current + name
                    val childRel = if (rel.isEmpty()) name else "$rel/$name"
                    if (f.isDirectory) {
                        walk("$full/", childRel, depth + 1)
                    } else if (name.lowercase().endsWith(".apk")) {
                        out.add(
                            apkEntry(
                                name, childRel, full, f.size,
                                f.timestamp?.timeInMillis ?: 0L
                            )
                        )
                    }
                }
            }
            walk(root, "", 0)
            out.sortBy { it["rel"] as String }
            return out
        } finally {
            runCatching { ftp.logout() }
            runCatching { ftp.disconnect() }
        }
    }

    /**
     * Builds a jcifs context (with timeouts/protocol/dialect tuned for NAS).
     * Returns the base context (to close) and the credential-bound context.
     */
    private fun buildSmbContext(config: Map<*, *>): Pair<BaseContext, CIFSContext> {
        val port = intArg(config, "port", 445).let { if (it <= 0) 445 else it }
        val anonymous = boolArg(config, "anonymous")
        val user = strArg(config, "username")
        val pass = strArg(config, "password")
        val domain = strArg(config, "domain")

        val props = Properties()
        // Resolve hostnames with DNS only: WINS/NetBIOS broadcast lookups are
        // what usually makes SMB "hang" then fail on Android.
        props.setProperty("jcifs.resolveOrder", "DNS")
        // Support old SMB1-only NAS through SMB 3.1.1.
        props.setProperty("jcifs.smb.client.minVersion", "SMB1")
        props.setProperty("jcifs.smb.client.maxVersion", "SMB311")
        // Bound the connection so a wrong host/port fails fast instead of hanging.
        props.setProperty("jcifs.smb.client.connTimeout", "15000")
        props.setProperty("jcifs.smb.client.responseTimeout", "30000")
        props.setProperty("jcifs.smb.client.soTimeout", "35000")
        props.setProperty("jcifs.smb.client.dfs.disabled", "true")
        // NTLMv2 only, matching what modern Samba/Windows/NAS expect.
        props.setProperty("jcifs.smb.lmCompatibility", "3")
        props.setProperty("jcifs.smb.client.useUnicode", "true")
        // Bigger socket buffers for faster bulk transfers.
        props.setProperty("jcifs.smb.client.rcv_buf_size", (1 shl 18).toString())
        props.setProperty("jcifs.smb.client.snd_buf_size", (1 shl 18).toString())
        if (port != 445) props.setProperty("jcifs.smb.client.port", port.toString())

        val base = BaseContext(PropertyConfiguration(props))
        val ctx = if (anonymous) {
            base.withAnonymousCredentials()
        } else {
            // A blank domain is fine for Samba local users; Windows local
            // accounts / domains need it ("WORKGROUP", "NAS\user", ...).
            base.withCredentials(NtlmPasswordAuthenticator(domain, user, pass))
        }
        return base to ctx
    }

    private fun listSmb(config: Map<*, *>): List<Map<String, Any?>> {
        val host = strArg(config, "host")
        require(host.isNotEmpty()) { "主机不能为空" }
        val port = intArg(config, "port", 445).let { if (it <= 0) 445 else it }
        val path = strArg(config, "path").trim('/')
        require(path.isNotEmpty()) { "请填写共享路径，例如 share/apks" }
        val portPart = if (port != 445) ":$port" else ""

        val (base, ctx) = buildSmbContext(config)
        try {
            val root = SmbFile("smb://$host$portPart/$path/", ctx)
            val out = ArrayList<Map<String, Any?>>()
            fun walk(dir: SmbFile, rel: String, depth: Int) {
                if (depth > maxScanDepth) return
                val children = dir.listFiles() ?: return
                for (c in children) {
                    if (c == null) continue
                    val name = c.name?.trimEnd('/') ?: continue
                    if (name.isEmpty() || name == "." || name == ".." ||
                        name.startsWith(".")
                    ) {
                        continue
                    }
                    val childRel = if (rel.isEmpty()) name else "$rel/$name"
                    if (c.isDirectory) {
                        walk(c, childRel, depth + 1)
                    } else if (name.lowercase().endsWith(".apk")) {
                        out.add(
                            apkEntry(
                                name, childRel, "$path/$childRel",
                                c.length(), c.lastModified()
                            )
                        )
                    }
                }
            }
            walk(root, "", 0)
            out.sortBy { it["rel"] as String }
            return out
        } finally {
            runCatching { base.close() }
        }
    }

    // ------------------------------------------------------------ download/cache

    private fun longArg(m: Map<*, *>, key: String, def: Long): Long {
        val v = m[key]
        return if (v is Number) v.toLong() else def
    }

    private fun cacheDir(): File {
        val dir = File(context.filesDir, "apk_cache")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    private fun cacheIndexFile(): File = File(cacheDir(), "index.json")

    private fun loadCache(): JSONObject {
        val f = cacheIndexFile()
        if (!f.exists()) return JSONObject()
        return runCatching { JSONObject(f.readText()) }.getOrDefault(JSONObject())
    }

    private fun saveCache(obj: JSONObject) {
        runCatching { cacheIndexFile().writeText(obj.toString()) }
    }

    private fun cacheKey(sourceId: String, remotePath: String) = "$sourceId::$remotePath"

    private fun safeName(name: String): String {
        val s = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return s.ifEmpty { "download.apk" }
    }

    /**
     * Downloads one remote file (or reuses a matching cached copy), parses its
     * APK metadata and records it in the persistent cache index.
     */
    private fun downloadRemoteFile(config: Map<*, *>): String {
        val sourceId = strArg(config, "sourceId", "default")
        val remotePath = strArg(config, "remotePath")
        require(remotePath.isNotEmpty()) { "缺少远程文件路径" }
        val protocol = strArg(config, "protocol", "ftp").lowercase()
        val name = strArg(config, "name").ifEmpty { remotePath.substringAfterLast('/') }
        val rel = strArg(config, "rel", name)
        val remoteSize = longArg(config, "size", -1L)
        val remoteModified = longArg(config, "modified", 0L)
        val force = boolArg(config, "force")
        val key = cacheKey(sourceId, remotePath)

        val cache = loadCache()
        val existing = cache.optJSONObject(key)
        if (existing != null) {
            val local = File(cacheDir(), existing.optString("file"))
            val cachedSize = existing.optLong("size", -1L)
            val cachedModified = existing.optLong("modified", 0L)
            // Size alone misses replacements of the same length, so also compare
            // the remote mtime when both sides know it.
            val sizeSame = remoteSize < 0 || cachedSize == remoteSize
            val modifiedSame = remoteModified <= 0 ||
                cachedModified <= 0 ||
                cachedModified == remoteModified
            if (!force && local.exists() && sizeSame && modifiedSame) {
                return local.absolutePath
            }
            // Remote changed (or a refresh was forced): drop the stale copy.
            local.delete()
            val oldIcon = existing.optString("icon")
            if (oldIcon.isNotEmpty()) runCatching { File(cacheDir(), oldIcon).delete() }
            cache.remove(key)
        }

        val fileName = "${Integer.toHexString(key.hashCode())}_${safeName(name)}"
        val target = File(cacheDir(), fileName)
        val downloadId = strArg(config, "downloadId")
        val onProgress: (Long, Long) -> Unit = { received, total ->
            reportProgress(downloadId, received, total)
        }
        when {
            protocol == "smb" || protocol == "samba" ->
                downloadSmb(config, remotePath, target, remoteSize, onProgress)
            protocol == "webdav" ->
                downloadWebdav(config, remotePath, target, remoteSize, onProgress)
            else ->
                downloadFtp(config, remotePath, target, remoteSize, onProgress)
        }

        val info = runCatching { apkInfoMap(target.absolutePath) }.getOrNull()
        var iconName = ""
        (info?.get("icon") as? ByteArray)?.let { bytes ->
            iconName = "$fileName.png"
            runCatching { File(cacheDir(), iconName).writeBytes(bytes) }
        }
        val entry = JSONObject().apply {
            put("file", fileName)
            put("path", remotePath)
            put("rel", rel)
            put("name", name)
            put("size", target.length())
            put("modified", remoteModified)
            put("icon", iconName)
            if (info != null) {
                put("packageName", info["packageName"] ?: "")
                put("appName", info["appName"] ?: "")
                put("versionName", info["versionName"] ?: "")
                put("versionCode", info["versionCode"] ?: 0)
                put("minSdk", info["minSdk"] ?: 0)
                put("targetSdk", info["targetSdk"] ?: 0)
            }
        }
        cache.put(key, entry)
        saveCache(cache)
        return target.absolutePath
    }

    private fun reportProgress(id: String, received: Long, total: Long) {
        if (id.isEmpty()) return
        mainHandler.post {
            runCatching {
                channel.invokeMethod(
                    "downloadProgress",
                    mapOf("id" to id, "received" to received, "total" to total)
                )
            }
        }
    }

    /** 64KB buffered copy that reports progress every ~256KB. */
    private fun copyWithProgress(
        input: InputStream,
        output: OutputStream,
        total: Long,
        onProgress: (Long, Long) -> Unit
    ) {
        val buffer = ByteArray(1 shl 16)
        var received = 0L
        var lastReport = 0L
        val bufferedIn = if (input is BufferedInputStream) input else BufferedInputStream(input, 1 shl 16)
        val bufferedOut = if (output is BufferedOutputStream) output else BufferedOutputStream(output, 1 shl 16)
        try {
            while (true) {
                val n = bufferedIn.read(buffer)
                if (n < 0) break
                bufferedOut.write(buffer, 0, n)
                received += n
                if (received - lastReport >= (1 shl 18)) {
                    lastReport = received
                    onProgress(received, total)
                }
            }
            bufferedOut.flush()
        } finally {
            runCatching { bufferedIn.close() }
            runCatching { bufferedOut.close() }
        }
        onProgress(received, total)
    }

    private fun downloadFtp(
        config: Map<*, *>,
        remotePath: String,
        target: File,
        total: Long,
        onProgress: (Long, Long) -> Unit
    ) {
        val host = strArg(config, "host")
        val port = intArg(config, "port", 21).let { if (it <= 0) 21 else it }
        val anonymous = boolArg(config, "anonymous")
        val user = if (anonymous) "anonymous" else strArg(config, "username")
        val pass = if (anonymous) "anonymous@" else strArg(config, "password")

        val ftp = FTPClient()
        ftp.connectTimeout = 10000
        ftp.defaultTimeout = 20000
        ftp.bufferSize = 1 shl 16
        try {
            ftp.connect(host, port)
            if (!ftp.login(user, pass)) throw IllegalStateException("FTP 登录失败")
            ftp.enterLocalPassiveMode()
            ftp.setFileType(FTPClient.BINARY_FILE_TYPE)
            val input = ftp.retrieveFileStream(remotePath)
                ?: throw IllegalStateException("无法读取远程文件：$remotePath")
            copyWithProgress(input, target.outputStream(), total, onProgress)
            if (!ftp.completePendingCommand()) {
                throw IllegalStateException("下载未完成：$remotePath")
            }
        } finally {
            runCatching { ftp.logout() }
            runCatching { ftp.disconnect() }
        }
    }

    private fun downloadSmb(
        config: Map<*, *>,
        remotePath: String,
        target: File,
        total: Long,
        onProgress: (Long, Long) -> Unit
    ) {
        val host = strArg(config, "host")
        val port = intArg(config, "port", 445).let { if (it <= 0) 445 else it }
        val portPart = if (port != 445) ":$port" else ""
        val (base, ctx) = buildSmbContext(config)
        try {
            val remote = SmbFile("smb://$host$portPart/$remotePath", ctx)
            val size = if (total >= 0) total else runCatching { remote.length() }.getOrDefault(-1L)
            copyWithProgress(remote.openInputStream(), target.outputStream(), size, onProgress)
        } finally {
            runCatching { base.close() }
        }
    }

    private fun downloadWebdav(
        config: Map<*, *>,
        remotePath: String,
        target: File,
        total: Long,
        onProgress: (Long, Long) -> Unit
    ) {
        val secure = boolArg(config, "secure")
        val host = strArg(config, "host")
        val port = intArg(config, "port", if (secure) 443 else 80)
        val scheme = if (secure) "https" else "http"
        val path = if (remotePath.startsWith("/")) remotePath else "/$remotePath"
        val url = URL("$scheme://$host:$port$path")
        val conn = openConnection(url)
        try {
            conn.requestMethod = "GET"
            conn.connectTimeout = 15000
            conn.readTimeout = 30000
            conn.instanceFollowRedirects = true
            if (!boolArg(config, "anonymous")) {
                val user = strArg(config, "username")
                val pass = strArg(config, "password")
                if (user.isNotEmpty()) {
                    val token = Base64.encodeToString(
                        "$user:$pass".toByteArray(Charsets.UTF_8),
                        Base64.NO_WRAP
                    )
                    conn.setRequestProperty("Authorization", "Basic $token")
                }
            }
            val code = conn.responseCode
            if (code >= 400) throw IllegalStateException("HTTP $code 下载失败：$path")
            val size = if (total >= 0) total else conn.contentLengthLong
            copyWithProgress(conn.inputStream, target.outputStream(), size, onProgress)
        } finally {
            runCatching { conn.disconnect() }
        }
    }

    /** Opens an HTTP(S) connection; HTTPS skips certificate checks (LAN NAS). */
    private fun openConnection(url: URL): HttpURLConnection {
        val conn = url.openConnection() as HttpURLConnection
        if (conn is HttpsURLConnection) {
            val trustAll = arrayOf<TrustManager>(object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {}
                override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
            })
            val ctx = SSLContext.getInstance("TLS")
            ctx.init(null, trustAll, SecureRandom())
            conn.sslSocketFactory = ctx.socketFactory
            conn.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, _ -> true }
        }
        return conn
    }

    // ------------------------------------------------------------ apk metadata

    /** Parses an APK's manifest (name/package/version/sdk + icon). */
    private fun apkInfoMap(path: String?): Map<String, Any?>? {
        if (path.isNullOrEmpty()) return null
        val file = File(path)
        if (!file.exists()) return null
        val pm = context.packageManager
        val flags = PackageManager.GET_META_DATA
        val info: PackageInfo = if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(path, flags)
        } ?: return null
        val app = info.applicationInfo ?: return null
        app.sourceDir = path
        app.publicSourceDir = path
        val label = runCatching { app.loadLabel(pm).toString() }.getOrDefault("")
        val versionCode = if (Build.VERSION.SDK_INT >= 28) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        val icon = runCatching {
            val drawable = app.loadIcon(pm)
            val bmp = drawableToBitmap(drawable, 144)
            val stream = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, stream)
            bmp.recycle()
            stream.toByteArray()
        }.getOrNull()
        return mapOf(
            "packageName" to info.packageName,
            "appName" to label,
            "versionName" to (info.versionName ?: ""),
            "versionCode" to versionCode,
            "minSdk" to app.minSdkVersion,
            "targetSdk" to app.targetSdkVersion,
            "size" to file.length(),
            "icon" to icon
        )
    }

    // ------------------------------------------------------------ cache index

    /** `{entries: [...], totalBytes: n}` for one source. */
    private fun cacheIndexPayload(sourceId: String): Map<String, Any?> {
        val cache = loadCache()
        val entries = ArrayList<Map<String, Any?>>()
        var total = 0L
        val prefix = "$sourceId::"
        val keys = cache.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (!key.startsWith(prefix)) continue
            val obj = cache.optJSONObject(key) ?: continue
            val file = File(cacheDir(), obj.optString("file"))
            if (!file.exists()) continue
            total += file.length()
            val iconFile = File(cacheDir(), obj.optString("icon"))
            entries.add(
                mapOf(
                    "path" to obj.optString("path"),
                    "rel" to obj.optString("rel"),
                    "name" to obj.optString("name"),
                    "localPath" to file.absolutePath,
                    "iconPath" to if (iconFile.exists()) iconFile.absolutePath else "",
                    "size" to file.length(),
                    "modified" to obj.optLong("modified", 0L),
                    "packageName" to obj.optString("packageName"),
                    "appName" to obj.optString("appName"),
                    "versionName" to obj.optString("versionName"),
                    "versionCode" to obj.optLong("versionCode", 0L),
                    "minSdk" to obj.optInt("minSdk", 0),
                    "targetSdk" to obj.optInt("targetSdk", 0)
                )
            )
        }
        return mapOf("entries" to entries, "totalBytes" to total)
    }

    /**
     * Deletes cached APKs whose remote file changed (size differs) or no longer
     * exists, so the next install re-downloads them. Returns freed bytes.
     */
    private fun cachePrune(sourceId: String, payload: Map<*, *>): Long {
        val list = payload["entries"] as? List<*> ?: return 0L
        val remotes = HashMap<String, Pair<Long, Long>>()
        for (item in list) {
            val m = item as? Map<*, *> ?: continue
            val p = (m["path"] as? String) ?: continue
            remotes[p] = longArg(m, "size", -1L) to longArg(m, "modified", 0L)
        }
        val cache = loadCache()
        var freed = 0L
        val prefix = "$sourceId::"
        val keys = cache.keys().asSequence().toList()
        for (key in keys) {
            if (!key.startsWith(prefix)) continue
            val remotePath = key.substring(prefix.length)
            val obj = cache.optJSONObject(key) ?: continue
            val remote = remotes[remotePath]
            val remoteSize = remote?.first ?: -2L
            val remoteModified = remote?.second ?: 0L
            val cachedSize = obj.optLong("size", -1L)
            val cachedModified = obj.optLong("modified", 0L)
            val fresh = remote != null &&
                (remoteSize < 0 || cachedSize == remoteSize) &&
                (remoteModified <= 0 || cachedModified <= 0 ||
                    cachedModified == remoteModified)
            if (fresh) continue
            val file = File(cacheDir(), obj.optString("file"))
            if (file.exists() && file.delete()) freed += obj.optLong("size", 0L)
            val icon = obj.optString("icon")
            if (icon.isNotEmpty()) runCatching { File(cacheDir(), icon).delete() }
            cache.remove(key)
        }
        saveCache(cache)
        return freed
    }

    /** Deletes a single cached APK (by source + remote path). Returns freed bytes. */
    private fun cacheDelete(sourceId: String, remotePath: String): Long {
        if (remotePath.isEmpty()) return 0L
        val cache = loadCache()
        val key = cacheKey(sourceId, remotePath)
        var freed = 0L
        cache.optJSONObject(key)?.let { obj ->
            val file = File(cacheDir(), obj.optString("file"))
            if (file.exists() && file.delete()) freed += obj.optLong("size", 0L)
            val icon = obj.optString("icon")
            if (icon.isNotEmpty()) runCatching { File(cacheDir(), icon).delete() }
        }
        cache.remove(key)
        saveCache(cache)
        return freed
    }

    private fun cacheClear(): Long {
        var freed = 0L
        val dir = cacheDir()
        dir.listFiles()?.forEach { f ->
            if (f.name == "index.json") return@forEach
            freed += f.length()
            f.delete()
        }
        runCatching { cacheIndexFile().delete() }
        return freed
    }

    /** Opens the system package installer for a downloaded APK (FileProvider). */
    private fun installApk(path: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        return try {
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            true
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * Copies an installed APK into the app's private cache and hands it to the
     * system share sheet. The installed APK lives under /data/app, which is
     * outside the FileProvider roots, so it has to be copied first.
     */
    private fun shareApk(sourcePath: String, displayName: String): Boolean {
        val src = File(sourcePath)
        if (!src.exists() || !src.isFile) return false
        return try {
            val dir = File(context.cacheDir, "share")
            dir.listFiles()?.forEach { it.delete() }
            dir.mkdirs()
            val base = displayName.ifBlank { src.nameWithoutExtension }
                .replace(Regex("[^A-Za-z0-9._\u4e00-\u9fff-]"), "_")
                .take(80)
            val dest = File(dir, "$base.apk")
            src.inputStream().use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                dest
            )
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "application/vnd.android.package-archive"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, displayName)
                clipData = ClipData.newUri(context.contentResolver, "apk", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val chooser = Intent.createChooser(send, null).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(chooser)
            true
        } catch (t: Throwable) {
            false
        }
    }
}
