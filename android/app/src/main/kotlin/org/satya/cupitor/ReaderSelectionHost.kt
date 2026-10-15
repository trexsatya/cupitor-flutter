package org.satya.cupitor

import android.app.Activity
import android.content.Context
import android.graphics.Rect
import android.net.Uri
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.FrameLayout

/** Keeps WebView selection handles, while Flutter supplies the reader toolbar. */
internal class ReaderSelectionHost(context: Context) : FrameLayout(context) {
    override fun startActionModeForChild(
        originalView: View,
        callback: ActionMode.Callback,
        type: Int,
    ): ActionMode? {
        // The browser, dictionary dialogs and editable text keep their menus.
        // loadHtmlString uses this base URL for both EPUB and DOCX chapters.
        val url = (originalView as? WebView)?.url?.let(Uri::parse)
        val reader = url?.scheme == "cupitor-epub" && url.host == "chapter"
        val wrapped = if (reader && type == ActionMode.TYPE_FLOATING) {
            ReaderSelectionCallback(callback)
        } else {
            callback
        }
        return super.startActionModeForChild(originalView, wrapped, type)
    }

    companion object {
        fun install(activity: Activity) {
            val content = activity.findViewById(android.R.id.content) as? ViewGroup ?: return
            if (content.childCount != 1 || content.getChildAt(0) is ReaderSelectionHost) return
            val flutterView = content.getChildAt(0)
            val params = flutterView.layoutParams
            content.removeView(flutterView)
            val host = ReaderSelectionHost(activity)
            host.addView(flutterView, LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
            ))
            content.addView(host, params)
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
