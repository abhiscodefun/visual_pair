package com.example.visual_pair // MAKE SURE THIS MATCHES YOUR PROJECT'S PACKAGE NAME

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity(), SensorEventListener {

    private val VOLUME_BUTTON_CHANNEL = "volume_button_channel"
    private val LIGHT_SENSOR_CHANNEL = "samples.flutter.dev/lightSensor"
    private val AUDIO_MANAGER_CHANNEL = "audio_manager_channel"

    // MethodChannels for communication with Flutter
    private lateinit var volumeButtonMethodChannel: MethodChannel
    private lateinit var audioManagerMethodChannel: MethodChannel

    // Light Sensor setup
    private lateinit var sensorManager: SensorManager
    private var lightSensor: Sensor? = null
    private var lightSensorEventSink: EventChannel.EventSink? = null

    // Audio Manager setup
    private lateinit var audioManager: AudioManager
    private var volumeMax: Int = 0

    // For Volume Button Long Press Detection
    private val longPressHandlers = mutableMapOf<Int, Handler>()
    private val longPressRunnables = mutableMapOf<Int, Runnable>()
    private val LONG_PRESS_TIMEOUT = 500L // milliseconds for long press detection

    // Flag to track if the long press action has been triggered
    private var isLongPressTriggered: Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize MethodChannels
        volumeButtonMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOLUME_BUTTON_CHANNEL)
        audioManagerMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_MANAGER_CHANNEL)

        // Set MethodCallHandler for Audio Manager specific calls from Flutter
        audioManagerMethodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "increaseVolumeAndReset" -> { // Increases volume and sends updated percentage
                    adjustVolume(AudioManager.ADJUST_RAISE)
                    result.success(null)
                }
                "decreaseVolumeAndReset" -> { // Decreases volume and sends updated percentage
                    adjustVolume(AudioManager.ADJUST_LOWER)
                    result.success(null)
                }
                "requestInitialVolumePercentage" -> { // Sends current volume when requested by Flutter
                    sendVolumePercentage()
                    result.success(null)
                }
                else -> result.notImplemented() // Handle unknown method calls
            }
        }

        // Set StreamHandler for Light Sensor events
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LIGHT_SENSOR_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    lightSensorEventSink = events
                    startListening() // Start listening to the light sensor
                }

                override fun onCancel(arguments: Any?) {
                    lightSensorEventSink = null
                    stopListening() // Stop listening to the light sensor
                }
            }
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Initialize sensor and audio managers
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        lightSensor = sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        volumeMax = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC) // Get max volume for music stream
    }

    // Start listening to the light sensor.
    private fun startListening() {
        lightSensor?.let { sensor ->
            sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
        }
    }

    // Stop listening to the light sensor.
    private fun stopListening() {
        sensorManager.unregisterListener(this)
    }

    // Callback for sensor changes (light sensor).
    override fun onSensorChanged(event: SensorEvent?) {
        event?.let {
            if (it.sensor.type == Sensor.TYPE_LIGHT) {
                val lux = it.values[0].toDouble() // Get ambient light in lux.
                lightSensorEventSink?.success(lux) // Send lux value to Flutter.
            }
        }
    }

    // Callback for sensor accuracy changes (not used in this implementation).
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // Not needed for this implementation
    }

    // --- Volume Button Key Event Handling ---
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // Intercept volume key down events.
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (event?.repeatCount == 0) { // Only care about the initial press (not repeated presses during long press).
                isLongPressTriggered = false // Reset the flag for a new key press.
                val handler = Handler(Looper.getMainLooper())
                val runnable = Runnable {
                    // This Runnable executes if the key is held down for LONG_PRESS_TIMEOUT.
                    isLongPressTriggered = true // Set the flag because the long press action is now triggered.
                    val methodName = if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "volumeUpLongPressed" else "volumeDownLongPressed"
                    volumeButtonMethodChannel.invokeMethod(methodName, null) // Notify Flutter of long press.
                }
                longPressHandlers[keyCode] = handler
                longPressRunnables[keyCode] = runnable
                handler.postDelayed(runnable, LONG_PRESS_TIMEOUT) // Start long press timer.

                // Allow system to handle the initial key down for volume change (shows volume UI).
                return super.onKeyDown(keyCode, event)
            } else {
                // If it's a repeated event *after* a long press has started,
                // consume it to prevent continuous system volume adjustments if long press is for mode toggle.
                return true
            }
        }
        // For other keys, let the system handle them.
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        // Intercept volume key up events.
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            val handler = longPressHandlers.remove(keyCode) // Get and remove handler for this key.
            val runnable = longPressRunnables.remove(keyCode) // Get and remove runnable for this key.

            // Always try to remove the callback. If it's successfully removed, it means
            // the long press runnable hadn't executed yet (it was a short press).
            handler?.removeCallbacks(runnable!!)

            // If the long press was NOT triggered by the runnable, then it was a short press.
            if (!isLongPressTriggered) {
                val methodName = if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "volumeUpPressed" else "volumeDownPressed"
                volumeButtonMethodChannel.invokeMethod(methodName, null) // Notify Flutter of short press.
            }

            // Reset the flag for the next key press.
            isLongPressTriggered = false

            // Always send the current volume percentage after any volume key up event,
            // as the system might have adjusted the volume.
            sendVolumePercentage()
            return true // Consume the event as we've handled the custom logic.
        }
        // For other keys, let the system handle them.
        return super.onKeyUp(keyCode, event)
    }
    // --- End Volume Button Key Event Handling ---


    // Calculates and sends the current music stream volume percentage to Flutter.
    private fun sendVolumePercentage() {
        val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val percentage = if (volumeMax > 0) (currentVolume.toDouble() / volumeMax * 100).toInt() else 0
        audioManagerMethodChannel.invokeMethod("volumePercentageChanged", percentage)
    }

    // Adjusts the music stream volume by one step in the given direction.
    // Includes wrap-around behavior (min->max, max->min).
    private fun adjustVolume(direction: Int) {
        val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)

        if (direction == AudioManager.ADJUST_RAISE) {
            if (currentVolume < volumeMax) {
                audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI)
            } else { // At max volume, wrap around to 0.
                audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, 0, AudioManager.FLAG_SHOW_UI)
            }
        } else if (direction == AudioManager.ADJUST_LOWER) {
            if (currentVolume > 0) { // Minimum volume is usually 0.
                audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
            } else { // At min volume, wrap around to max.
                audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, volumeMax, AudioManager.FLAG_SHOW_UI)
            }
        }
        sendVolumePercentage() // Always send the updated percentage after adjustment.
    }

    // Lifecycle method: called when the activity is being destroyed.
    override fun onDestroy() {
        super.onDestroy()
        stopListening() // Stop light sensor listening to prevent leaks.
        // Clear any pending long press handlers to prevent memory leaks.
        longPressHandlers.values.forEach { it.removeCallbacksAndMessages(null) }
        longPressHandlers.clear()
        longPressRunnables.clear()
    }
}