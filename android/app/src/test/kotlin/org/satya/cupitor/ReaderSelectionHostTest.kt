package org.satya.cupitor

import android.app.Activity
import android.content.Context
import android.graphics.Rect
import android.view.ActionMode
import android.view.Menu
import android.view.MenuInflater
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.PopupMenu
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 35], manifest = Config.NONE)
class ReaderSelectionHostTest {
    private lateinit var activity: Activity
    private lateinit var parent: RecordingParent
    private lateinit var host: ReaderSelectionHost

    @Before
    fun setUp() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        parent = RecordingParent(activity)
        host = ReaderSelectionHost(activity)
        parent.addView(host)
    }

    @Test
    fun registeredReaderWithBlankHistoryUrlKeepsSelectionAndClearsMenu() {
        val reader = webView("about:blank")
        host.registerReader(reader)
        val delegate = SelectionCallback()

        val mode = reader.startActionMode(delegate, ActionMode.TYPE_FLOATING)
        val callback = parent.callback!!
        assertNotSame(delegate, callback)
        assertSame(parent.mode, mode)
        assertSame(reader, parent.origin)
        assertTrue(callback.onCreateActionMode(mode!!, mode.menu))
        assertEquals(0, mode.menu.size())
        // Moving a handle can repopulate the menu; it must remain empty.
        assertTrue(callback.onPrepareActionMode(mode, mode.menu))
        assertEquals(0, mode.menu.size())
        assertEquals(0, parent.mode.finishes)
        assertEquals(0, delegate.destroyed)

        val rect = Rect()
        (callback as ActionMode.Callback2).onGetContentRect(mode, reader, rect)
        assertEquals(Rect(10, 20, 30, 40), rect)
        val item = mode.menu.add("item")
        assertTrue(callback.onActionItemClicked(mode, item))
        assertSame(item, delegate.clicked)
        callback.onDestroyActionMode(mode)
        assertEquals(1, delegate.destroyed)
    }

    @Test
    fun selectionOriginatingInsideRegisteredWebViewIsAlsoWrapped() {
        val reader = webView("about:blank")
        host.registerReader(reader)
        val child = View(activity)
        reader.addView(child)
        val delegate = SelectionCallback()
        child.startActionMode(delegate, ActionMode.TYPE_FLOATING)
        assertNotSame(delegate, parent.callback)
        assertSame(child, parent.origin)
    }

    @Test
    fun browserLookupAndEditableViewsKeepTheirOriginalCallbacks() {
        host.registerReader(webView("about:blank"))
        val delegate = SelectionCallback()
        // Identical history URLs must not cause unrelated WebViews to match.
        webView("about:blank").startActionMode(delegate, ActionMode.TYPE_FLOATING)
        assertSame(delegate, parent.callback)
        // A URL resembling a chapter is insufficient without registration.
        webView("cupitor-epub://chapter/0").startActionMode(delegate, ActionMode.TYPE_FLOATING)
        assertSame(delegate, parent.callback)
        val editor = EditText(activity)
        host.addView(editor)
        editor.startActionMode(delegate, ActionMode.TYPE_FLOATING)
        assertSame(delegate, parent.callback)
    }

    @Test
    fun primaryActionModesAreUnchanged() {
        val reader = webView("about:blank")
        host.registerReader(reader)
        val delegate = SelectionCallback()
        reader.startActionMode(delegate, ActionMode.TYPE_PRIMARY)
        assertSame(delegate, parent.callback)
    }

    @Test
    fun delegateCanStillRejectCreation() {
        val callback = ReaderSelectionCallback(object : SelectionCallback() {
            override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
                menu.add("Copy")
                return false
            }
        })
        assertFalse(callback.onCreateActionMode(parent.mode, parent.mode.menu))
        assertEquals(0, parent.mode.menu.size())
        assertEquals(0, parent.mode.finishes)
    }

    @Test
    fun installationIsIdempotentAndPreservesFlutterView() {
        val flutterView = FrameLayout(activity)
        activity.setContentView(flutterView)
        val installed = ReaderSelectionHost.install(activity)!!
        assertSame(installed, ReaderSelectionHost.install(activity))
        assertSame(flutterView, installed.getChildAt(0))
        val content = activity.findViewById<ViewGroup>(android.R.id.content)!!
        assertEquals(1, content.childCount)
        assertSame(installed, content.getChildAt(0))
    }

    private fun webView(historyUrl: String): WebView = object : WebView(activity) {
        override fun getUrl(): String = historyUrl
    }.also { host.addView(it) }

    private class RecordingParent(context: Context) : FrameLayout(context) {
        val mode = SelectionMode(context)
        var callback: ActionMode.Callback? = null
        var origin: View? = null

        override fun startActionModeForChild(
            originalView: View,
            callback: ActionMode.Callback,
            type: Int,
        ): ActionMode {
            this.callback = callback
            origin = originalView
            return mode
        }
    }

    private open class SelectionCallback : ActionMode.Callback2() {
        var destroyed = 0
        var clicked: MenuItem? = null
        override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
            menu.add("Copy")
            return true
        }
        override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {
            menu.add("Translate")
            return false
        }
        override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
            clicked = item
            return true
        }
        override fun onDestroyActionMode(mode: ActionMode) { destroyed++ }
        override fun onGetContentRect(mode: ActionMode, view: View, outRect: Rect) {
            outRect.set(10, 20, 30, 40)
        }
    }

    private class SelectionMode(context: Context) : ActionMode() {
        private val selectionMenu = PopupMenu(context, View(context)).menu
        private val inflater = MenuInflater(context)
        var finishes = 0
        override fun finish() { finishes++ }
        override fun invalidate() {}
        override fun getMenu(): Menu = selectionMenu
        override fun getMenuInflater(): MenuInflater = inflater
        override fun setTitle(title: CharSequence?) {}
        override fun setTitle(resId: Int) {}
        override fun getTitle(): CharSequence? = null
        override fun setSubtitle(subtitle: CharSequence?) {}
        override fun setSubtitle(resId: Int) {}
        override fun getSubtitle(): CharSequence? = null
        override fun setCustomView(view: View?) {}
        override fun getCustomView(): View? = null
    }
}
