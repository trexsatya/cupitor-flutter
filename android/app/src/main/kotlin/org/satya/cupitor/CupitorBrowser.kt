package org.satya.cupitor

import android.app.Activity
import android.app.Dialog
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Message
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.Toast
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener
import java.io.IOException

/** A native browser surface with its own chrome and no page-to-app JS bridge. */
internal class CupitorBrowser(
    private val activity: Activity,
    private val captureScript: () -> String,
    private val onCapture: (String) -> Unit,
) {
    private class Tab(val view: WebView) {
        var committedUrl: String? = null
        var loaded = false
        var navigation = 0
    }

    private val tabs = mutableListOf<Tab>()
    private var active: Tab? = null
    private var capturing: Tab? = null
    private val dialog = object : Dialog(activity, android.R.style.Theme_Material_Light_NoActionBar) {
        @Deprecated("Handles the browser's history before returning to the study surface")
        override fun onBackPressed() {
            val view = active?.view
            if (view?.canGoBack() == true) view.goBack() else hideForStudy()
        }
    }
    private val content = FrameLayout(activity)
    private val address = EditText(activity).apply {
        hint = "Web address"
        isSingleLine = true
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        imeOptions = EditorInfo.IME_ACTION_GO
        setSelectAllOnFocus(true)
        setOnEditorActionListener { _, action, event ->
            if (action == EditorInfo.IME_ACTION_GO ||
                (event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)
            ) {
                navigateFromAddress()
                true
            } else false
        }
    }
    private val capture = button("Capture", ::captureSubtitles)
    private val menu = button("⋮", ::showMenu).apply { contentDescription = "Browser menu" }

    init {
        val bar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(address, LinearLayout.LayoutParams(0, -2, 1f))
            addView(capture)
            addView(menu)
        }
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            isFocusableInTouchMode = true
            addView(bar)
            addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        if (Build.VERSION.SDK_INT >= 30) {
            root.setOnApplyWindowInsetsListener { view, insets ->
                val edge = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                view.setPadding(edge.left, edge.top, edge.right, edge.bottom)
                insets
            }
        } else {
            root.fitsSystemWindows = true
        }
        dialog.setContentView(root)
        dialog.setCanceledOnTouchOutside(false)
        @Suppress("DEPRECATION")
        dialog.window?.setSoftInputMode(
            WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or
                WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN
        )
    }

    fun resume() {
        if (dialog.isShowing) active?.view?.onResume()
    }

    fun pause() {
        active?.view?.onPause()
    }

    fun open(url: String?): Boolean {
        if (url != null && !isWebUrl(url)) return false
        if (url != null) {
            val existing = tabs.firstOrNull { it.view.url == url }
            if (existing != null) select(existing) else {
                if (tabs.size >= MAX_TABS) {
                    toast("Close a tab before opening another.")
                    return false
                }
                newTab(url)
            }
        } else if (active == null) {
            newTab(HOME)
        }
        dialog.show()
        dialog.window?.setLayout(-1, -1)
        resume()
        updateChrome()
        return true
    }

    fun destroy() {
        dialog.dismiss()
        content.removeAllViews()
        tabs.forEach { it.view.destroy() }
        tabs.clear()
        active = null
        capturing = null
    }

    private fun button(label: String, click: () -> Unit) = Button(activity).apply {
        text = label
        isAllCaps = false
        setOnClickListener { click() }
    }

    private fun newTab(url: String? = null): Tab {
        val view = WebView(activity)
        val tab = Tab(view)
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            setSupportMultipleWindows(true)
        }
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                request.isForMainFrame && !isWebUrl(request.url.toString()) && request.url.toString() != "about:blank"

            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                tab.navigation++
                tab.loaded = false
                tab.committedUrl = null
                if (active === tab) updateChrome()
            }

            override fun onPageCommitVisible(view: WebView, url: String) {
                tab.committedUrl = url
                if (active === tab) {
                    address.clearFocus()
                    updateChrome()
                }
            }

            override fun onPageFinished(view: WebView, url: String) {
                if (view.url == url) {
                    tab.committedUrl = url
                    tab.loaded = true
                }
                if (active === tab) updateChrome()
            }

            override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
                if (tab.loaded) tab.committedUrl = url
                if (active === tab) updateChrome()
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                close(tab)
                return true
            }
        }
        view.webChromeClient = object : WebChromeClient() {
            override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
                if (!isUserGesture || tabs.size >= MAX_TABS) return false
                val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
                transport.webView = newTab().view
                resultMsg.sendToTarget()
                return true
            }

            override fun onCloseWindow(window: WebView) = close(tab)
        }
        tabs.add(tab)
        select(tab)
        if (url != null) view.loadUrl(url)
        return tab
    }

    private fun select(tab: Tab) {
        if (active === tab) return
        active?.view?.onPause()
        content.removeAllViews()
        active = tab
        content.addView(tab.view, FrameLayout.LayoutParams(-1, -1))
        if (dialog.isShowing) tab.view.onResume() else tab.view.onPause()
        address.clearFocus()
        updateChrome()
    }

    private fun close(tab: Tab) {
        val index = tabs.indexOf(tab)
        if (index < 0) return
        tabs.removeAt(index)
        if (capturing === tab) capturing = null
        if (active === tab) {
            content.removeAllViews()
            active = null
            if (tabs.isEmpty()) hideForStudy() else select(tabs[index.coerceAtMost(tabs.lastIndex)])
        }
        tab.view.destroy()
    }

    private fun navigateFromAddress() {
        val input = address.text.toString().trim()
        val url = if ("://" in input) input else "https://$input"
        if (!isWebUrl(url)) {
            toast("Enter a valid HTTP or HTTPS address.")
            return
        }
        activity.getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(address.windowToken, 0)
        address.clearFocus()
        active?.view?.loadUrl(url)
    }

    private fun updateChrome() {
        val tab = active
        if (!address.hasFocus()) address.setText(tab?.committedUrl.orEmpty())
        capture.visibility = if (isFilmotUrl(tab?.committedUrl)) View.VISIBLE else View.GONE
        capture.isEnabled = tab?.loaded == true && capturing == null
    }

    private fun showMenu() {
        val tab = active ?: return
        PopupMenu(activity, menu).apply {
            this.menu.addSubMenu("Navigation").apply {
                add("Back").setEnabled(tab.view.canGoBack()).setOnMenuItemClickListener {
                    tab.view.goBack()
                    true
                }
                add("Forward").setEnabled(tab.view.canGoForward()).setOnMenuItemClickListener {
                    tab.view.goForward()
                    true
                }
                add("Reload").setOnMenuItemClickListener {
                    tab.view.reload()
                    true
                }
            }
            this.menu.addSubMenu("Tabs (${tabs.size})").apply {
                add("New tab").setEnabled(tabs.size < MAX_TABS).setOnMenuItemClickListener {
                    newTab(HOME)
                    true
                }
                add("Close current tab").setOnMenuItemClickListener {
                    close(tab)
                    true
                }
                for (item in tabs) {
                    val label = item.view.title?.takeIf { it.isNotBlank() } ?: item.committedUrl ?: "New tab"
                    add(label).setCheckable(true).setChecked(item === tab).setOnMenuItemClickListener {
                        select(item)
                        true
                    }
                }
            }
            this.menu.add("Return to study").setOnMenuItemClickListener {
                hideForStudy()
                true
            }
            show()
        }
    }

    private fun captureSubtitles() {
        val tab = active ?: return
        val url = tab.committedUrl
        if (!tab.loaded || !isFilmotUrl(url) || tab.view.url != url || capturing != null) return
        val navigation = tab.navigation
        val script = try {
            captureScript()
        } catch (_: IOException) {
            toast("The Filmot capture script could not be loaded.")
            return
        }
        capturing = tab
        updateChrome()
        tab.view.evaluateJavascript(script) { encoded ->
            if (capturing !== tab) return@evaluateJavascript
            capturing = null
            updateChrome()
            if (active !== tab || !dialog.isShowing || !tab.loaded ||
                tab.navigation != navigation || tab.committedUrl != url || tab.view.url != url
            ) return@evaluateJavascript
            val payload = try {
                (JSONTokener(encoded ?: "null").nextValue() as? String)?.let(::JSONObject)
            } catch (_: JSONException) { null }
            if (payload == null || (payload.optJSONArray("lines")?.length() ?: 0) == 0) {
                toast("No Filmot subtitles yet. Open a video with captions and try again.")
                return@evaluateJavascript
            }
            hideForStudy()
            onCapture(payload.toString())
        }
    }

    private fun hideForStudy() {
        pause()
        capturing = null
        dialog.hide()
    }

    private fun toast(message: String) = Toast.makeText(activity, message, Toast.LENGTH_SHORT).show()

    companion object {
        private const val HOME = "https://www.google.com/"
        private const val MAX_TABS = 12

        fun isWebUrl(value: String?): Boolean {
            if (value.isNullOrBlank() || value.any { it.isWhitespace() || it == '\\' }) return false
            val uri = Uri.parse(value)
            return uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.userInfo == null
        }

        fun isFilmotUrl(value: String?): Boolean {
            if (!isWebUrl(value)) return false
            val host = Uri.parse(value).host?.lowercase() ?: return false
            return host == "filmot.com" || host.endsWith(".filmot.com")
        }
    }
}
