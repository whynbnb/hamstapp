package me.whynbnb.hamstapp

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsetsController
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

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

    private var display = "standalone"
    private var themeColor = 0
    private var backgroundColor = 0
    private var scope = ""
    private var startUrl = ""
    private var appName = ""
    private var browserPackage = ""

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A window that cannot be built must not take the whole app with it:
        // report it, say so, and close.
        try {
            setup()
        } catch (t: Throwable) {
            NotificationStore.addEvent(
                "网页应用 · 窗口初始化失败 · ${t.javaClass.simpleName}: ${t.message}"
            )
            android.widget.Toast.makeText(
                this,
                "无法打开网页窗口",
                android.widget.Toast.LENGTH_SHORT,
            ).show()
            finish()
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
        themeColor = intent.getIntExtra(EXTRA_THEME_COLOR, 0)
        backgroundColor = intent.getIntExtra(EXTRA_BACKGROUND_COLOR, 0)
        val iconBytes = intent.getByteArrayExtra(EXTRA_ICON)

        if (startUrl.isEmpty()) {
            finish()
            return
        }
        NotificationStore.addEvent(
            "网页应用 · 窗口创建 · $appName · $startUrl · display=$display · " +
                "theme=${Integer.toHexString(themeColor)} · 图标=${iconBytes?.size ?: 0}B"
        )

        if (display == "fullscreen") {
            window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        }

        val root = FrameLayout(this)
        root.setBackgroundColor(if (backgroundColor != 0) backgroundColor else Color.WHITE)

        webView = WebView(this)
        configure(webView)
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
        window.statusBarColor = if (themeColor != 0) themeColor else Color.BLACK
        setLightStatusBar(themeColor != 0 && luminance(themeColor) > 0.6)
        webView.loadUrl(startUrl)
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
                if (inScope(target)) return false
                // Out-of-scope navigation is where the browser takes over, the
                // same way an installed web app shows browser UI there.
                openInBrowser(target)
                return true
            }

            override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                // Pretend to be the manifest's display mode: WebView reports
                // "browser", and sites that ask for standalone would otherwise
                // render their browser layout.
                view.evaluateJavascript(displayModeShim(), null)
            }

            override fun onPageFinished(view: WebView, url: String) {
                if (splash.visibility == View.VISIBLE) splash.visibility = View.GONE
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: android.webkit.WebResourceError,
            ) {
                if (!request.isForMainFrame) return
                showLoadFailure()
            }
        }

        view.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                progress.progress = newProgress
                progress.visibility = if (newProgress in 1..99) View.VISIBLE else View.GONE
            }

            // Some sign-in flows ask for a location; granting keeps them usable.
            override fun onGeolocationPermissionsShowPrompt(
                origin: String,
                callback: GeolocationPermissions.Callback,
            ) {
                callback.invoke(origin, true, false)
            }

            // Links opened with target="_blank" belong to the browser.
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
                        openInBrowser(request.url.toString())
                        return true
                    }
                }
                transport.webView = popup
                resultMsg.sendToTarget()
                return true
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

    private fun openInBrowser(url: String) {
        // The browser the entry picked, if any; the system's choice otherwise.
        if (browserPackage.isNotEmpty()) {
            val targeted = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                setPackage(browserPackage)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (runCatching { startActivity(targeted) }.isSuccess) return
        }
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            // Nothing to hand it to; keep it in this window instead.
            webView.loadUrl(url)
        }
    }

    private fun showLoadFailure() {
        splash.visibility = View.GONE
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(if (backgroundColor != 0) backgroundColor else Color.WHITE)
        }
        column.addView(
            TextView(this).apply {
                text = getString(android.R.string.cancel)
                textSize = 14f
                gravity = Gravity.CENTER
                visibility = View.GONE
            },
        )
        column.addView(
            TextView(this).apply {
                text = "无法打开，请检查网络后重试"
                textSize = 15f
                setPadding(dp(24), 0, dp(24), dp(12))
                gravity = Gravity.CENTER
            },
        )
        column.addView(
            TextView(this).apply {
                text = "重试"
                textSize = 16f
                setTextColor(Color.parseColor("#1a73e8"))
                setPadding(dp(24), dp(8), dp(24), dp(8))
                setOnClickListener {
                    (this@WebAppActivity.findViewById<View>(android.R.id.content) as ViewGroup)
                        .removeView(column)
                    splash.visibility = View.VISIBLE
                    webView.loadUrl(startUrl)
                }
            },
        )
        (findViewById<View>(android.R.id.content) as ViewGroup).addView(
            column,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    override fun onBackPressed() {
        if (this::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
            return
        }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    override fun onDestroy() {
        if (this::webView.isInitialized) {
            webView.destroy()
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
        const val EXTRA_THEME_COLOR = "themeColor"
        const val EXTRA_BACKGROUND_COLOR = "backgroundColor"
        const val EXTRA_ICON = "icon"

        /** Beyond this an icon is refused outright; the splash does without. */
        const val MAX_ICON_BYTES = 512 * 1024

        /** `WindowInsets` is only touched where it exists. */
        const val TAG = "WebAppActivity"
    }
}
