package com.example.moon_note

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.example.moon_note/service"
    private var channel: MethodChannel? = null
    private var pendingQuickNote = false
    private val quickNoteReceiver = QuickNoteReceiver()

    inner class QuickNoteReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            Log.d("MoonNote", "MainActivity: QuickNoteReceiver received")
            channel?.invokeMethod("onQuickNote", null) ?: run {
                pendingQuickNote = true
                Log.d("MoonNote", "MainActivity: channel null on broadcast, set pending")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingQuickNote = intent.getBooleanExtra("quick_note", false)
        Log.d("MoonNote", "MainActivity: onCreate, pendingQuickNote=$pendingQuickNote")
        val filter = IntentFilter("com.example.moon_note.QUICK_NOTE_ACTION")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(quickNoteReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(quickNoteReceiver, filter)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(quickNoteReceiver)
        } catch (_: Exception) {}
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val qn = intent.getBooleanExtra("quick_note", false)
        Log.d("MoonNote", "MainActivity: onNewIntent, quick_note=$qn, channel=${channel != null}")
        if (qn) {
            channel?.invokeMethod("onQuickNote", null) ?: run {
                pendingQuickNote = true
                Log.d("MoonNote", "MainActivity: channel null, set pendingQuickNote")
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundService" -> {
                    ForegroundService.start(this)
                    result.success(true)
                }
                "stopForegroundService" -> {
                    ForegroundService.stop(this)
                    result.success(true)
                }
                "requestBatteryOptimization" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        startActivity(intent)
                    }
                    result.success(true)
                }
                "isIgnoringBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val powerManager = getSystemService(POWER_SERVICE) as android.os.PowerManager
                        result.success(powerManager.isIgnoringBatteryOptimizations(packageName))
                    } else {
                        result.success(true)
                    }
                }
                "checkPendingQuickNote" -> {
                    Log.d("MoonNote", "MainActivity: checkPendingQuickNote=$pendingQuickNote")
                    result.success(pendingQuickNote)
                    pendingQuickNote = false
                }
                "openBackgroundPopupPermission" -> {
                    // Xiaomi/MIUI: open the "Background pop-up" permission page
                    try {
                        val intent = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                            putExtra("extra_pkgname", packageName)
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                        Log.d("MoonNote", "MainActivity: opened MIUI permission editor")
                    } catch (e: Exception) {
                        // Fallback to generic app settings
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(intent)
                        } catch (e2: Exception) {
                            Log.e("MoonNote", "Failed to open settings: ${e2.message}")
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
