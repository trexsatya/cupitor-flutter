package org.satya.cupitor

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Notification actions launch this activity directly, without a broadcast trampoline. */
class StudyCallDeclineActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        val id = intent.getStringExtra("id") ?: run { finish(); return }
        val original = StudyCalls.find(this, id) ?: run { finish(); return }
        if (original.optString("status") == "ringing") StudyCalls.finish(this, id, "declined")
        val row = StudyCalls.find(this, id)
        if (row?.optString("status") != "declined") { finish(); return }
        if (StudyCalls.visibleCallId == id) StudyCalls.visibleCallId = null
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (24 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad); setBackgroundColor(Color.WHITE)
        }
        setContentView(ScrollView(this).apply { isFillViewport = true; addView(body) })
        body.addView(TextView(this).apply { text = "Call declined"; textSize = 28f; setTextColor(Color.BLACK) })
        body.addView(TextView(this).apply {
            text = "${row.getString("title")}\nWhen should Cupitor call back?"
            textSize = 20f; setTextColor(Color.BLACK); setPadding(0, 24, 0, 24)
        })
        val status = TextView(this).apply { textSize = 16f; setTextColor(Color.DKGRAY) }
        val buttons = mutableListOf<Button>()
        for (minutes in listOf(5, 10, 15)) {
            val button = Button(this).apply {
                text = "Call back in $minutes minutes"; isAllCaps = false
                minHeight = (52 * resources.displayMetrics.density).toInt()
                setOnClickListener {
                    buttons.forEach { it.isEnabled = false }
                    try { StudyCalls.callBack(this@StudyCallDeclineActivity, id, minutes); finish() }
                    catch (error: Exception) {
                        status.text = when (error.message) {
                            "too_many_calls" -> "The pending call limit is full. Increase it in Study calls Settings."
                            "permission_denied" -> "Enable study-call notifications before scheduling a callback."
                            "not_declined", "unknown_call" -> "This call has already changed. Close and refresh Study calls."
                            else -> "Could not schedule the callback. Please try again."
                        }
                        buttons.forEach { it.isEnabled = true }
                    }
                }
            }
            buttons.add(button); body.addView(button)
        }
        body.addView(Button(this).apply {
            text = "Dismiss without callback"; isAllCaps = false
            minHeight = (52 * resources.displayMetrics.density).toInt()
            setOnClickListener { finish() }
        })
        body.addView(status)
    }
}
