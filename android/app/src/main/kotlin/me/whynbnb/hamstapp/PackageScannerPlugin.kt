package me.whynbnb.hamstapp

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.AppOpsManager
import android.app.WallpaperManager
import android.app.usage.NetworkStatsManager
import android.app.usage.StorageStats
import android.app.usage.StorageStatsManager
import android.app.usage.UsageStatsManager
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.PermissionInfo
import android.content.pm.ResolveInfo
import android.content.pm.Signature
import android.content.pm.SigningInfo
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.ConnectivityManager
import android.net.TrafficStats
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.StatFs
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.os.storage.StorageManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.util.Base64
import androidx.core.app.NotificationManagerCompat
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

    init {
        // Load the persisted unread-notification state as soon as the bridge
        // exists, so counts are available even before the listener connects.
        NotificationStore.init(context)
        registerTorchCallback()
    }

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
            "webAppReport" -> {
                executor.execute {
                    val report = runCatching { webAppReport() }.getOrElse {
                        mapOf("error" to describe(it))
                    }
                    mainHandler.post { result.success(report) }
                }
            }
            "getAppIcon" -> {
                val pkg = call.argument<String>("packageName")
                val size = call.argument<Int>("size") ?: 144
                val activity = call.argument<String>("activity")
                if (pkg == null) {
                    result.error("BAD_ARGS", "packageName is required", null)
                    return
                }
                val cacheKey = "$pkg|${activity ?: ""}@$size"
                iconCache[cacheKey]?.let {
                    result.success(it)
                    return
                }
                executor.execute {
                    try {
                        val bytes = loadIcon(pkg, size, activity)
                        if (bytes != null) iconCache[cacheKey] = bytes
                        mainHandler.post { result.success(bytes) }
                    } catch (t: Throwable) {
                        mainHandler.post { result.error("ICON_FAILED", t.message, null) }
                    }
                }
            }
            "launchApp" -> {
                val pkg = call.argument<String>("packageName")
                val activity = call.argument<String>("activity")
                mainHandler.post {
                    val reason = if (pkg == null) "missing" else launchApp(pkg, activity)
                    if (reason == null && pkg != null) {
                        // Launching the app counts as reading its notifications.
                        NotificationStore.markAllRead(pkg)
                        NotificationStore.emit()
                    }
                    result.success(
                        mapOf("ok" to (reason == null), "reason" to (reason ?: ""))
                    )
                }
            }
            "getLaunchActivities" -> {
                val pkg = call.argument<String>("packageName")
                executor.execute {
                    val list = runCatching {
                        if (pkg == null) emptyList() else launchActivities(pkg)
                    }.getOrDefault(emptyList())
                    mainHandler.post { result.success(list) }
                }
            }
            "clearNotificationMark" -> {
                val pkg = call.argument<String>("packageName")
                if (pkg != null) {
                    NotificationStore.markAllRead(pkg)
                    NotificationStore.emit()
                }
                result.success(pkg != null)
            }
            "clearAllNotificationMarks" -> {
                NotificationStore.clearAll()
                NotificationStore.emit()
                result.success(true)
            }
            "openAppInfo" -> {
                val pkg = call.argument<String>("packageName")
                mainHandler.post { result.success(pkg != null && openAppInfo(pkg)) }
            }
            "openUrl" -> {
                val url = call.argument<String>("url")
                val pkg = call.argument<String>("package")
                mainHandler.post { result.success(url != null && openUrl(url, pkg)) }
            }
            "browsers" -> {
                executor.execute {
                    val list = runCatching { browserApps() }.getOrDefault(emptyList())
                    mainHandler.post { result.success(list) }
                }
            }
            "webAppHandler" -> {
                val url = call.argument<String>("url")
                executor.execute {
                    val info = runCatching {
                        if (url.isNullOrEmpty()) null else webAppHandler(url)
                    }.getOrNull()
                    mainHandler.post { result.success(info) }
                }
            }
            "openWebApp" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrEmpty()) {
                    result.success(false)
                    return
                }
                mainHandler.post {
                    val ok = runCatching { startWebAppWindow(call, url) }
                        .onFailure {
                            NotificationStore.addEvent(
                                "网页应用 · 窗口启动异常 · ${describe(it)}"
                            )
                        }
                        .getOrDefault(false)
                    result.success(ok)
                }
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
            // ---------------- storage, privacy, signature, device status -----
            "usageAccess" -> executor.execute {
                val granted = hasUsageAccess()
                mainHandler.post { result.success(mapOf("granted" to granted)) }
            }
            "openUsageAccessSettings" -> mainHandler.post {
                result.success(openUsageAccessSettings())
            }
            "appStorage" -> {
                val pkg = call.argument<String>("packageName")
                executor.execute {
                    val info = runCatching {
                        if (pkg.isNullOrEmpty()) {
                            mapOf("ok" to false, "reason" to "args")
                        } else {
                            appStorage(pkg)
                        }
                    }.getOrElse { mapOf("ok" to false, "reason" to describe(it)) }
                    mainHandler.post { result.success(info) }
                }
            }
            "storageRanking" -> executor.execute {
                val ranking = runCatching { storageRanking() }.getOrElse {
                    mapOf(
                        "entries" to emptyList<Map<String, Any?>>(),
                        "permission" to hasUsageAccess(),
                        "error" to describe(it)
                    )
                }
                mainHandler.post { result.success(ranking) }
            }
            "appPermissions" -> {
                val pkg = call.argument<String>("packageName")
                executor.execute {
                    val list = runCatching {
                        if (pkg.isNullOrEmpty()) {
                            emptyList<Map<String, Any?>>()
                        } else {
                            appPermissions(pkg)
                        }
                    }.getOrDefault(emptyList())
                    mainHandler.post { result.success(list) }
                }
            }
            "appSignature" -> {
                val pkg = call.argument<String>("packageName")
                executor.execute {
                    val info = runCatching {
                        if (pkg.isNullOrEmpty()) null else appSignature(pkg)
                    }.getOrNull()
                    mainHandler.post { result.success(info) }
                }
            }
            // One pass over every installed package for the facts a snapshot
            // records next to each app: requested permissions, signing
            // certificate, target SDK, installer and whether it lives on
            // external storage. A single getInstalledPackages call, so a
            // snapshot does not turn into hundreds of binder round trips.
            // The wallpaper's own colours: the closest public API to the
            // launcher's Material You seed. Empty when the platform will not
            // tell us (Android 8.0 or older, or a wallpaper that declares
            // nothing) — the UI then keeps the colour it already has.
            "wallpaperColors" -> executor.execute {
                val colors = runCatching { wallpaperColors() }
                    .getOrDefault(emptyList())
                mainHandler.post {
                    result.success(
                        mapOf("ok" to colors.isNotEmpty(), "colors" to colors)
                    )
                }
            }
            "appFacts" -> executor.execute {
                val facts = runCatching { appFacts() }.getOrDefault(emptyMap())
                mainHandler.post { result.success(facts) }
            }
            "installSource" -> {
                val pkg = call.argument<String>("packageName")
                executor.execute {
                    val info = runCatching {
                        if (pkg.isNullOrEmpty()) {
                            emptyMap<String, Any?>()
                        } else {
                            installSource(pkg)
                        }
                    }.getOrDefault(emptyMap())
                    mainHandler.post { result.success(info) }
                }
            }
            "permissionAudit" -> executor.execute {
                val audit = runCatching { permissionAudit() }.getOrElse {
                    mapOf(
                        "capabilities" to emptyList<Map<String, Any?>>(),
                        "error" to describe(it)
                    )
                }
                mainHandler.post { result.success(audit) }
            }
            "deviceStatus" -> executor.execute {
                val status = runCatching { deviceStatus() }.getOrElse {
                    mapOf(
                        "level" to -1,
                        "charging" to false,
                        "freeBytes" to 0L,
                        "totalBytes" to 0L
                    )
                }
                mainHandler.post { result.success(status) }
            }
            "screenTimeToday" -> executor.execute {
                val info = runCatching { screenTimeToday() }.getOrElse {
                    mapOf("permitted" to false, "totalMillis" to 0L)
                }
                mainHandler.post { result.success(info) }
            }
            "trafficSummary" -> executor.execute {
                val info = runCatching { trafficSummary() }.getOrElse {
                    mapOf(
                        "permitted" to false,
                        "mobileBytes" to 0L,
                        "wifiBytes" to 0L
                    )
                }
                mainHandler.post { result.success(info) }
            }
            "openNextAlarm" -> mainHandler.post {
                result.success(openNextAlarm())
            }
            "setTorch" -> {
                val on = call.argument<Boolean>("on") ?: false
                mainHandler.post { result.success(setTorch(on)) }
            }
            "trafficTotals" -> executor.execute {
                val totals = runCatching { trafficTotals() }.getOrElse {
                    mapOf("rx" to 0L, "tx" to 0L, "supported" to false)
                }
                mainHandler.post { result.success(totals) }
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
            // The app's own scratch directory (Android may clear it whenever it
            // likes). Exposed so the storage screen measures the real place
            // instead of guessing a path.
            "tempDir" -> mainHandler.post {
                result.success(context.cacheDir.absolutePath)
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
            "hasNotificationAccess" -> {
                result.success(hasNotificationAccess())
            }
            "openNotificationAccessSettings" -> {
                mainHandler.post { result.success(openNotificationAccessSettings()) }
            }
            "getNotificationCounts" -> {
                result.success(NotificationStore.counts())
            }
            "notificationDiagnostics" -> {
                val counts = NotificationStore.counts()
                result.success(
                    mapOf(
                        "connected" to NotificationStore.listenerConnected,
                        "lastEventAt" to NotificationStore.lastEventAt,
                        "events" to NotificationStore.eventCount,
                        "packages" to counts.size,
                        "total" to counts.values.sum(),
                    ),
                )
            }
            "setLoggingEnabled" -> {
                NotificationStore.loggingEnabled = call.arguments as? Boolean ?: false
                if (NotificationStore.loggingEnabled) NotificationStore.flushEvents()
                result.success(null)
            }
            "requestNotificationRebind" -> {
                mainHandler.post { result.success(requestNotificationRebind()) }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * The wallpaper's own colours (primary first). Public API since Android
     * 8.1, no vendor hooks involved: the launcher's exact Material You seed is
     * not exposed, so its private colours are used to derive a seed of our own
     * in Dart.
     */
    private fun wallpaperColors(): List<Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) {
            return emptyList()
        }
        val manager = WallpaperManager.getInstance(context)
        val colors = manager.getWallpaperColors(WallpaperManager.FLAG_SYSTEM)
            ?: return emptyList()
        return listOf("getPrimaryColor", "getSecondaryColor", "getTertiaryColor")
            .mapNotNull { name -> readWallpaperColor(colors, name) }
    }

    /**
     * One of a [WallpaperColors]' colours as an ARGB int.
     *
     * Android 15 changed these getters from returning an ARGB int to returning
     * an `android.graphics.Color` object, which is not binary compatible; the
     * app still runs on Android 7. Reading them reflectively lets the same code
     * handle whichever shape the running platform returns, instead of failing
     * with a link error on one side of the divide.
     */
    private fun readWallpaperColor(colors: Any, getter: String): Int? = runCatching {
        when (val raw = colors.javaClass.getMethod(getter).invoke(colors)) {
            is Int -> raw
            null -> null
            else -> raw.javaClass.getMethod("toArgb").invoke(raw) as? Int
        }
    }.getOrNull()

    /**
     * Per-package facts captured with a snapshot, keyed by package name. The
     * requested permissions are the declared ones (not the grant state), which
     * is what "did this update ask for more?" is about.
     */
    private fun appFacts(): Map<String, Any?> {
        val pm = context.packageManager
        var flags = PackageManager.GET_PERMISSIONS
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            flags = flags or PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            flags = flags or PackageManager.GET_SIGNATURES
        }
        val packages = pm.getInstalledPackages(flags)
        val out = HashMap<String, Any?>(packages.size * 2)
        for (info in packages) {
            val app = info.applicationInfo ?: continue
            val permissions = (info.requestedPermissions ?: emptyArray<String>())
                .sorted()
            var sha = ""
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val si = info.signingInfo
                val arr = if (si != null && si.hasMultipleSigners()) {
                    si.apkContentsSigners
                } else {
                    si?.signingCertificateHistory
                }
                sha = arr?.firstOrNull()?.let { certInfo(it)["sha256"] as? String } ?: ""
            } else {
                @Suppress("DEPRECATION")
                sha = info.signatures?.firstOrNull()
                    ?.let { certInfo(it)["sha256"] as? String } ?: ""
            }
            out[info.packageName] = mapOf(
                "permissions" to permissions,
                "signature" to sha,
                "targetSdk" to app.targetSdkVersion,
                "installer" to installerOf(info.packageName),
                "external" to ((app.flags and ApplicationInfo.FLAG_EXTERNAL_STORAGE) != 0)
            )
        }
        return out
    }

    /**
     * Who installed [packageName]: '' when the package was side-loaded or the
     * installer is unknown. `getInstallerPackageName` still answers on newer
     * releases, but the newer API is the one that is still supported.
     */
    private fun installerOf(packageName: String): String = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.packageManager.getInstallSourceInfo(packageName)
                .installingPackageName ?: ""
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getInstallerPackageName(packageName) ?: ""
        }
    }.getOrDefault("")

    /**
     * The full install chain of a package: who installed it, which app asked
     * for the install and which app the install is attributed to. Only the
     * installer is knowable before Android 11, so the other two stay empty
     * there instead of being guessed.
     */
    private fun installSource(packageName: String): Map<String, Any?> {
        val installer = installerOf(packageName)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return mapOf(
                "installer" to installer,
                "initiating" to "",
                "originating" to "",
                "detailed" to false
            )
        }
        return runCatching {
            val src = context.packageManager.getInstallSourceInfo(packageName)
            mapOf(
                "installer" to (src.installingPackageName ?: installer),
                "initiating" to (src.initiatingPackageName ?: ""),
                "originating" to (src.originatingPackageName ?: ""),
                "detailed" to true
            )
        }.getOrElse {
            mapOf(
                "installer" to installer,
                "initiating" to "",
                "originating" to "",
                "detailed" to false
            )
        }
    }

    private fun scanApps(includeSystem: Boolean): List<Map<String, Any?>> {
        val pm = context.packageManager
        // GET_META_DATA so installed web apps (WebAPK / Trusted Web Activity)
        // can be told apart from ordinary apps — see [webAppUrl]. It costs one
        // manifest parse per package, which the scan budget can absorb.
        val packages: List<PackageInfo> =
            pm.getInstalledPackages(PackageManager.GET_META_DATA)
        val shells = launcherWebApps(pm)
        val out = ArrayList<Map<String, Any?>>(packages.size)
        for (info in packages) {
            val app = info.applicationInfo ?: continue
            val isSystem = (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (!includeSystem && isSystem) continue

            val label = runCatching { app.loadLabel(pm).toString() }.getOrDefault(info.packageName)
            val sourceDir = app.sourceDir
            val sizeBytes = if (sourceDir != null) File(sourceDir).length() else 0L
            val webUrl = webAppUrl(app, info.packageName, shells)

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
                    "uid" to app.uid,
                    "installer" to installerOf(info.packageName),
                    "isWebApp" to (webUrl != null),
                    "webUrl" to (webUrl ?: ""),
                    "webSignal" to webAppSignal(app, info.packageName, shells)
                )
            )
        }
        return out
    }

    /**
     * How a package was recognised as a web app: `entry` (its launcher activity
     * is a shell), `package` (the name says so) or `metadata` (it declares a
     * web-app manifest entry). '' when it is an ordinary app.
     */
    private fun webAppSignal(
        app: ApplicationInfo,
        packageName: String,
        shells: Map<String, String>,
    ): String {
        if (shells.containsKey(packageName)) return "entry"
        val lowerPackage = packageName.lowercase(Locale.ROOT)
        if (WEB_APP_PKG_MARKERS.any { lowerPackage.contains(it) }) return "package"
        val md = app.metaData
        if (md != null) {
            for (key in md.keySet()) {
                val lowerKey = key.lowercase(Locale.ROOT)
                if (WEB_APP_META_MARKERS.any { lowerKey.contains(it) }) return "metadata"
            }
        }
        return ""
    }

    /**
     * Site behind an installed web app, or null when [packageName] is an
     * ordinary app.
     *
     * A web app installed from a browser or a store is a real package — either
     * a Chromium "WebAPK" shell or a Trusted Web Activity, which is what most
     * Play Store web apps are — so it scans, launches, takes tiles and
     * favorites like any other app. This only says which packages are really
     * websites, using several signals at once so no single vendor's names are
     * required: the launcher entry's type ([shells]), the package name, and the
     * manifest metadata keys of the application. The URL may stay empty when a
     * shell keeps it somewhere we cannot read.
     */
    private fun webAppUrl(
        app: ApplicationInfo,
        packageName: String,
        shells: Map<String, String>,
    ): String? {
        if (webAppSignal(app, packageName, shells).isEmpty()) return null
        val fromShell = shells[packageName]
        return if (!fromShell.isNullOrEmpty()) {
            fromShell
        } else {
            webAppUrlIn(app.metaData) ?: ""
        }
    }

    /**
     * Desktop entries of web apps, as package name to the site URL the entry
     * declares ('' when it declares none) — from a single bulk query.
     *
     * The launcher activity's class name is public and says what the entry is
     * (`org.chromium.webapk.shell_apk.MainActivity`, `…androidbrowserhelper.
     * trusted.LauncherActivity`, `…customtabs.trusted.LauncherActivity`), so a
     * shell is recognised even when its metadata is unreadable and its package
     * name hints at nothing.
     */
    private fun launcherWebApps(pm: PackageManager): Map<String, String> {
        val out = HashMap<String, String>()
        var flags = PackageManager.GET_META_DATA
        if (Build.VERSION.SDK_INT >= 24) {
            flags = flags or PackageManager.MATCH_DISABLED_UNTIL_USED_COMPONENTS
        }
        val resolved = runCatching {
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            if (Build.VERSION.SDK_INT >= 33) {
                pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(flags.toLong()))
            } else {
                @Suppress("DEPRECATION")
                pm.queryIntentActivities(intent, flags)
            }
        }.getOrDefault(emptyList())
        for (ri in resolved) {
            val ai = ri.activityInfo ?: continue
            val pkg = ai.packageName ?: continue
            val cls = (ai.name ?: "").lowercase(Locale.ROOT)
            val lowerPkg = pkg.lowercase(Locale.ROOT)
            val looksLikeShell = WEB_APP_SHELL_MARKERS.any { cls.contains(it) } ||
                WEB_APP_PKG_MARKERS.any { lowerPkg.contains(it) }
            if (!looksLikeShell) continue
            out[pkg] = webAppUrlIn(ai.metaData) ?: out[pkg] ?: ""
        }
        return out
    }

    /**
     * Site URL declared in web-app metadata, or null. Swapped shells declare
     * different keys and put them on either the `<application>` element or the
     * launcher activity, so both are checked and only an http(s) value is
     * accepted — metadata also holds things like icons and privacy links.
     */
    private fun webAppUrlIn(md: Bundle?): String? {
        if (md == null) return null
        var url: String? = null
        for (key in md.keySet()) {
            val lowerKey = key.lowercase(Locale.ROOT)
            if (WEB_APP_URL_KEYS.none { lowerKey.contains(it) }) continue
            val value = runCatching { md.getString(key) }.getOrNull()
            if (value != null && value.startsWith("http")) url = value
        }
        return url
    }

    /**
     * What the device actually holds, for the in-app check-up: totals, the
     * installed web apps, and the packages that look suspicious without being
     * confirmed. Nothing here is cached, so it reports the live state — the
     * point is to tell "this device has no web apps" apart from "detection
     * missed one", and to show shortcuts are not packages at all.
     */
    private fun webAppReport(): Map<String, Any?> {
        val pm = context.packageManager
        val packages = pm.getInstalledPackages(PackageManager.GET_META_DATA)
        val shells = launcherWebApps(pm)
        var user = 0
        var system = 0
        var metaReadable = 0
        var launcherEntries = 0
        val webApps = ArrayList<Map<String, Any?>>()
        val candidates = ArrayList<Map<String, Any?>>()
        for (info in packages) {
            val app = info.applicationInfo ?: continue
            val isSystem = (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (isSystem) system++ else user++
            if (app.metaData != null) metaReadable++
            val activity = launcherClass(pm, info.packageName)
            if (activity.isNotEmpty()) launcherEntries++
            val label = runCatching { app.loadLabel(pm).toString() }
                .getOrDefault(info.packageName)
            val size = app.sourceDir?.let { File(it).length() } ?: 0L
            val webUrl = webAppUrl(app, info.packageName, shells)
            val entry = mapOf(
                "packageName" to info.packageName,
                "appName" to label,
                "activity" to activity,
                "sizeBytes" to size,
                "isSystem" to isSystem,
                "webUrl" to (webUrl ?: ""),
            )
            if (webUrl != null) {
                webApps.add(entry)
                continue
            }
            val signal = candidateSignal(info.packageName, shells, size, isSystem)
            if (signal != null) candidates.add(entry + mapOf("signal" to signal))
        }
        return mapOf(
            "total" to packages.size,
            "user" to user,
            "system" to system,
            "metaReadable" to metaReadable,
            "launcherEntries" to launcherEntries,
            "shells" to shells.size,
            "webApps" to webApps,
            "candidates" to candidates,
        )
    }

    /** Why a package looks like a web app even though it was not confirmed. */
    private fun candidateSignal(
        packageName: String,
        shells: Map<String, String>,
        sizeBytes: Long,
        isSystem: Boolean,
    ): String? {
        if (shells.containsKey(packageName)) return "entry"
        if (WEB_APP_PKG_MARKERS.any { packageName.lowercase(Locale.ROOT).contains(it) }) {
            return "packageName"
        }
        // A web app shell is a few dozen kilobytes; ordinary apps are not.
        // System packages are skipped here — they are full of tiny stubs.
        if (!isSystem && sizeBytes in 1..512_000L) return "small"
        return null
    }

    /** Launcher activity class of a package, or '' when it has no entry. */
    private fun launcherClass(pm: PackageManager, packageName: String): String =
        runCatching {
            pm.getLaunchIntentForPackage(packageName)?.component?.className ?: ""
        }.getOrDefault("")

    /**
     * Icon of one launcher entry, falling back to the application icon. A
     * package's entries can have different icons — the dialer and the contacts
     * tabs of the same package carry their own — so [activity] picks which one.
     */
    private fun loadIcon(
        packageName: String,
        sizePx: Int,
        activity: String? = null,
    ): ByteArray? {
        val pm = context.packageManager
        val drawable: Drawable = (if (activity.isNullOrEmpty()) {
            null
        } else {
            runCatching {
                pm.getActivityIcon(ComponentName(packageName, activity))
            }.getOrNull()
        }) ?: runCatching {
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

    /**
     * Every entry a package can be started through: its desktop icons plus any
     * activity matching a probe intent, each carrying its own label and whether
     * it is a desktop icon. The labels are the system's, so nothing is hardcoded
     * per app.
     */
    private fun launchActivities(packageName: String): List<Map<String, Any?>> {
        val pm = context.packageManager
        val out = LinkedHashMap<String, Map<String, Any?>>()
        fun add(ri: ResolveInfo, launcher: Boolean) {
            val ai = ri.activityInfo ?: return
            val existing = out[ai.name]
            // A launcher entry outranks a probe match for the same activity.
            if (existing != null) {
                if (!launcher) return
                if (existing["launcher"] == true) return
            }
            val label = runCatching { ri.loadLabel(pm).toString() }
                .getOrNull()
                ?.takeIf { it.isNotBlank() }
                ?: ai.name
            out[ai.name] = mapOf(
                "name" to ai.name,
                "label" to label,
                "launcher" to launcher,
            )
        }
        queryLauncherActivities(packageName).forEach { add(it, true) }
        for (base in probeIntents) {
            resolveActivities(base, packageName).forEach { add(it, false) }
        }
        return out.values.toList()
    }

    /** `ACTION_MAIN`/`CATEGORY_LAUNCHER` activities, optionally for one package. */
    private fun queryLauncherActivities(packageName: String?): List<ResolveInfo> =
        resolveActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER),
            packageName,
        )

    /**
     * Extra entry intents worth probing beyond the desktop icons. On some ROMs
     * the dialer has no icon of its own and is only reachable through the
     * standard "place a call" intent, so it never shows up in a launcher query.
     */
    private val probeIntents = listOf(Intent(Intent.ACTION_DIAL, Uri.parse("tel:")))

    /** Resolves [intent] (optionally limited to one package), version-safely. */
    private fun resolveActivities(
        intent: Intent,
        packageName: String? = null,
    ): List<ResolveInfo> {
        val pm = context.packageManager
        val probe = Intent(intent)
        if (packageName != null) probe.setPackage(packageName)
        // MATCH_DISABLED_UNTIL_USED_COMPONENTS: the ROM launchers show icons for
        // preinstalled-but-never-opened apps, which are hidden from a plain
        // query. Matching them keeps our list in step with the desktop, and lets
        // us start an entry the default lookup would miss.
        var flags = 0
        if (Build.VERSION.SDK_INT >= 24) {
            flags = flags or PackageManager.MATCH_DISABLED_UNTIL_USED_COMPONENTS
        }
        return runCatching {
            if (Build.VERSION.SDK_INT >= 33) {
                pm.queryIntentActivities(
                    probe,
                    PackageManager.ResolveInfoFlags.of(flags.toLong()),
                )
            } else {
                @Suppress("DEPRECATION")
                pm.queryIntentActivities(probe, flags)
            }
        }.getOrDefault(emptyList())
    }

    /**
     * Starts [packageName]. Returns null when it worked, otherwise a reason
     * code (`missing` / `disabled` / `no_entry` / `blocked`) so the UI can say
     * what actually went wrong instead of a generic failure.
     *
     * [activity] pins one of the package's desktop entries; without it the
     * system's default entry is used.
     */
    private fun launchApp(packageName: String, activity: String? = null): String? {
        val pm = context.packageManager
        val app = runCatching { pm.getApplicationInfo(packageName, 0) }.getOrNull()
            ?: return "missing"
        if (!app.enabled) return "disabled"

        // A few ROMs ship components the plain lookup misses; fall back to the
        // explicit launcher activity, then to a probe intent (the dialer often
        // has no icon of its own), before giving up.
        val base = if (!activity.isNullOrEmpty()) {
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setComponent(ComponentName(packageName, activity))
        } else {
            pm.getLaunchIntentForPackage(packageName)
                ?: explicitLaunchIntent(packageName)
                ?: probeLaunchIntent(packageName)
        }
        val intent = base ?: return "no_entry"
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return if (runCatching { context.startActivity(intent) }.isSuccess) {
            null
        } else {
            "blocked"
        }
    }

    private fun explicitLaunchIntent(packageName: String): Intent? {
        val info = queryLauncherActivities(packageName).firstOrNull()?.activityInfo
            ?: return null
        return Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .setComponent(ComponentName(info.packageName, info.name))
    }

    /** Starts whatever a probe intent resolves to inside [packageName]. */
    private fun probeLaunchIntent(packageName: String): Intent? {
        for (base in probeIntents) {
            val info = resolveActivities(base, packageName).firstOrNull()?.activityInfo
                ?: continue
            return Intent(base).setComponent(ComponentName(info.packageName, info.name))
        }
        return null
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

    /**
     * Builds the intent for [WebAppActivity] and starts it.
     *
     * Every value read back from the call is converted through [Number]: Dart
     * sends a 64-bit int when a colour does not fit in 32 bits (any colour with
     * a high alpha byte does not), and reading that as an Int throws — which is
     * what silently sent PWA entries to the browser before.
     */
    private fun startWebAppWindow(call: MethodCall, url: String): Boolean {
        val name = call.argument<String>("name") ?: ""
        val display = call.argument<String>("display") ?: "standalone"
        val theme = intArgument(call, "themeColor")
        val background = intArgument(call, "backgroundColor")
        val hideStatusBar = call.argument<Boolean>("hideStatusBar") ?: false
        val icon = call.argument<ByteArray>("icon")
        val intent = Intent(context, WebAppActivity::class.java).apply {
            // A window of its own: its own task, so it appears separately in
            // Recents and can be used beside the app. The address doubles as the
            // document identity, which is what makes re-opening the same site
            // bring the same window forward instead of stacking a second one.
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
            data = Uri.parse(url)
            putExtra(WebAppActivity.EXTRA_URL, url)
            putExtra(WebAppActivity.EXTRA_NAME, name)
            putExtra(WebAppActivity.EXTRA_DISPLAY, display)
            putExtra(WebAppActivity.EXTRA_SCOPE, call.argument<String>("scope") ?: "")
            putExtra(
                WebAppActivity.EXTRA_BROWSER,
                call.argument<String>("browserPackage") ?: "",
            )
            putExtra(WebAppActivity.EXTRA_HIDE_STATUS_BAR, hideStatusBar)
            putExtra(WebAppActivity.EXTRA_THEME_COLOR, theme)
            putExtra(WebAppActivity.EXTRA_BACKGROUND_COLOR, background)
            if (icon != null && icon.isNotEmpty()) {
                putExtra(WebAppActivity.EXTRA_ICON, icon)
            }
        }
        val started = runCatching { context.startActivity(intent) }.isSuccess
        NotificationStore.addEvent(
            "网页应用 · 打开 · $name · $url · display=$display · " +
                "theme=${Integer.toHexString(theme)} · 状态栏=${if (hideStatusBar) "隐藏" else "显示"} · " +
                "图标=${icon?.size ?: 0}B · " +
                (if (started) "已启动窗口" else "启动窗口失败（改用浏览器）")
        )
        return started
    }

    /** A call argument as an Int, whatever width the codec used for it. */
    private fun intArgument(call: MethodCall, key: String, def: Int = 0): Int =
        (call.argument<Any>(key) as? Number)?.toInt() ?: def

    /**
     * Opens a link: in the chosen browser, or in whatever claims the address.
     *
     * An https link for a site that is *installed* as a web app is routed by
     * Android itself to that app (App Links), and that app opens the site in the
     * browser's own standalone window — which is what "open in browser" usually
     * means. Pinning the intent to a browser would defeat that routing, so a
     * handler that is not a browser wins over the choice.
     *
     * Chrome's shortcuts (what "add to home screen" leaves behind) cannot be
     * launched this way: Chromium only opens its standalone web app window for a
     * verified WebAPK, a MAC-signed shortcut, or an intent from Chrome itself, so
     * those end up in a browser tab, as Chromium's own code says.
     */
    private fun openUrl(url: String, packageName: String? = null): Boolean {
        val handler = handlerPackage(url)
        val installedWebApp = handler != null &&
            handler != packageName &&
            !isBrowserPackage(handler)
        if (installedWebApp) {
            NotificationStore.addEvent(
                "网页应用 · 交给已安装的网页应用 · $url · $handler"
            )
            if (startView(url, null)) return true
        }
        val ok = startView(url, packageName)
        if (!ok && !packageName.isNullOrEmpty()) {
            NotificationStore.addEvent(
                "网页应用 · 指定浏览器打不开，改用系统默认 · $packageName"
            )
            return startView(url, null)
        }
        return ok
    }

    private fun startView(url: String, packageName: String?): Boolean {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
            // No package when nobody specific was asked for: the system then
            // hands the link to an installed web app for that site if there is
            // one, which is the only way into a browser's standalone window.
            if (!packageName.isNullOrEmpty()) setPackage(packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return runCatching {
            context.startActivity(intent)
            true
        }.getOrDefault(false)
    }

    /** Who would open [url] by default, or null when nobody claims it. */
    private fun handlerPackage(url: String): String? = runCatching {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        val resolved = if (Build.VERSION.SDK_INT >= 33) {
            context.packageManager.resolveActivity(
                intent,
                PackageManager.ResolveInfoFlags.of(0L),
            )
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.resolveActivity(intent, 0)
        }
        resolved?.activityInfo?.packageName
    }.getOrNull()

    /** A general-purpose browser, as opposed to a web app for one site. */
    private fun isBrowserPackage(packageName: String): Boolean = runCatching {
        browserApps().any { (it["packageName"] as? String) == packageName }
    }.getOrDefault(false)

    /**
     * Who would open [url]: an app installed for that site (a WebAPK or TWA,
     * which shows it in the browser's own standalone window), a general browser
     * (a tab), or nobody. Lets the app say what a tap will do — and makes
     * visible whether a site has been installed as a real web app rather than
     * left as a home-screen shortcut, which nothing outside the launcher can use.
     */
    private fun webAppHandler(url: String): Map<String, Any?>? {
        val pm = context.packageManager
        val handler = handlerPackage(url) ?: return null
        val label = runCatching {
            val info = if (Build.VERSION.SDK_INT >= 33) {
                pm.getApplicationInfo(handler, PackageManager.ApplicationInfoFlags.of(0L))
            } else {
                @Suppress("DEPRECATION")
                pm.getApplicationInfo(handler, 0)
            }
            pm.getApplicationLabel(info).toString()
        }.getOrDefault(handler)
        return mapOf(
            "packageName" to handler,
            "label" to label,
            "browser" to isBrowserPackage(handler),
        )
    }

    /**
     * Apps that can open an http(s) address, one entry per package: what "use
     * this browser" can offer.
     *
     * A plain query for an https URL also returns apps that only handle links
     * for their own hosts (shopping apps, chat apps), and a plain query is also
     * how a browser that handles only some hosts gets missed. Probing with a
     * host that cannot exist keeps only the handlers that accept *any* address —
     * which is what a browser is — and the browser category adds any that
     * advertise themselves as one.
     */
    private fun browserApps(): List<Map<String, Any?>> {
        val nonce = System.currentTimeMillis()
        fun handlers(intent: Intent): LinkedHashMap<String, String> {
            val pm = context.packageManager
            val out = LinkedHashMap<String, String>()
            val resolved = runCatching {
                if (Build.VERSION.SDK_INT >= 33) {
                    pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0L))
                } else {
                    @Suppress("DEPRECATION")
                    pm.queryIntentActivities(intent, 0)
                }
            }.getOrDefault(emptyList())
            for (ri in resolved) {
                val ai = ri.activityInfo ?: continue
                val pkg = ai.packageName ?: continue
                if (pkg == context.packageName) continue
                val label = runCatching { ai.loadLabel(pm).toString() }.getOrDefault(pkg)
                out.putIfAbsent(pkg, label)
            }
            return out
        }

        // A host that cannot exist: only a handler that accepts *any* address
        // answers, which is what a browser does and what an app handling links
        // for its own site does not. Both schemes are required, so an app that
        // merely registers an https deep link is left out.
        val https = handlers(
            Intent(
                Intent.ACTION_VIEW,
                Uri.parse("https://hamstapp-probe-$nonce.invalid/"),
            )
        )
        val http = handlers(
            Intent(
                Intent.ACTION_VIEW,
                Uri.parse("http://hamstapp-probe-$nonce.invalid/"),
            )
        )
        val found = LinkedHashMap<String, String>()
        for ((pkg, label) in https) {
            if (http.containsKey(pkg)) found[pkg] = label
        }
        // Anything advertising the browser category is one, too.
        for ((pkg, label) in handlers(
            Intent(Intent.ACTION_MAIN).addCategory("android.intent.category.APP_BROWSER")
        )) {
            found.putIfAbsent(pkg, label)
        }
        return found.entries
            .sortedBy { it.value }
            .map { mapOf("packageName" to it.key, "label" to it.value) }
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
        val activities = info.activities ?: emptyArray()
        val services = info.services ?: emptyArray()
        val receivers = info.receivers ?: emptyArray()
        val providers = info.providers ?: emptyArray()
        val activityCount = activities.size
        val serviceCount = services.size
        val receiverCount = receivers.size
        val providerCount = providers.size
        // Exported components are reachable from other apps; the accessibility
        // and device-admin bindings are the two most powerful things an app can
        // ask to be, so the risk check wants to know about all of them.
        val exportedActivities = activities.count { it.exported }
        val exportedServices = services.count { it.exported }
        val exportedReceivers = receivers.count { it.exported }
        val exportedProviders = providers.count { it.exported }
        val accessibilityService = services.any {
            it.permission == "android.permission.BIND_ACCESSIBILITY_SERVICE"
        }
        val deviceAdminReceiver = receivers.any {
            it.permission == "android.permission.BIND_DEVICE_ADMIN"
        }

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
            "exportedActivities" to exportedActivities,
            "exportedServices" to exportedServices,
            "exportedReceivers" to exportedReceivers,
            "exportedProviders" to exportedProviders,
            "accessibilityService" to accessibilityService,
            "deviceAdminReceiver" to deviceAdminReceiver,
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

        /**
         * Hidden system action that shows the notification-access toggle for one
         * specific listener. Public API only exposes the whole list, so the raw
         * string is used and the call falls back to the list when unsupported.
         */
        const val ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS =
            "android.settings.NOTIFICATION_LISTENER_DETAIL_SETTINGS"

        /** Extra carrying the flattened [ComponentName] for the action above. */
        const val EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME =
            "android.provider.extra.NOTIFICATION_LISTENER_COMPONENT_NAME"

        /**
         * Web app markers, matched case-insensitively against metadata keys.
         * Chromium browsers (Chrome, Edge, Samsung Internet…) install a site as
         * a "WebAPK" shell, Play Store web apps are Trusted Web Activities, and
         * some browsers/ROMs ship their own wrapper — hence several markers and
         * no per-vendor branch.
         *
         * Only the trusted-activity prefixes and `webapk` are matched here: a
         * plain "webapp" key is common in ordinary apps (Gmail carries a
         * `…gms.webapp.…` entry), and the WebAPK cases it would add are already
         * covered by the package name and the launcher class.
         */
        val WEB_APP_META_MARKERS = arrayOf(
            "webapk",
            "customtabs.trusted",
            "browser.trusted",
        )

        /**
         * Launcher-activity class markers: shell classes we know by name
         * (Chromium's WebAPK shell, the Android Browser Helper and the older
         * custom-tabs TWA launcher). Matched on the class name so a shell is
         * recognisable even when its metadata is unreadable.
         */
        val WEB_APP_SHELL_MARKERS = arrayOf(
            "webapk",
            "webapp",
            "web_app",
            "androidbrowserhelper",
            "customtabs.trusted",
        )

        /** Package names that spell out that the package is a web app. */
        val WEB_APP_PKG_MARKERS = arrayOf("webapk", "webapp", "web_app")

        /**
         * Metadata keys holding the site URL, matched by lowercased substring:
         * WebAPK's `…shell_apk.startUrl` and the TWA `…trusted.DEFAULT_URL`,
         * plus the generic spellings a home-grown wrapper tends to use.
         */
        val WEB_APP_URL_KEYS = arrayOf(
            "starturl",
            "start_url",
            "default_url",
        )
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

    /** Whether the user granted this app notification-listener access. */
    private fun hasNotificationAccess(): Boolean = runCatching {
        NotificationManagerCompat.getEnabledListenerPackages(context)
            .contains(context.packageName)
    }.getOrDefault(false)

    /**
     * Opens the system UI where notification access is granted.
     *
     * Android has **no runtime permission dialog** for this special access, so
     * the app can only take the user there. Where the device supports it we jump
     * straight to 囤囤's own toggle page; otherwise we fall back to the full list.
     */
    private fun openNotificationAccessSettings(): Boolean {
        val detail = Intent(ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
            .putExtra(
                EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                ComponentName(context, NotifListenerService::class.java)
                    .flattenToString(),
            )
        if (startExternal(detail)) return true
        return startExternal(
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS),
        )
    }

    /** Launches [intent] in its own task, reporting whether a target was found. */
    private fun startExternal(intent: Intent): Boolean = try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: Throwable) {
        false
    }

    /**
     * Asks the system to re-bind the notification listener, e.g. right after the
     * user granted access, so counts start flowing without a reboot.
     */
    private fun requestNotificationRebind(): Boolean = runCatching {
        val component = ComponentName(context, NotifListenerService::class.java)
        NotificationListenerService.requestRebind(component)
    }.isSuccess

    /**
     * Copies an installed APK into the app's private cache and hands it to the
     * system share sheet. The installed APK lives under /data/app, which is
     * outside the FileProvider roots, so it has to be copied first.
     */
    private fun shareApk(sourcePath: String, displayName: String): Boolean {        val src = File(sourcePath)
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

    // --------------------------------- storage / privacy / signature / status

    /**
     * Whether the user granted 囤囤 "usage access". The storage sizes of other
     * apps (and our own) are only readable with it, so every storage feature
     * asks first and guides the user there instead of showing wrong numbers.
     */
    private fun hasUsageAccess(): Boolean =
        opAllowed(AppOpsManager.OPSTR_GET_USAGE_STATS, context.packageName)

    private fun openUsageAccessSettings(): Boolean {
        val base = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // Android 10+ can open our own row directly; ROMs that do not handle
        // the package-qualified form fall back to the plain list.
        if (Build.VERSION.SDK_INT >= 29) {
            val targeted = Intent(base).setData(
                Uri.fromParts("package", context.packageName, null)
            )
            if (startExternal(targeted)) return true
        }
        return startExternal(base)
    }

    private fun opAllowed(op: String, packageName: String): Boolean = runCatching {
        val ops = context.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
            ?: return false
        val uid = context.packageManager
            .getApplicationInfo(packageName, 0).uid
        val mode = if (Build.VERSION.SDK_INT >= 29) {
            ops.unsafeCheckOpNoThrow(op, uid, packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow(op, uid, packageName)
        }
        mode == AppOpsManager.MODE_ALLOWED
    }.getOrDefault(false)

    private fun storageStats(): StorageStatsManager? =
        if (Build.VERSION.SDK_INT >= 26) {
            context.getSystemService(Context.STORAGE_STATS_SERVICE)
                as? StorageStatsManager
        } else {
            null
        }

    /** Per-app storage of one package, or a reason why it cannot be read. */
    private fun statsFor(packageName: String): StorageStats? = runCatching {
        storageStats()?.queryStatsForPackage(
            StorageManager.UUID_DEFAULT,
            packageName,
            Process.myUserHandle()
        )
    }.getOrNull()

    private fun appStorage(packageName: String): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < 26) {
            return mapOf("ok" to false, "reason" to "unsupported")
        }
        if (!hasUsageAccess()) {
            return mapOf("ok" to false, "reason" to "permission")
        }
        val stats = statsFor(packageName)
            ?: return mapOf("ok" to false, "reason" to "unavailable")
        val apk = stats.appBytes
        val data = stats.dataBytes
        val cache = stats.cacheBytes
        return mapOf(
            "ok" to true,
            "apkBytes" to apk,
            "dataBytes" to data,
            "cacheBytes" to cache,
            "totalBytes" to (apk + data + cache)
        )
    }

    /**
     * Every visible app's storage, biggest first. Only meaningful with usage
     * access; without it the list comes back empty and `permission` is false so
     * the screen can ask for it instead of showing a blank list.
     */
    private fun storageRanking(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < 26) {
            return mapOf(
                "entries" to emptyList<Map<String, Any?>>(),
                "permission" to true,
                "unsupported" to true
            )
        }
        if (!hasUsageAccess()) {
            return mapOf(
                "entries" to emptyList<Map<String, Any?>>(),
                "permission" to false
            )
        }
        val pm = context.packageManager
        val entries = ArrayList<Map<String, Any?>>()
        for (info in visibleAppInfos()) {
            val stats = statsFor(info.packageName) ?: continue
            val apk = stats.appBytes
            val data = stats.dataBytes
            val cache = stats.cacheBytes
            val total = apk + data + cache
            if (total <= 0) continue
            entries.add(
                mapOf(
                    "packageName" to info.packageName,
                    "appName" to runCatching { info.loadLabel(pm).toString() }
                        .getOrDefault(info.packageName),
                    "isSystem" to ((info.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                    "apkBytes" to apk,
                    "dataBytes" to data,
                    "cacheBytes" to cache,
                    "totalBytes" to total
                )
            )
        }
        entries.sortByDescending { (it["totalBytes"] as? Long) ?: 0L }
        return mapOf("entries" to entries, "permission" to true)
    }

    /** Requested permissions of one package, dangerous and granted first. */
    private fun appPermissions(packageName: String): List<Map<String, Any?>> {
        val pm = context.packageManager
        val info = packageInfo(packageName, PackageManager.GET_PERMISSIONS)
            ?: return emptyList()
        val names = info.requestedPermissions ?: return emptyList()
        val flags = info.requestedPermissionsFlags
        val out = ArrayList<Map<String, Any?>>()
        for (i in names.indices) {
            val name = names[i]
            val granted = flags != null && i < flags.size &&
                (flags[i] and PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0
            var dangerous = false
            var group = ""
            runCatching {
                val pi = pm.getPermissionInfo(name, 0)
                dangerous =
                    (pi.protectionLevel and PermissionInfo.PROTECTION_DANGEROUS) != 0
                @Suppress("DEPRECATION")
                group = pi.group ?: ""
            }
            out.add(
                mapOf(
                    "name" to name,
                    "granted" to granted,
                    "dangerous" to dangerous,
                    "group" to group
                )
            )
        }
        out.sortWith(
            compareByDescending<Map<String, Any?>> {
                (it["dangerous"] as? Boolean) ?: false
            }.thenByDescending { (it["granted"] as? Boolean) ?: false }
                .thenBy { (it["name"] as? String) ?: "" }
        )
        return out
    }

    /**
     * The certificate the installed app is actually signed with. Certificate
     * rotation is reported separately, so a rotated key is not mistaken for a
     * different (re-packaged) app.
     */
    private fun appSignature(packageName: String): Map<String, Any?>? {
        val pm = context.packageManager
        val base = packageInfo(packageName, 0) ?: return null
        val app = base.applicationInfo
        val certs = ArrayList<Map<String, Any?>>()
        var multipleSigners = false
        var rotated = false
        if (Build.VERSION.SDK_INT >= 28) {
            val signing = packageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES
            )?.signingInfo
            if (signing != null) {
                multipleSigners = signing.hasMultipleSigners()
                rotated = signing.hasPastSigningCertificates()
                signing.apkContentsSigners?.forEach { certs.add(certInfo(it)) }
            }
        } else {
            @Suppress("DEPRECATION")
            val info = packageInfo(packageName, PackageManager.GET_SIGNATURES)
            @Suppress("DEPRECATION")
            info?.signatures?.forEach { certs.add(certInfo(it)) }
        }
        if (certs.isEmpty()) return null
        val current = certs.first()
        return mapOf(
            "packageName" to packageName,
            "appName" to runCatching { app?.loadLabel(pm)?.toString() ?: "" }
                .getOrDefault(""),
            "system" to (((app?.flags ?: 0) and ApplicationInfo.FLAG_SYSTEM) != 0),
            "count" to certs.size,
            "multipleSigners" to multipleSigners,
            "rotated" to rotated,
            "sha256" to (current["sha256"] ?: ""),
            "sha1" to (current["sha1"] ?: ""),
            "subject" to (current["subject"] ?: ""),
            "issuer" to (current["issuer"] ?: ""),
            "selfSigned" to (current["selfSigned"] ?: false),
            "notBefore" to (current["notBefore"] ?: 0L),
            "notAfter" to (current["notAfter"] ?: 0L),
            "certs" to certs
        )
    }

    private class AuditCandidate(
        val packageName: String,
        val appName: String,
        val isSystem: Boolean,
        val granted: Set<String>
    )

    private val auditPermissionGroups: List<Pair<String, List<String>>> = listOf(
        "microphone" to listOf("android.permission.RECORD_AUDIO"),
        "camera" to listOf("android.permission.CAMERA"),
        "location" to listOf(
            "android.permission.ACCESS_FINE_LOCATION",
            "android.permission.ACCESS_COARSE_LOCATION"
        ),
        "backgroundLocation" to listOf(
            "android.permission.ACCESS_BACKGROUND_LOCATION"
        ),
        "contacts" to listOf(
            "android.permission.READ_CONTACTS",
            "android.permission.WRITE_CONTACTS",
            "android.permission.GET_ACCOUNTS"
        ),
        "phone" to listOf(
            "android.permission.CALL_PHONE",
            "android.permission.READ_CALL_LOG",
            "android.permission.WRITE_CALL_LOG",
            "android.permission.READ_PHONE_STATE",
            "android.permission.ANSWER_PHONE_CALLS"
        ),
        "sms" to listOf(
            "android.permission.READ_SMS",
            "android.permission.RECEIVE_SMS",
            "android.permission.SEND_SMS",
            "android.permission.RECEIVE_MMS"
        ),
        "media" to listOf(
            "android.permission.READ_EXTERNAL_STORAGE",
            "android.permission.WRITE_EXTERNAL_STORAGE",
            "android.permission.READ_MEDIA_IMAGES",
            "android.permission.READ_MEDIA_VIDEO",
            "android.permission.READ_MEDIA_AUDIO",
            "android.permission.MANAGE_EXTERNAL_STORAGE"
        ),
        "calendar" to listOf(
            "android.permission.READ_CALENDAR",
            "android.permission.WRITE_CALENDAR"
        ),
        "sensors" to listOf("android.permission.BODY_SENSORS"),
        "notifications" to listOf("android.permission.POST_NOTIFICATIONS")
    )

    private val auditOps: List<Pair<String, String>> = listOf(
        "overlay" to AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW,
        // "android:request_install_packages" has no public constant, but app-ops
        // are addressed by name, so the literal selects the same op.
        "installPackages" to "android:request_install_packages",
        "writeSettings" to AppOpsManager.OPSTR_WRITE_SETTINGS,
        "usageAccess" to AppOpsManager.OPSTR_GET_USAGE_STATS
    )

    /**
     * Who can do the sensitive things: apps holding each dangerous permission,
     * apps with a special app-op granted, the enabled notification listeners
     * and accessibility services, and apps exempt from battery optimisation.
     *
     * One flat list of capabilities, in a fixed order; the screen supplies the
     * localized names so the ids stay stable.
     */
    private fun permissionAudit(): Map<String, Any?> {
        val candidates = auditCandidates()
        val capabilities = ArrayList<Map<String, Any?>>()

        for ((id, permissions) in auditPermissionGroups) {
            val hits = candidates.filter { c ->
                permissions.any { c.granted.contains(it) }
            }
            if (hits.isEmpty()) continue
            capabilities.add(
                mapOf("id" to id, "apps" to hits.map { auditEntry(it, "") })
            )
        }

        for ((id, op) in auditOps) {
            val hits = candidates.filter { opAllowed(op, it.packageName) }
            if (hits.isEmpty()) continue
            capabilities.add(
                mapOf("id" to id, "apps" to hits.map { auditEntry(it, "") })
            )
        }

        secureComponentHits(
            // Settings.Secure.ENABLED_NOTIFICATION_LISTENERS is hidden API; the
            // setting itself is a plain string.
            "enabled_notification_listeners",
            candidates
        )?.let {
            if (it.isNotEmpty()) {
                capabilities.add(mapOf("id" to "notificationAccess", "apps" to it))
            }
        }
        secureComponentHits(
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            candidates
        )?.let {
            if (it.isNotEmpty()) {
                capabilities.add(mapOf("id" to "accessibility", "apps" to it))
            }
        }

        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (power != null) {
            val hits = candidates.filter {
                runCatching { power.isIgnoringBatteryOptimizations(it.packageName) }
                    .getOrDefault(false)
            }
            if (hits.isNotEmpty()) {
                capabilities.add(
                    mapOf(
                        "id" to "batteryUnrestricted",
                        "apps" to hits.map { auditEntry(it, "") }
                    )
                )
            }
        }

        return mapOf("capabilities" to capabilities)
    }

    private fun auditEntry(c: AuditCandidate, note: String): Map<String, Any?> =
        mapOf(
            "packageName" to c.packageName,
            "appName" to c.appName,
            "isSystem" to c.isSystem,
            "note" to note
        )

    /**
     * Apps worth auditing: every non-system package, plus system packages that
     * have a launcher entry. Names come along so the screen needs no lookups.
     */
    private fun auditCandidates(): List<AuditCandidate> {
        val pm = context.packageManager
        val flags = PackageManager.GET_PERMISSIONS
        val infos = if (Build.VERSION.SDK_INT >= 33) {
            pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getInstalledPackages(flags)
        }
        val launchers = launcherPackages()
        val out = ArrayList<AuditCandidate>()
        for (info in infos) {
            val app = info.applicationInfo ?: continue
            val isSystem = (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (isSystem && !launchers.contains(info.packageName)) continue
            val granted = HashSet<String>()
            val names = info.requestedPermissions
            val permFlags = info.requestedPermissionsFlags
            if (names != null) {
                for (i in names.indices) {
                    if (permFlags != null && i < permFlags.size &&
                        (permFlags[i] and PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0
                    ) {
                        granted.add(names[i])
                    }
                }
            }
            out.add(
                AuditCandidate(
                    info.packageName,
                    runCatching { app.loadLabel(pm).toString() }
                        .getOrDefault(info.packageName),
                    isSystem,
                    granted
                )
            )
        }
        out.sortBy { it.appName.lowercase(Locale.getDefault()) }
        return out
    }

    /**
     * Enabled components from a `Settings.Secure` colon-separated list, as
     * audit entries. Returns null when the setting is unset.
     */
    private fun secureComponentHits(
        setting: String,
        candidates: List<AuditCandidate>
    ): List<Map<String, Any?>>? {
        val raw = runCatching {
            Settings.Secure.getString(context.contentResolver, setting)
        }.getOrNull()
        if (raw.isNullOrBlank()) return null
        val byPackage = LinkedHashMap<String, MutableList<String>>()
        for (part in raw.split(':')) {
            val component = ComponentName.unflattenFromString(part.trim()) ?: continue
            byPackage.getOrPut(component.packageName) { ArrayList() }
                .add(component.className)
        }
        val out = ArrayList<Map<String, Any?>>()
        for ((pkgName, classes) in byPackage) {
            val known = candidates.firstOrNull { it.packageName == pkgName }
            val label = known?.appName ?: runCatching {
                context.packageManager
                    .getApplicationLabel(
                        context.packageManager.getApplicationInfo(pkgName, 0)
                    ).toString()
            }.getOrDefault(pkgName)
            out.add(
                mapOf(
                    "packageName" to pkgName,
                    "appName" to label,
                    "isSystem" to (known?.isSystem ?: true),
                    "note" to classes.joinToString(", ") { it.substringAfterLast('.') }
                )
            )
        }
        out.sortBy { (it["appName"] as? String)?.lowercase(Locale.getDefault()) }
        return out
    }

    /** Installed apps the user would recognise (see [auditCandidates]). */
    private fun visibleAppInfos(): List<ApplicationInfo> {
        val pm = context.packageManager
        val all = if (Build.VERSION.SDK_INT >= 33) {
            pm.getInstalledApplications(
                PackageManager.ApplicationInfoFlags.of(0L)
            )
        } else {
            @Suppress("DEPRECATION")
            pm.getInstalledApplications(0)
        }
        val launchers = launcherPackages()
        return all.filter { info ->
            val isSystem = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            !isSystem || launchers.contains(info.packageName)
        }
    }

    /** Packages that have a launcher entry, in one query. */
    private fun launcherPackages(): Set<String> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = if (Build.VERSION.SDK_INT >= 33) {
            pm.queryIntentActivities(
                intent,
                PackageManager.ResolveInfoFlags.of(0L)
            )
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(intent, 0)
        }
        val out = HashSet<String>()
        for (r in resolved) r.activityInfo?.packageName?.let { out.add(it) }
        return out
    }

    private fun packageInfo(packageName: String, extraFlags: Int): PackageInfo? =
        runCatching {
            val pm = context.packageManager
            if (Build.VERSION.SDK_INT >= 33) {
                pm.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(extraFlags.toLong())
                )
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(packageName, extraFlags)
            }
        }.getOrNull()

    /** Battery level, charging state and free space of the data volume. */
    private fun deviceStatus(): Map<String, Any?> {
        val battery = context.getSystemService(Context.BATTERY_SERVICE)
            as? BatteryManager
        val level = runCatching {
            battery?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        }.getOrDefault(-1)
        val charging = runCatching { battery?.isCharging ?: false }
            .getOrDefault(false)
        val stat = runCatching { StatFs(context.filesDir.absolutePath) }
            .getOrNull()
        // RAM (no permission) and the next alarm (public API) ride along: the
        // tiles that show them wake up with the same call.
        val memory = ActivityManager.MemoryInfo()
        runCatching {
            (context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)
                ?.getMemoryInfo(memory)
        }
        val alarm = runCatching {
            (context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager)
                ?.nextAlarmClock
        }.getOrNull()
        // Battery temperature comes from the sticky battery broadcast (tenths
        // of a degree, no permission).
        val temperature = runCatching {
            context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                ?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
        }.getOrDefault(-1)
        return mapOf(
            "level" to level,
            "charging" to charging,
            "freeBytes" to (stat?.availableBytes ?: 0L),
            "totalBytes" to (stat?.totalBytes ?: 0L),
            "memTotalBytes" to memory.totalMem,
            "memAvailBytes" to memory.availMem,
            "memLow" to memory.lowMemory,
            "alarmAt" to (alarm?.triggerTime ?: 0L),
            "uptimeMillis" to SystemClock.elapsedRealtime(),
            "batteryTempC" to (if (temperature > 0) temperature / 10.0 else -1.0),
            "torchOn" to torchState()
        )
    }

    /** Today's total foreground time across apps; needs usage access. */
    private fun screenTimeToday(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < 23) {
            return mapOf("permitted" to true, "totalMillis" to 0L)
        }
        if (!hasUsageAccess()) {
            return mapOf("permitted" to false, "totalMillis" to 0L)
        }
        val usage = context.getSystemService(Context.USAGE_STATS_SERVICE)
            as? UsageStatsManager
            ?: return mapOf("permitted" to true, "totalMillis" to 0L)
        val start = startOfToday()
        val stats = runCatching {
            usage.queryUsageStats(
                UsageStatsManager.INTERVAL_DAILY,
                start,
                System.currentTimeMillis()
            )
        }.getOrNull() ?: return mapOf("permitted" to true, "totalMillis" to 0L)
        // Daily buckets can repeat a package; keep the largest window per
        // package so today's time is not counted twice.
        val perPackage = HashMap<String, Long>()
        for (s in stats) {
            if (s.lastTimeUsed < start) continue
            val seen = perPackage[s.packageName] ?: 0L
            if (s.totalTimeInForeground > seen) {
                perPackage[s.packageName] = s.totalTimeInForeground
            }
        }
        return mapOf(
            "permitted" to true,
            "totalMillis" to perPackage.values.sum()
        )
    }

    /** This month's traffic, split mobile / Wi-Fi; needs usage access. */
    private fun trafficSummary(): Map<String, Any?> {
        fun empty(permitted: Boolean) = mapOf(
            "permitted" to permitted,
            "mobileBytes" to 0L,
            "wifiBytes" to 0L
        )
        if (Build.VERSION.SDK_INT < 23) return empty(true)
        if (!hasUsageAccess()) return empty(false)
        val stats = context.getSystemService(Context.NETWORK_STATS_SERVICE)
            as? NetworkStatsManager ?: return empty(true)
        val start = startOfMonth()
        val end = System.currentTimeMillis()
        fun query(type: Int): Long = runCatching {
            val bucket = stats.querySummaryForDevice(type, null, start, end)
            bucket.rxBytes + bucket.txBytes
        }.getOrDefault(0L)
        return mapOf(
            "permitted" to true,
            // A null subscriber id asks for every subscription, which is the
            // device total; some ROMs restrict the mobile query, in which case
            // it simply reports 0.
            "mobileBytes" to query(ConnectivityManager.TYPE_MOBILE),
            "wifiBytes" to query(ConnectivityManager.TYPE_WIFI)
        )
    }

    /** The back camera's torch, when it has one. */
    private fun torchCameraId(): String? = runCatching {
        val manager = context.getSystemService(Context.CAMERA_SERVICE)
            as? CameraManager ?: return null
        manager.cameraIdList.firstOrNull { id ->
            val chars = manager.getCameraCharacteristics(id)
            chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true &&
                chars.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
        }
    }.getOrNull()

    /**
     * Latest known torch state. Android has no public getter, so this is kept
     * up to date by [torchCallback] plus our own writes — which also means a
     * torch switched on from the notification shade shows up here.
     */
    @Volatile
    private var torchOn = false

    private fun registerTorchCallback() {
        runCatching {
            val manager = context.getSystemService(Context.CAMERA_SERVICE)
                as? CameraManager ?: return
            val id = torchCameraId() ?: return
            manager.registerTorchCallback(
                object : CameraManager.TorchCallback() {
                    override fun onTorchModeChanged(cameraId: String, enabled: Boolean) {
                        if (cameraId == id) torchOn = enabled
                    }
                },
                null
            )
        }
    }

    private fun torchState(): Boolean = torchOn

    /** Turns the torch on/off; returns the state afterwards. */
    private fun setTorch(on: Boolean): Boolean = runCatching {
        val manager = context.getSystemService(Context.CAMERA_SERVICE)
            as? CameraManager ?: return false
        val id = torchCameraId() ?: return false
        manager.setTorchMode(id, on)
        torchOn = on
        true
    }.getOrDefault(false)

    /** Device-wide bytes since boot, for a live throughput reading. */
    private fun trafficTotals(): Map<String, Any?> {
        val rx = TrafficStats.getTotalRxBytes()
        val tx = TrafficStats.getTotalTxBytes()
        val unsupported = TrafficStats.UNSUPPORTED.toLong()
        val supported = rx != unsupported && tx != unsupported
        return mapOf(
            "rx" to (if (rx > 0) rx else 0L),
            "tx" to (if (tx > 0) tx else 0L),
            "supported" to supported
        )
    }

    /** Opens the clock app for the next alarm, if one is set. */
    private fun openNextAlarm(): Boolean = runCatching {
        val alarm = (context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager)
            ?.nextAlarmClock ?: return false
        alarm.showIntent?.send()
        true
    }.getOrDefault(false)

    private fun startOfToday(): Long = java.util.Calendar.getInstance().apply {
        set(java.util.Calendar.HOUR_OF_DAY, 0)
        set(java.util.Calendar.MINUTE, 0)
        set(java.util.Calendar.SECOND, 0)
        set(java.util.Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun startOfMonth(): Long = java.util.Calendar.getInstance().apply {
        set(java.util.Calendar.DAY_OF_MONTH, 1)
        set(java.util.Calendar.HOUR_OF_DAY, 0)
        set(java.util.Calendar.MINUTE, 0)
        set(java.util.Calendar.SECOND, 0)
        set(java.util.Calendar.MILLISECOND, 0)
    }.timeInMillis
}
