package me.whynbnb.hamstapp

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat

/**
 * Hosts one installed web app (PWA), following the web app manifest.
 *
 * The manifest's `display` decides how much chrome is shown, which is the same
 * rule browsers use when a web app is installed:
 *
 *  - `fullscreen`  no UI at all, not even the status bar
 *  - `standalone`  no browser UI, status bar tinted with `theme_color`
 *  - `minimal-ui`  a small bar with the app name, back and reload
 *  - `browser`     (never hosted here — those entries go to the real browser)
 *
 * `background_color` paints the window while the first page loads and the
 * manifest icon sits on top of it, which is the launch experience the standard
 * describes. Navigation outside the manifest `scope` leaves the app for the
 * browser, so the user can see where they ended up — again as browsers do.
 *
 * The WebView keeps its own cookies and storage, so a login inside here does
 * not follow the user into Chrome and vice versa.
 */
class WebAppActivity : Activity() {

    private lateinit var webView: WebView
    private lateinit var progress: ProgressBar
    private lateinit var splash: View
    private var topBar: View? = null
    private var urlBar: View? = null
    private var urlText: TextView? = null
    private var currentUrl = ""

    private var display = "standalone"
    private var themeColor = 0
    private var backgroundColor = 0
    private var scope = ""
    private var startUrl = ""
    private var appName = ""
    private var browserPackage = ""
    private var hideStatusBar = false

    /** The view the page lives in; its background paints the status-bar strip. */
    private var rootView: View? = null

    /** The retry / browser panel currently over the page, if any. */
    private var failureView: View? = null

    /** The main frame already reported an error, so a later onPageFinished must
     *  not hide the failure panel and leave the user on a blank page. */
    private var loadFailed = false

    /** The renderer is gone: the WebView may not be touched any more. */
    private var rendererGone = false

    /** When the current main-frame load started (milliseconds), for timing and
     *  for the "it never finishes" timeout. */
    private var loadStartedAt = 0L

    private val timeoutHandler = Handler(Looper.getMainLooper())
    private var loadTimeout: Runnable? = null

    /** Script errors recorded for this window; sites can emit a lot of them. */
    private var consoleErrors = 0

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A window that cannot be built must not take the whole app with it:
        // report it and hand the site to a browser instead of a dead end.
        try {
            setup()
        } catch (t: Throwable) {
            log("窗口初始化失败 · ${describe(t)}", "error")
            fallBackToBrowser("窗口初始化失败")
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setup() {
        val intent = intent
        startUrl = intent.getStringExtra(EXTRA_URL) ?: ""
        appName = intent.getStringExtra(EXTRA_NAME) ?: ""
        display = intent.getStringExtra(EXTRA_DISPLAY) ?: "standalone"
        scope = intent.getStringExtra(EXTRA_SCOPE) ?: ""
        browserPackage = intent.getStringExtra(EXTRA_BROWSER) ?: ""
        hideStatusBar = intent.getBooleanExtra(EXTRA_HIDE_STATUS_BAR, false)
        themeColor = intent.getIntExtra(EXTRA_THEME_COLOR, 0)
        backgroundColor = intent.getIntExtra(EXTRA_BACKGROUND_COLOR, 0)
        val iconBytes = intent.getByteArrayExtra(EXTRA_ICON)

        if (startUrl.isEmpty()) {
            log("窗口创建失败 · 没有网址", "error")
            finish()
            return
        }
        if (!startUrl.startsWith("http://") && !startUrl.startsWith("https://")) {
            // A relative address would be loaded as file:///… and fail with
            // ERR_ACCESS_DENIED; never put anything but the web in a web window.
            log("窗口创建失败 · 地址不是网页 · $startUrl", "error")
            finish()
            return
        }
        log(
            "窗口创建 · $appName · $startUrl · display=$display · " +
                "状态栏=${if (hideStatusBar) "隐藏" else "显示"} · " +
                "theme=${Integer.toHexString(themeColor)} · 图标=${iconBytes?.size ?: 0}B"
        )

        // This app targets a recent SDK, so on Android 15+ the window is drawn
        // under the system bars whether we ask for it or not; older versions are
        // told to do the same so both behave identically, and the insets are
        // applied by hand below.
        WindowCompat.setDecorFitsSystemWindows(window, false)

        if (display == "fullscreen") {
            window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        }

        val root = FrameLayout(this)
        rootView = root
        // With the bar hidden the page owns the screen and the window's own
        // background only shows while the page loads; with it visible the root's
        // background is the status-bar strip (see [tintStatusBar]).
        root.setBackgroundColor(
            if (hideStatusBar) {
                if (backgroundColor != 0) backgroundColor else Color.WHITE
            } else {
                Color.WHITE
            }
        )
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(
                bars.left,
                if (hideStatusBar) 0 else bars.top,
                bars.right,
                bars.bottom,
            )
            insets
        }

        webView = try {
            WebView(this)
        } catch (t: Throwable) {
            // The system WebView is missing, disabled, or its provider failed to
            // load — nothing in this window can work, but the site still can.
            log("系统 WebView 不可用 · ${describe(t)} · ${webViewProviderLabel()}", "error")
            fallBackToBrowser("系统 WebView 不可用")
            return
        }
        configure(webView)
        log("WebView · ${webViewProviderLabel()}")
        root.addView(
            webView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        if (display == "minimal-ui") {
            val bar = buildTopBar()
            topBar = bar
            root.addView(
                bar,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.TOP,
                ),
            )
            // Keep the page below the bar.
            (webView.layoutParams as FrameLayout.LayoutParams).topMargin = dp(44)
        }

        // The address bar appears whenever the page leaves the app's scope — the
        // standard's own rule for sign-in pages on another host: they stay in the
        // app window (so the session survives) but the user can see where they are.
        if (display != "minimal-ui") {
            val bar = buildUrlBar()
            urlBar = bar
            root.addView(
                bar,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.TOP,
                ),
            )
            bar.visibility = View.GONE
        }

        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            visibility = View.GONE
        }
        root.addView(
            progress,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(3),
                Gravity.TOP,
            ),
        )

        splash = buildSplash(iconBytes)
        root.addView(
            splash,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        setContentView(root)
        // Only now does the decor view exist: reading it earlier (which
        // getWindowInsetsController() does) throws a NullPointerException.
        applyStatusBar()
        applyTaskDescription(iconBytes)
        webView.loadUrl(startUrl)
    }

    /**
     * Names this window for the task switcher: the web app's own label and icon,
     * so it reads as that site rather than as this app.
     */
    private fun applyTaskDescription(iconBytes: ByteArray?) {
        val label = appName.ifEmpty { startUrl }
        setTitle(label)
        runCatching {
            val icon = iconBytes?.let { decodeSampled(it, dp(96)) }
            @Suppress("DEPRECATION")
            setTaskDescription(
                if (icon != null) {
                    android.app.ActivityManager.TaskDescription(label, icon, themeColor)
                } else {
                    android.app.ActivityManager.TaskDescription(label)
                }
            )
        }
    }

    /**
     * The status bar, in one of the two strategies the entry can pick: hidden so
     * the page owns the whole screen, or visible — in which case the insets
     * above keep the page from running into it and its strip is tinted to match
     * the page.
     */
    private fun applyStatusBar() {
        if (hideStatusBar) {
            if (Build.VERSION.SDK_INT >= 30) {
                window.insetsController?.hide(WindowInsets.Type.statusBars())
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN
            }
            return
        }
        tintStatusBar(themeColor)
    }

    /**
     * Paints the strip behind a visible status bar and picks icon colours that
     * can actually be read on it.
     *
     * The icon style follows the *resulting* colour, not the source of it: a
     * page with no theme colour leaves a white strip, and white-on-white is
     * exactly how the clock became unreadable.
     */
    private fun tintStatusBar(color: Int) {
        val bar = if (color != 0) color else Color.WHITE
        rootView?.setBackgroundColor(bar)
        // From API 35 the bar is drawn over the window and its colour is
        // ignored; there the root's background is what shows through.
        if (Build.VERSION.SDK_INT < 35) window.statusBarColor = bar
        setLightStatusBar(luminance(bar) > 0.6)
    }

    /**
     * Asks the page what colour the strip above it should be.
     *
     * The sample is taken from the top of the page — the element sitting right
     * under the status bar, walking up until something actually paints — because
     * that is what the eye compares the bar with. A page's `theme-color` (when
     * it applies to the current colour scheme) and the manifest's colour are the
     * fallbacks, since `body`'s own background often belongs to a container the
     * page never shows at the top.
     */
    private fun tintFromPage(view: WebView) {
        if (hideStatusBar) return
        runCatching {
            view.evaluateJavascript(SAMPLE_COLOR_JS) { value ->
                val parsed = parseCssColor(unquoteJs(value))
                if (parsed != 0) tintStatusBar(parsed)
            }
        }
    }

    /** A JS string result as plain text (`null` and quotes removed). */
    private fun unquoteJs(value: String?): String {
        val text = value ?: return ""
        if (text.isEmpty() || text == "null") return ""
        return text.trim().trim('"').trim()
    }

    /** CSS colour → ARGB, or 0 when it cannot be read. */
    private fun parseCssColor(raw: String): Int {
        val text = raw.trim().lowercase()
        if (text.isEmpty() || text == "transparent") return 0
        if (text.startsWith("#")) {
            val hex = text.substring(1)
            fun ok(length: Int) = Regex("^[0-9a-f]{$length}$").matches(hex)
            // #rgb and #rrggbb are opaque; only #rgba/#rrggbbaa carry alpha, and
            // only those need the CSS order (#rrggbbaa) turned into ARGB. Getting
            // this wrong swaps the channels — a dark green came out red.
            if (hex.length == 3 && ok(3)) {
                val doubled = hex.map { "$it$it" }.joinToString("")
                return (0xff shl 24) or doubled.toLong(16).toInt()
            }
            if (hex.length == 6 && ok(6)) {
                return (0xff shl 24) or hex.toLong(16).toInt()
            }
            val rgba = when {
                hex.length == 4 && ok(4) -> hex.map { "$it$it" }.joinToString("")
                hex.length == 8 && ok(8) -> hex
                else -> return 0
            }
            val value = rgba.toLongOrNull(16) ?: return 0
            return (((value and 0xff) shl 24) or (value shr 8)).toInt()
        }
        val match = Regex("^rgba?\\(([^)]*)\\)$").find(text) ?: return 0
        val parts = match.groupValues[1].split(',').map { it.trim() }
        if (parts.size < 3) return 0
        fun channel(s: String): Int? = if (s.endsWith("%")) {
            s.dropLast(1).toDoubleOrNull()?.let { (it * 255 / 100).toInt().coerceIn(0, 255) }
        } else {
            s.toDoubleOrNull()?.toInt()?.coerceIn(0, 255)
        }

        val r = channel(parts[0]) ?: return 0
        val g = channel(parts[1]) ?: return 0
        val b = channel(parts[2]) ?: return 0
        val a = if (parts.size >= 4) {
            val raw = parts[3]
            val alpha = raw.toDoubleOrNull() ?: 1.0
            (if (raw.endsWith("%")) alpha * 255 / 100 else alpha * 255)
                .toInt()
                .coerceIn(0, 255)
        } else {
            255
        }
        // A nearly transparent colour paints nothing: treat it as unusable so
        // the next source is tried.
        if (a < 128) return 0
        return (a shl 24) or (r shl 16) or (g shl 8) or b
    }

    /** The launch screen: manifest icon on the manifest's background colour. */
    private fun buildSplash(iconBytes: ByteArray?): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(if (backgroundColor != 0) backgroundColor else Color.WHITE)
        }
        if (iconBytes != null && iconBytes.isNotEmpty()) {
            decodeSampled(iconBytes, dp(96))?.let { bitmap ->
                column.addView(
                    ImageView(this).apply {
                        setImageBitmap(bitmap)
                        scaleType = ImageView.ScaleType.FIT_CENTER
                    },
                    LinearLayout.LayoutParams(dp(96), dp(96)),
                )
            }
        }
        if (appName.isNotEmpty()) {
            column.addView(
                TextView(this).apply {
                    text = appName
                    textSize = 16f
                    gravity = Gravity.CENTER
                    setTextColor(if (luminance(backgroundColor) > 0.6) Color.BLACK else Color.WHITE)
                    setPadding(0, dp(12), 0, 0)
                },
            )
        }
        return column
    }

    /**
     * Decodes [bytes] down to about [maxPx]: a launch icon must never cost the
     * memory of the full-size image a site ships (an 1024² apple-touch-icon is
     * 4 MB of bitmap), which is what used to take the app down on launch.
     */
    private fun decodeSampled(bytes: ByteArray, maxPx: Int): android.graphics.Bitmap? =
        runCatching {
            if (bytes.size > MAX_ICON_BYTES) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= maxPx &&
                bounds.outHeight / (sample * 2) >= maxPx
            ) {
                sample *= 2
            }
            BitmapFactory.decodeByteArray(
                bytes,
                0,
                bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample },
            )
        }.getOrNull()

    /** Only for `minimal-ui`: the standard keeps a small set of controls. */
    private fun buildTopBar(): View {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(if (themeColor != 0) themeColor else Color.BLACK)
            setPadding(dp(4), dp(4), dp(4), dp(4))
        }
        fun button(symbol: String, onClick: () -> Unit) {
            bar.addView(
                TextView(this).apply {
                    text = symbol
                    textSize = 18f
                    setTextColor(Color.WHITE)
                    gravity = Gravity.CENTER
                    setPadding(dp(10), dp(6), dp(10), dp(6))
                    setOnClickListener { onClick() }
                },
                LinearLayout.LayoutParams(dp(44), ViewGroup.LayoutParams.WRAP_CONTENT),
            )
        }
        button("←") { if (webView.canGoBack()) webView.goBack() else finish() }
        val title = TextView(this).apply {
            text = appName
            textSize = 15f
            maxLines = 1
            setTextColor(Color.WHITE)
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        bar.addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        button("⟳") { webView.reload() }
        return bar
    }

    /**
     * Address bar shown while the page is outside the app's scope: where the
     * user is, and a way out to a real browser. Kept minimal on purpose — it is
     * a context signal, not browser chrome.
     */
    private fun buildUrlBar(): View {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(if (themeColor != 0) themeColor else Color.BLACK)
            setPadding(dp(12), dp(6), dp(8), dp(6))
        }
        bar.addView(
            TextView(this).apply {
                text = "🌐"
                textSize = 14f
                setPadding(0, 0, dp(8), 0)
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        val urlView = TextView(this).apply {
            textSize = 12.5f
            maxLines = 1
            setTextColor(Color.WHITE)
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
            alpha = 0.9f
        }
        urlText = urlView
        bar.addView(
            urlView,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        bar.addView(
            TextView(this).apply {
                text = "浏览器"
                textSize = 13f
                setTextColor(Color.WHITE)
                setPadding(dp(10), dp(2), dp(10), dp(2))
                setOnClickListener { if (currentUrl.isNotEmpty()) openInBrowser(currentUrl) }
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        return bar
    }

    /**
     * Shows or hides the address bar for [url]: visible when the page is outside
     * the manifest scope (a sign-in host, an external page), hidden when it is
     * back inside the app.
     */
    private fun updateChrome(url: String) {
        currentUrl = url
        urlText?.text = Uri.parse(url).let { uri ->
            listOf(uri.host ?: "", uri.path ?: "").joinToString("")
        }
        val bar = urlBar ?: return
        val visible = !inScope(url)
        if (visible == (bar.visibility == View.VISIBLE)) return
        bar.visibility = if (visible) View.VISIBLE else View.GONE
        // Keep the page below the bar while it is shown.
        val params = webView.layoutParams as? FrameLayout.LayoutParams ?: return
        params.topMargin = if (visible) dp(38) else 0
        webView.requestLayout()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configure(view: WebView) {
        val settings = view.settings
        settings.javaScriptEnabled = true
        // Sites keep a login in storage, and web apps cache their shell there.
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.loadsImagesAutomatically = true
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true
        settings.setSupportZoom(true)
        settings.builtInZoomControls = false
        settings.displayZoomControls = false
        settings.mediaPlaybackRequiresUserGesture = true
        if (Build.VERSION.SDK_INT >= 21) {
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        }
        // The WebView user agent carries a "; wv" marker and no browser version
        // trail some login flows reject; dropping it makes the app look like the
        // mobile browser it is built on.
        settings.userAgentString = settings.userAgentString
            ?.replace("; wv", "")
            ?.replace(Regex(" Version/\\d+\\.\\d+"), "")

        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
        WebView.setWebContentsDebuggingEnabled(false)

        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest,
            ): Boolean {
                val target = request.url.toString()
                if (target.startsWith("http://") || target.startsWith("https://")) {
                    // Web pages stay in this window — sign-in hosts included: a
                    // login only works if it happens in the same cookie jar, and
                    // leaving the scope merely shows the address bar (the
                    // standard's rule for out-of-scope pages).
                    return false
                }
                // Anything that is not a web page belongs to its own app: mail,
                // phone numbers, a site's own app, an intent:// link.
                log("交给其他应用 · $target")
                openExternal(target)
                return true
            }

            override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                // A new main-frame load: the old failure no longer applies.
                loadFailed = false
                removeFailure()
                loadStartedAt = System.currentTimeMillis()
                log("开始加载 · $url")
                scheduleLoadTimeout()
                // Pretend to be the manifest's display mode: WebView reports
                // "browser", and sites that ask for standalone would otherwise
                // render their browser layout.
                runCatching { view.evaluateJavascript(displayModeShim(), null) }
                updateChrome(url)
            }

            override fun onPageFinished(view: WebView, url: String) {
                cancelLoadTimeout()
                val elapsed = if (loadStartedAt > 0) {
                    System.currentTimeMillis() - loadStartedAt
                } else {
                    0L
                }
                log(
                    if (loadFailed) {
                        "页面结束（已报告加载失败） · $url · ${elapsed}ms"
                    } else {
                        "页面加载完成 · $url · ${elapsed}ms"
                    },
                    if (loadFailed) "warn" else "info",
                )
                if (!loadFailed) {
                    // Only a page that actually loaded replaces the panel; an
                    // error page finishing must not hide it.
                    removeFailure()
                    if (splash.visibility == View.VISIBLE) splash.visibility = View.GONE
                }
                // The page may declare (or change) the colour it wants the
                // browser UI in; ask it now that there is a document.
                tintFromPage(view)
                // Recents is snapshotted when the task is first shown, which can
                // happen before the page is up: name it again now.
                applyTaskDescription(null)
                updateChrome(url)
            }

            override fun doUpdateVisitedHistory(
                view: WebView,
                url: String?,
                isReload: Boolean,
            ) {
                // Single-page apps change views without a page load.
                tintFromPage(view)
                if (url.isNullOrEmpty()) return
                val previous = currentUrl
                updateChrome(url)
                if (isReload) {
                    log("页面重载 · $url")
                } else if (url != previous && !inScope(url)) {
                    // A sign-in page on another host is exactly where a PWA
                    // appears to "stop working"; note it in the log.
                    log("离开应用范围 · $url（显示地址栏）")
                }
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (!request.isForMainFrame) return
                cancelLoadTimeout()
                loadFailed = true
                log(
                    "页面加载失败 · code=${error.errorCode} · ${error.description}" +
                        " · ${request.url}",
                    "warn",
                )
                showFailure("无法打开，请检查网络后重试", allowRetry = true)
            }

            override fun onReceivedHttpError(
                view: WebView,
                request: WebResourceRequest,
                errorResponse: WebResourceResponse,
            ) {
                if (!request.isForMainFrame) return
                // An HTTP error page may still be the site's own content, so it
                // is logged rather than replaced.
                log(
                    "页面返回 HTTP ${errorResponse.statusCode}" +
                        " · ${errorResponse.reasonPhrase} · ${request.url}",
                    "warn",
                )
            }

            override fun onReceivedSslError(
                view: WebView,
                handler: SslErrorHandler,
                error: SslError,
            ) {
                log("证书不被信任 · primary=${error.primaryError} · ${error.url}", "warn")
                // Never continue past a certificate error; say what happened.
                handler.cancel()
                loadFailed = true
                showFailure("网站证书有问题，已停止打开", allowRetry = false)
            }

            override fun onRenderProcessGone(
                view: WebView,
                detail: RenderProcessGoneDetail,
            ): Boolean {
                // The renderer crashed (or was reclaimed for memory). The
                // WebView cannot be used again, and touching it would take the
                // whole process down — this is a common "the PWA will not open"
                // cause, so it is logged with the reason.
                val crashed = Build.VERSION.SDK_INT >= 26 && detail.didCrash()
                rendererGone = true
                cancelLoadTimeout()
                log(
                    "渲染进程结束 · ${if (crashed) "崩溃" else "内存不足或被系统回收"}" +
                        " · 当前=$currentUrl · 起始=$startUrl",
                    "error",
                )
                runCatching { view.stopLoading() }
                runCatching { (view.parent as? ViewGroup)?.removeView(view) }
                runCatching { view.destroy() }
                showFailure("页面进程已停止，请重新打开", allowRetry = false)
                // Keep the process alive; Android would kill the app otherwise.
                return true
            }
        }

        view.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                progress.progress = newProgress
                progress.visibility = if (newProgress in 1..99) View.VISIBLE else View.GONE
            }

            // A page that fails to start usually says why in its own script
            // errors (a service worker that cannot register, a missing chunk).
            // Only errors, capped, so the in-app log stays readable.
            override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                if (message.messageLevel() != ConsoleMessage.MessageLevel.ERROR) {
                    return false
                }
                if (consoleErrors >= MAX_CONSOLE_ERRORS) return true
                consoleErrors++
                val where = message.sourceId().orEmpty().takeLast(80)
                log(
                    "页面脚本错误 · $where:${message.lineNumber()} · " +
                        message.message().take(240),
                    "error",
                )
                return true
            }

            // Some sign-in flows ask for a location; granting keeps them usable.
            override fun onGeolocationPermissionsShowPrompt(
                origin: String,
                callback: GeolocationPermissions.Callback,
            ) {
                callback.invoke(origin, true, false)
            }

            // Links opened with target="_blank" — a sign-in popup, typically —
            // load in this window instead of elsewhere: they must stay in the
            // same session, and the back button brings the user back.
            override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: android.os.Message,
            ): Boolean {
                val transport = resultMsg.obj as WebView.WebViewTransport
                val popup = WebView(this@WebAppActivity)
                popup.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        v: WebView,
                        request: WebResourceRequest,
                    ): Boolean {
                        log("新窗口链接改在本窗口打开 · ${request.url}")
                        v.stopLoading()
                        if (!rendererGone) webView.loadUrl(request.url.toString())
                        return true
                    }
                }
                transport.webView = popup
                resultMsg.sendToTarget()
                return true
            }

            override fun onCloseWindow(window: WebView) {
                // A popup that closes itself: back to whatever opened it.
                if (window !== webView) window.destroy()
                if (!rendererGone && webView.canGoBack()) webView.goBack()
            }
        }
        settings.setSupportMultipleWindows(true)
        settings.javaScriptCanOpenWindowsAutomatically = true
    }

    /**
     * `display-mode` media queries in the page. Only the display-mode queries
     * are answered differently; everything else is delegated untouched.
     */
    private fun displayModeShim(): String = """
        (function () {
          var mode = '$display';
          if (window.__hamstappDisplayMode) { window.__hamstappDisplayMode = mode; return; }
          window.__hamstappDisplayMode = mode;
          try {
            var original = window.matchMedia.bind(window);
            window.matchMedia = function (query) {
              var result = original(query);
              if (String(query).indexOf('display-mode') >= 0) {
                var wanted = String(query).match(/display-mode:\s*([a-z-]+)/);
                var matches = wanted ? wanted[1] === mode : false;
                Object.defineProperty(result, 'matches', { value: matches, configurable: true });
              }
              return result;
            };
          } catch (e) {}
        })();
    """.trimIndent()

    /** Inside the manifest scope means inside this window. */
    private fun inScope(target: String): Boolean {
        val targetUri = Uri.parse(target)
        if (scope.isNotEmpty()) {
            return target.startsWith(scope)
        }
        // No declared scope: the manifest's directory is the default scope.
        val start = Uri.parse(startUrl)
        return targetUri.host == start.host &&
            targetUri.path.orEmpty().startsWith(start.path.orEmpty().substringBeforeLast('/') + "/")
    }

    /** Opens [url] in the chosen browser, or whatever the system picks. */
    private fun openInBrowser(url: String): Boolean {
        // The browser the entry picked, if any; the system's choice otherwise.
        if (browserPackage.isNotEmpty()) {
            val targeted = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                setPackage(browserPackage)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (runCatching { startActivity(targeted) }.isSuccess) return true
        }
        return openExternal(url)
    }

    /**
     * Hands a link to whoever handles it: the browser for a web address, the
     * matching app for anything else (`mailto:`, `tel:`, a site's own app, an
     * `intent://` URL).
     */
    private fun openExternal(url: String): Boolean {
        val intent = if (url.startsWith("intent:")) {
            runCatching { Intent.parseUri(url, Intent.URI_INTENT_SCHEME) }.getOrNull()
        } else {
            Intent(Intent.ACTION_VIEW, Uri.parse(url))
        } ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            log("没人能处理这个链接 · $url", "warn")
            // Nothing to hand it to; keep it in this window when it is a page.
            if (url.startsWith("http") && !rendererGone && this::webView.isInitialized) {
                runCatching { webView.loadUrl(url) }
            }
            false
        } catch (t: Throwable) {
            log("交给其他应用失败 · $url · ${describe(t)}", "warn")
            false
        }
    }

    /**
     * When the window itself cannot work — a missing or disabled system
     * WebView, a failed setup — the site still belongs somewhere: hand it to a
     * browser and say so, instead of leaving the user with a flash and nothing.
     */
    private fun fallBackToBrowser(reason: String) {
        if (startUrl.isEmpty()) {
            log("$reason · 没有网址", "error")
            android.widget.Toast.makeText(
                this,
                "无法打开网页窗口",
                android.widget.Toast.LENGTH_SHORT,
            ).show()
            finish()
            return
        }
        val opened = openInBrowser(startUrl)
        log(
            "$reason · 改用浏览器${if (opened) "" else "失败"} · $startUrl",
            "warn",
        )
        android.widget.Toast.makeText(
            this,
            if (opened) "网页窗口打不开，已改用浏览器" else "网页窗口打不开",
            android.widget.Toast.LENGTH_LONG,
        ).show()
        finish()
    }

    /**
     * Puts a retry / browser / close panel over the page.
     *
     * [allowRetry] is false when the WebView itself can no longer load anything
     * (a dead renderer, a rejected certificate), so the panel does not offer an
     * action that cannot work.
     */
    private fun showFailure(message: String, allowRetry: Boolean) {
        removeFailure()
        // Deliberately not `loadFailed`: a timeout is only a guess, and if the
        // page does finish later onPageFinished should take the panel away.
        if (this::splash.isInitialized) splash.visibility = View.GONE
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(if (backgroundColor != 0) backgroundColor else Color.WHITE)
        }
        column.addView(
            TextView(this).apply {
                text = message
                textSize = 15f
                setPadding(dp(24), 0, dp(24), dp(12))
                gravity = Gravity.CENTER
            },
        )
        fun action(label: String, color: Int = Color.parseColor("#1a73e8"), run: () -> Unit) {
            column.addView(
                TextView(this).apply {
                    text = label
                    textSize = 16f
                    setTextColor(color)
                    gravity = Gravity.CENTER
                    setPadding(dp(24), dp(8), dp(24), dp(8))
                    setOnClickListener { run() }
                },
            )
        }
        if (allowRetry) action("重试") { retryLoad() }
        action("用浏览器打开") {
            openInBrowser(if (currentUrl.isNotEmpty()) currentUrl else startUrl)
        }
        action("关闭", Color.GRAY) { finish() }
        failureView = column
        runCatching {
            (findViewById<View>(android.R.id.content) as ViewGroup).addView(
                column,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
        }
    }

    private fun removeFailure() {
        failureView?.let { view ->
            runCatching { (view.parent as? ViewGroup)?.removeView(view) }
        }
        failureView = null
    }

    private fun retryLoad() {
        removeFailure()
        if (rendererGone || !this::webView.isInitialized) return
        loadFailed = false
        splash.visibility = View.VISIBLE
        loadStartedAt = System.currentTimeMillis()
        scheduleLoadTimeout()
        runCatching { webView.loadUrl(startUrl) }
            .onFailure { log("重新加载失败 · ${describe(it)}", "error") }
    }

    /**
     * A page that neither finishes nor reports an error (a redirect loop, a
     * stalled network, a WebView that hangs) would otherwise leave the splash
     * up forever — the exact "the PWA will not open" report. Note it in the log
     * and offer the browser instead.
     */
    private fun scheduleLoadTimeout() {
        cancelLoadTimeout()
        val runnable = Runnable {
            loadTimeout = null
            val waited = if (loadStartedAt > 0) {
                (System.currentTimeMillis() - loadStartedAt) / 1000
            } else {
                LOAD_TIMEOUT_MS / 1000
            }
            log(
                "加载超时 · ${waited}s · 进度=${if (this::progress.isInitialized) progress.progress else 0}%" +
                    " · 当前=$currentUrl · 起始=$startUrl",
                "warn",
            )
            if (!loadFailed && !rendererGone) {
                showFailure("打开超时，请检查网络后重试", allowRetry = true)
            }
        }
        loadTimeout = runnable
        timeoutHandler.postDelayed(runnable, LOAD_TIMEOUT_MS)
    }

    private fun cancelLoadTimeout() {
        loadTimeout?.let { timeoutHandler.removeCallbacks(it) }
        loadTimeout = null
    }

    /** One line in the in-app log; a no-op unless the user turned logging on. */
    private fun log(text: String, level: String = "info") {
        NotificationStore.addEvent(
            "网页应用 · $text",
            level = level,
            module = "launch",
        )
    }

    /** Class, message and the first few frames of [t], for a log line. */
    private fun describe(t: Throwable): String {
        val head = "${t.javaClass.simpleName}: ${t.message}"
        val frames = t.stackTrace.take(4).joinToString(" ← ") {
            "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}"
        }
        return if (frames.isEmpty()) head else "$head · $frames"
    }

    /** The system WebView provider, so a broken one can be spotted in the log. */
    private fun webViewProviderLabel(): String {
        val sdk = "SDK ${Build.VERSION.SDK_INT}"
        if (Build.VERSION.SDK_INT < 26) return sdk
        val pkg = runCatching { WebView.getCurrentWebViewPackage() }.getOrNull()
            ?: return "未找到 WebView 提供者 · $sdk"
        return "${pkg.packageName} ${pkg.versionName ?: "?"} · $sdk"
    }

    override fun onBackPressed() {
        if (!rendererGone && this::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
            return
        }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    override fun onDestroy() {
        cancelLoadTimeout()
        if (!rendererGone && this::webView.isInitialized) {
            runCatching { webView.destroy() }
        }
        super.onDestroy()
    }

    private fun setLightStatusBar(light: Boolean) {
        // Touching the decor view before the content is set throws; a window
        // that cannot be tinted is not worth failing over anyway.
        if (window.decorView == null) return
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.setSystemBarsAppearance(
                if (light) WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS else 0,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS,
            )
        } else if (Build.VERSION.SDK_INT >= 23) {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                if (light) View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR else 0
        }
    }

    private fun luminance(color: Int): Double {
        if (color == 0) return 0.0
        val r = Color.red(color) / 255.0
        val g = Color.green(color) / 255.0
        val b = Color.blue(color) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_NAME = "name"
        const val EXTRA_DISPLAY = "display"
        const val EXTRA_SCOPE = "scope"
        const val EXTRA_BROWSER = "browserPackage"
        const val EXTRA_HIDE_STATUS_BAR = "hideStatusBar"
        const val EXTRA_THEME_COLOR = "themeColor"
        const val EXTRA_BACKGROUND_COLOR = "backgroundColor"
        const val EXTRA_ICON = "icon"

        /** Beyond this an icon is refused outright; the splash does without. */
        const val MAX_ICON_BYTES = 512 * 1024

        /** How long a main-frame load may stay unfinished before it is called a
         *  timeout (milliseconds). Slow networks still get a real chance. */
        const val LOAD_TIMEOUT_MS = 30_000L

        /** Script errors kept per window; beyond this they are only noise. */
        const val MAX_CONSOLE_ERRORS = 20

        /**
         * What colour the strip under the status bar should be.
         *
         * 1. the element at the very top of the page that actually paints — what
         *    sits directly below the bar, so the two line up;
         * 2. the page's `theme-color`, but only the entry that matches the
         *    current colour scheme (sites ship one per scheme);
         * 3. nothing, leaving the manifest colour (or white) in place.
         */
        val SAMPLE_COLOR_JS = """
            (function () {
              function painted(color) {
                if (!color) return false;
                if (color === 'transparent' || color === 'rgba(0, 0, 0, 0)') return false;
                var m = color.match(/rgba?\(([^)]+)\)/);
                if (!m) return true;
                var parts = m[1].split(',');
                return parts.length < 4 || parseFloat(parts[3]) >= 0.5;
              }
              // Let the CSSOM normalise whatever the site wrote (hex, a colour
              // name, hsl…) into rgb() form, so the native side only has one
              // shape to read.
              function canonical(color) {
                try {
                  var probe = document.createElement('span');
                  probe.style.color = color;
                  return probe.style.color || color;
                } catch (e) {
                  return color;
                }
              }
              try {
                var x = Math.floor(window.innerWidth / 2);
                var el = document.elementFromPoint(x, 1) ||
                  document.body || document.documentElement;
                while (el) {
                  var bg = getComputedStyle(el).backgroundColor || '';
                  if (painted(bg)) return bg;
                  el = el.parentElement;
                }
              } catch (e) {}
              try {
                var metas = document.querySelectorAll('meta[name="theme-color"]');
                for (var i = 0; i < metas.length; i++) {
                  var media = metas[i].getAttribute('media');
                  if (media && !window.matchMedia(media).matches) continue;
                  if (metas[i].content) return canonical(metas[i].content);
                }
              } catch (e) {}
              return '';
            })();
        """.trimIndent()

        /** `WindowInsets` is only touched where it exists. */
        const val TAG = "WebAppActivity"
    }
}
