package me.whynbnb.hamstapp

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.content.pm.SigningInfo
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
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Locale
import java.util.Properties
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.zip.ZipFile
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
            "analyzeApk" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "path is required", null)
                    return
                }
                executor.execute {
                    try {
                        val info = analyzeApk(path)
                        mainHandler.post { result.success(info) }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error("ANALYZE_FAILED", describe(t), null)
                        }
                    }
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
            "cacheIndexAll" -> executor.execute {
                val payload = runCatching { cacheIndexAllPayload() }
                    .getOrElse { emptyMap<String, Any?>() }
                mainHandler.post { result.success(payload) }
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
            "cacheDeleteById" -> {
                val id = call.argument<String>("id") ?: ""
                executor.execute {
                    val freed = runCatching { cacheDeleteById(id) }
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
            "canInstallPackages" -> {
                mainHandler.post { result.success(canInstallPackages()) }
            }
            "openInstallPermissionSettings" -> {
                mainHandler.post { result.success(openInstallPermissionSettings()) }
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

    /** Marker appended to a cache key when an old copy is kept as history. */
    private val histMark = "#h:"

    private fun isHistoricalKey(key: String) = key.contains(histMark)

    /**
     * Re-keys [obj] under a unique historical key so an outdated cached copy is
     * kept instead of deleted (used when the source keeps all versions). The
     * file itself is left in place.
     */
    private fun archiveEntry(cache: JSONObject, key: String, obj: JSONObject) {
        if (isHistoricalKey(key)) return
        val base = "$key$histMark${obj.optLong("modified", 0L)}"
        var histKey = base
        var seq = 0
        while (cache.has(histKey)) {
            seq++
            histKey = "$base:$seq"
        }
        obj.put("historical", true)
        cache.put(histKey, obj)
        cache.remove(key)
    }

    private fun deleteCacheEntry(cache: JSONObject, key: String): Long {
        val obj = cache.optJSONObject(key) ?: return 0L
        var freed = 0L
        val file = File(cacheDir(), obj.optString("file"))
        if (file.exists() && file.delete()) freed += obj.optLong("size", 0L)
        val icon = obj.optString("icon")
        if (icon.isNotEmpty()) runCatching { File(cacheDir(), icon).delete() }
        cache.remove(key)
        return freed
    }

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
        val keepAll = boolArg(config, "keepAllVersions")
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
            // Remote changed (or a refresh was forced): drop the stale copy, or
            // keep it as history when the source keeps all versions.
            if (keepAll && local.exists()) {
                archiveEntry(cache, key, existing)
            } else {
                local.delete()
                val oldIcon = existing.optString("icon")
                if (oldIcon.isNotEmpty()) runCatching { File(cacheDir(), oldIcon).delete() }
                cache.remove(key)
            }
        }

        val fileName =
            "${Integer.toHexString(key.hashCode())}_${remoteModified}_${remoteSize}_${safeName(name)}"
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

    // ------------------------------------------------------------ apk analysis

    /**
     * Deep, self-contained analysis of an APK *file* (no install required).
     *
     * Combines three independent sources so the result is trustworthy:
     *  1. the parsed AndroidManifest (via PackageManager.getPackageArchiveInfo),
     *  2. the signing certificates (v1/v2/v3, cert details + fingerprints),
     *  3. the raw zip structure (DEX files, native ABIs, resources.arsc, ...),
     * plus whole-file hashes and a comparison against the installed app.
     */
    private fun analyzeApk(path: String): Map<String, Any?> {
        val file = File(path)
        if (!file.exists() || !file.isFile) {
            throw IllegalArgumentException("文件不存在")
        }
        val size = file.length()
        val fileSha256 = fileDigest(file, "SHA-256")
        val fileMd5 = fileDigest(file, "MD5")

        val pm = context.packageManager
        var flags = PackageManager.GET_META_DATA or
            PackageManager.GET_ACTIVITIES or
            PackageManager.GET_SERVICES or
            PackageManager.GET_RECEIVERS or
            PackageManager.GET_PROVIDERS or
            PackageManager.GET_PERMISSIONS or
            PackageManager.GET_SIGNATURES
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            flags = flags or PackageManager.GET_SIGNING_CERTIFICATES
        }
        val info: PackageInfo = if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageArchiveInfo(
                path,
                PackageManager.PackageInfoFlags.of(flags.toLong())
            )
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(path, flags)
        } ?: throw IllegalArgumentException("无法解析 APK（可能不是有效的安装包）")
        val app = info.applicationInfo
        app?.sourceDir = path
        app?.publicSourceDir = path

        val label = runCatching { app?.loadLabel(pm)?.toString() }.getOrNull() ?: ""
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        val icon = runCatching {
            val drawable = app?.loadIcon(pm) ?: return@runCatching null
            val bmp = drawableToBitmap(drawable, 192)
            val stream = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, stream)
            bmp.recycle()
            stream.toByteArray()
        }.getOrNull()

        val permissions = (info.requestedPermissions ?: emptyArray<String>()).toList()
        val features = (info.reqFeatures ?: emptyArray())
            .mapNotNull { it.name }
        val activityCount = info.activities?.size ?: 0
        val serviceCount = info.services?.size ?: 0
        val receiverCount = info.receivers?.size ?: 0
        val providerCount = info.providers?.size ?: 0

        val appFlags = app?.flags ?: 0
        val debuggable = (appFlags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val allowBackup = (appFlags and ApplicationInfo.FLAG_ALLOW_BACKUP) != 0
        val testOnly = (appFlags and ApplicationInfo.FLAG_TEST_ONLY) != 0
        val cleartext = (appFlags and ApplicationInfo.FLAG_USES_CLEARTEXT_TRAFFIC) != 0
        val extractNative =
            (appFlags and ApplicationInfo.FLAG_EXTRACT_NATIVE_LIBS) != 0

        val signers = ArrayList<Map<String, Any?>>()
        var hasMultipleSigners = false
        var hasPastSigningCerts = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val si: SigningInfo? = info.signingInfo
            if (si != null) {
                hasMultipleSigners = si.hasMultipleSigners()
                hasPastSigningCerts = si.hasPastSigningCertificates()
                val sigs = if (hasMultipleSigners) {
                    si.apkContentsSigners
                } else {
                    si.signingCertificateHistory
                }
                sigs?.forEach { signers.add(certInfo(it)) }
            }
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.forEach { signers.add(certInfo(it)) }
        }

        var entryCount = 0
        var uncompressed = 0L
        var compressed = 0L
        var dexCount = 0
        var dexBytes = 0L
        var nativeLibCount = 0
        val abis = sortedSetOf<String>()
        var hasArsc = false
        var hasManifest = false
        var hasV1Signature = false
        runCatching {
            ZipFile(file).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    entryCount++
                    uncompressed += entry.size.coerceAtLeast(0L)
                    compressed += entry.compressedSize.coerceAtLeast(0L)
                    if (entry.isDirectory) continue
                    val name = entry.name
                    val lower = name.lowercase(Locale.US)
                    when {
                        DEX_NAME.matches(lower) -> {
                            dexCount++
                            dexBytes += entry.size.coerceAtLeast(0L)
                        }
                        name.startsWith("lib/") -> {
                            val abi = name.substringAfter("lib/").substringBefore('/')
                            if (abi.isNotEmpty()) {
                                abis.add(abi)
                                nativeLibCount++
                            }
                        }
                        lower == "resources.arsc" -> hasArsc = true
                        name == "AndroidManifest.xml" -> hasManifest = true
                        lower.startsWith("meta-inf/") &&
                            (lower.endsWith(".rsa") ||
                                lower.endsWith(".dsa") ||
                                lower.endsWith(".ec")) -> hasV1Signature = true
                    }
                }
            }
        }

        // Compare with the currently installed app of the same package.
        var installed = false
        var installedVersionCode = -1L
        var installedVersionName = ""
        var sameSigner = false
        runCatching {
            val ip: PackageInfo = when {
                Build.VERSION.SDK_INT >= 33 -> pm.getPackageInfo(
                    info.packageName,
                    PackageManager.PackageInfoFlags.of(
                        PackageManager.GET_SIGNING_CERTIFICATES.toLong()
                    )
                )
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ->
                    pm.getPackageInfo(
                        info.packageName,
                        PackageManager.GET_SIGNING_CERTIFICATES
                    )
                else -> {
                    @Suppress("DEPRECATION")
                    pm.getPackageInfo(info.packageName, PackageManager.GET_SIGNATURES)
                }
            }
            installed = true
            installedVersionCode =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    ip.longVersionCode
                } else {
                    @Suppress("DEPRECATION")
                    ip.versionCode.toLong()
                }
            installedVersionName = ip.versionName ?: ""
            val installedSigs = ArrayList<String>()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val isi = ip.signingInfo
                val arr = if (isi != null && isi.hasMultipleSigners()) {
                    isi.apkContentsSigners
                } else {
                    isi?.signingCertificateHistory
                }
                arr?.forEach {
                    installedSigs.add(certInfo(it)["sha256"] as? String ?: "")
                }
            } else {
                @Suppress("DEPRECATION")
                ip.signatures?.forEach {
                    installedSigs.add(certInfo(it)["sha256"] as? String ?: "")
                }
            }
            val apkSigs = signers.mapNotNull { it["sha256"] as? String }
            sameSigner =
                installedSigs.isNotEmpty() && apkSigs.containsAll(installedSigs)
        }

        return mapOf(
            "path" to path,
            "fileName" to file.name,
            "size" to size,
            "modified" to file.lastModified(),
            "sha256" to fileSha256,
            "md5" to fileMd5,
            "packageName" to info.packageName,
            "appName" to label,
            "versionName" to (info.versionName ?: ""),
            "versionCode" to versionCode,
            "minSdk" to (app?.minSdkVersion ?: 0),
            "targetSdk" to (app?.targetSdkVersion ?: 0),
            "debuggable" to debuggable,
            "allowBackup" to allowBackup,
            "testOnly" to testOnly,
            "usesCleartextTraffic" to cleartext,
            "extractNativeLibs" to extractNative,
            "permissions" to permissions,
            "features" to features,
            "activityCount" to activityCount,
            "serviceCount" to serviceCount,
            "receiverCount" to receiverCount,
            "providerCount" to providerCount,
            "abis" to abis.toList(),
            "nativeLibCount" to nativeLibCount,
            "dexCount" to dexCount,
            "dexBytes" to dexBytes,
            "apkEntryCount" to entryCount,
            "apkUncompressedBytes" to uncompressed,
            "apkCompressedBytes" to compressed,
            "hasResourcesArsc" to hasArsc,
            "hasManifest" to hasManifest,
            "hasV1Signature" to hasV1Signature,
            "hasMultipleSigners" to hasMultipleSigners,
            "hasPastSigningCertificates" to hasPastSigningCerts,
            "signers" to signers,
            "installed" to installed,
            "installedVersionCode" to installedVersionCode,
            "installedVersionName" to installedVersionName,
            "sameSignerAsInstalled" to sameSigner,
            "icon" to icon
        )
    }

    /** Parses one signing certificate into display + trust fields. */
    private fun certInfo(signature: Signature): Map<String, Any?> {
        val der = signature.toByteArray()
        val out = HashMap<String, Any?>()
        out["sha256"] = hex(MessageDigest.getInstance("SHA-256").digest(der), true)
        out["sha1"] = hex(MessageDigest.getInstance("SHA-1").digest(der), true)
        runCatching {
            val cert = CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(der)) as X509Certificate
            out["subject"] = cert.subjectX500Principal.name
            out["issuer"] = cert.issuerX500Principal.name
            out["serialNumber"] = cert.serialNumber.toString(16).uppercase(Locale.US)
            out["signatureAlgorithm"] = cert.sigAlgName
            out["notBefore"] = cert.notBefore.time
            out["notAfter"] = cert.notAfter.time
            out["selfSigned"] = cert.subjectX500Principal == cert.issuerX500Principal
        }
        return out
    }

    private fun fileDigest(file: File, algorithm: String): String {
        val md = MessageDigest.getInstance(algorithm)
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                md.update(buffer, 0, read)
            }
        }
        return hex(md.digest(), false)
    }

    private fun hex(data: ByteArray, colon: Boolean): String {
        val sb = StringBuilder(data.size * if (colon) 3 else 2)
        for ((i, b) in data.withIndex()) {
            if (colon && i > 0) sb.append(':')
            sb.append(String.format(Locale.US, "%02X", b.toInt() and 0xFF))
        }
        return sb.toString()
    }

    // ------------------------------------------------------------ cache index

    private companion object {
        val DEX_NAME = Regex("classes\\d*\\.dex")
    }

    /** `{entries: [...], totalBytes: n}` for one source. */
    private fun cacheIndexPayload(sourceId: String): Map<String, Any?> {
        val cache = loadCache()
        val entries = ArrayList<Map<String, Any?>>()
        var total = 0L
        val prefix = "$sourceId::"
        val keys = cache.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (!key.startsWith(prefix) || isHistoricalKey(key)) continue
            val obj = cache.optJSONObject(key) ?: continue
            val entry = cacheEntryMap(key, obj) ?: continue
            total += (entry["size"] as? Long) ?: 0L
            entries.add(entry)
        }
        return mapOf("entries" to entries, "totalBytes" to total)
    }

    /** Every cached APK across all sources, each tagged with its `sourceId`. */
    private fun cacheIndexAllPayload(): Map<String, Any?> {
        val cache = loadCache()
        val entries = ArrayList<Map<String, Any?>>()
        var total = 0L
        val keys = cache.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val obj = cache.optJSONObject(key) ?: continue
            val entry = cacheEntryMap(key, obj) ?: continue
            total += (entry["size"] as? Long) ?: 0L
            entries.add(entry)
        }
        return mapOf("entries" to entries, "totalBytes" to total)
    }

    private fun cacheEntryMap(key: String, obj: JSONObject): Map<String, Any?>? {
        val file = File(cacheDir(), obj.optString("file"))
        if (!file.exists()) return null
        val iconFile = File(cacheDir(), obj.optString("icon"))
        return mapOf(
            "id" to key,
            "historical" to obj.optBoolean("historical", false),
            "sourceId" to key.substringBefore("::"),
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
        val keepAll = boolArg(payload, "keepAllVersions")
        val prefix = "$sourceId::"
        val keys = cache.keys().asSequence().toList()
        for (key in keys) {
            if (!key.startsWith(prefix) || isHistoricalKey(key)) continue
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
            if (keepAll && file.exists()) {
                // Keep the outdated copy as history instead of deleting it.
                archiveEntry(cache, key, obj)
            } else {
                if (file.exists() && file.delete()) freed += obj.optLong("size", 0L)
                val icon = obj.optString("icon")
                if (icon.isNotEmpty()) runCatching { File(cacheDir(), icon).delete() }
                cache.remove(key)
            }
        }
        saveCache(cache)
        return freed
    }

    /**
     * Deletes a cached APK (by source + remote path) together with any kept
     * historical copies of the same file. Returns freed bytes.
     */
    private fun cacheDelete(sourceId: String, remotePath: String): Long {
        if (remotePath.isEmpty()) return 0L
        val cache = loadCache()
        val prefix = cacheKey(sourceId, remotePath)
        var freed = 0L
        val keys = cache.keys().asSequence().toList()
        for (key in keys) {
            if (key != prefix && !key.startsWith("$prefix$histMark")) continue
            freed += deleteCacheEntry(cache, key)
        }
        saveCache(cache)
        return freed
    }

    /** Deletes one cache entry by its exact key/id. Returns freed bytes. */
    private fun cacheDeleteById(id: String): Long {
        if (id.isEmpty()) return 0L
        val cache = loadCache()
        val freed = deleteCacheEntry(cache, id)
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

    /** Whether the app is allowed to install unknown packages (API 26+). */
    private fun canInstallPackages(): Boolean = if (
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
    ) {
        try {
            context.packageManager.canRequestPackageInstalls()
        } catch (_: Throwable) {
            false
        }
    } else {
        true
    }

    /** Sends the user to the "install unknown apps" screen for this app. */
    private fun openInstallPermissionSettings(): Boolean = try {
        val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
            .setData(Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (_: Throwable) {
        false
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
