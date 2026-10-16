package org.satya.cupitor

import android.app.Activity
import android.content.Context
import android.graphics.Rect
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.FrameLayout
import java.util.WeakHashMap

/** Keeps WebView selection handles, while Flutter supplies the reader toolbar. */
internal class ReaderSelectionHost(context: Context) : FrameLayout(context) {
    // Explicit native instances: loadHtmlString's base URL is not WebView.url
    // (the plugin passes a null history URL to loadDataWithBaseURL).
    // Weak keys allow disposed reader views to be collected without retaining
    // them for the lifetime of the activity.
    private val readers = WeakHashMap<WebView, Unit>()

    fun registerReader(webView: WebView) {
        readers[webView] = Unit
    }

    private fun isReaderSelection(originalView: View): Boolean {
        var view: View? = originalView
        while (view != null && view !== this) {
            // Some WebView implementations originate the request in a child.
            if (view is WebView) return readers.containsKey(view)
            view = view.parent as? View
        }
        return false
    }

    override fun startActionModeForChild(
        originalView: View,
        callback: ActionMode.Callback,
        type: Int,
    ): ActionMode? {
        // Browser and lookup WebViews are never registered as reader views.
        val wrapped = if (type == ActionMode.TYPE_FLOATING && isReaderSelection(originalView)) {
            ReaderSelectionCallback(callback)
        } else {
            callback
        }
        return super.startActionModeForChild(originalView, wrapped, type)
    }

    companion object {
        fun install(activity: Activity): ReaderSelectionHost? {
            val content = activity.findViewById(android.R.id.content) as? ViewGroup ?: return null
            if (content.childCount != 1) return null
            (content.getChildAt(0) as? ReaderSelectionHost)?.let { return it }
            val flutterView = content.getChildAt(0)
            val params = flutterView.layoutParams
            content.removeView(flutterView)
            val host = ReaderSelectionHost(activity)
            host.addView(flutterView, LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
            ))
            content.addView(host, params)
            return host
        }
    }
}

/** Do not finish/reject the ActionMode: Chromium would also clear selection. */
internal class ReaderSelectionCallback(
    private val delegate: ActionMode.Callback,
) : ActionMode.Callback2() {
    override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
        val created = delegate.onCreateActionMode(mode, menu)
        menu.clear()
        return created
    }

    override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {
        delegate.onPrepareActionMode(mode, menu)
        // WebView can recreate items when selection handles move.
        menu.clear()
        return true
    }

    override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean =
        delegate.onActionItemClicked(mode, item)

    override fun onDestroyActionMode(mode: ActionMode) = delegate.onDestroyActionMode(mode)

    override fun onGetContentRect(mode: ActionMode, view: View, outRect: Rect) {
        val positioned = delegate as? ActionMode.Callback2
        if (positioned != null) positioned.onGetContentRect(mode, view, outRect)
        else super.onGetContentRect(mode, view, outRect)
    }
}

