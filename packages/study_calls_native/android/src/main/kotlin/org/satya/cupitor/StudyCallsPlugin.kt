package org.satya.cupitor

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Registered in every engine, including Workmanager's headless engine.
 * This internal channel is never exposed as a WebView JavaScript channel. */
class StudyCallsPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "cupitor/playlist_calls").also {
            it.setMethodCallHandler { call, reply ->
                try {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    when (call.method) {
                        "deliver" -> reply.success(StudyCalls.deliverPlaylist(context, args))
                        "cancelScheduled" -> { StudyCalls.cancelPlaylistScheduled(context); reply.success(true) }
                        "retainItems" -> {
                            val ids = (args["notif_ids"] as? List<*>)?.mapNotNull { n -> (n as? Number)?.toInt() }?.toSet()
                                ?: error("bad_payload")
                            StudyCalls.retainPlaylistItems(context, ids); reply.success(true)
                        }
                        "activeIds" -> reply.success(StudyCalls.read(context).filter { row ->
                            row.has("notif_id") && row.optString("status") in setOf("ringing", "answered")
                        }.map { row -> row.getInt("notif_id") })
                        else -> reply.notImplemented()
                    }
                } catch (e: Exception) { reply.error(e.message ?: "internal", null, null) }
            }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null); channel = null
    }
}
