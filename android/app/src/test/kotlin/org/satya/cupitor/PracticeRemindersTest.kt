package org.satya.cupitor

import android.app.Activity
import android.app.AlertDialog
import android.content.DialogInterface
import android.os.Looper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class PracticeRemindersTest {
    @Test
    fun foregroundReminderShowsAndOpensProgress() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        PracticeReminders.attachForegroundHost(activity)
        try {
            var opens = 0
            PracticeReminders.showForegroundReminder("Time to update Reading.") { opens++ }
            val dialog = ShadowDialog.getLatestDialog() as AlertDialog
            assertTrue(dialog.isShowing)

            dialog.getButton(DialogInterface.BUTTON_POSITIVE).performClick()
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(1, opens)
            assertFalse(dialog.isShowing)

            PracticeReminders.showForegroundReminder("Time to update Writing.") { opens++ }
            val secondDialog = ShadowDialog.getLatestDialog()
            assertTrue(secondDialog.isShowing)
            PracticeReminders.detachForegroundHost(activity)
            assertFalse(secondDialog.isShowing)
        } finally {
            PracticeReminders.detachForegroundHost(activity)
            controller.pause().stop().destroy()
        }
    }
}
