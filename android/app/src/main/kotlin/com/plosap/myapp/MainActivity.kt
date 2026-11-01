package com.plosap.myapp

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.net.Uri
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareSession
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareNetworkSpecifier
import android.net.wifi.aware.WifiAwareNetworkInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.provider.Settings
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.Security
import java.security.Signature
import java.security.KeyFactory
import java.security.spec.X509EncodedKeySpec
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Mac
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHODS = "com.blousab.messenger/bluetooth"
        private const val EVENTS = "com.blousab.messenger/events"
        private const val SERVICE_NAME = "BlousabRFCOMM"
        private val SERVICE_UUID: UUID =
            UUID.fromString("f0e1d2c3-b4a5-4678-9012-123456789abc")
    }

    private val executor = Executors.newCachedThreadPool()
    private val wifiAwareManager: WifiAwareManager?
        get() = getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
    @Volatile private var wifiAwareSession: WifiAwareSession? = null
    @Volatile private var wifiPublishSession: PublishDiscoverySession? = null
    @Volatile private var wifiSubscribeSession: SubscribeDiscoverySession? = null
    @Volatile private var wifiAwareEventSink: EventChannel.EventSink? = null
    private val pendingWifiAwareEvents = java.util.concurrent.ConcurrentLinkedQueue<Map<String, Any>>()
    @Volatile private var wifiAwareStarted = false
    @Volatile private var wifiAwareStarting = false
    @Volatile private var wifiAwareIdentity = ""
    @Volatile private var wifiAwareUserId = ""
    private val awareNetworkCallbacks = ConcurrentHashMap<String, ConnectivityManager.NetworkCallback>()
    private val awareSockets = ConcurrentHashMap<String, Socket>()
    private val awareWriters = ConcurrentHashMap<String, DataOutputStream>()
    private val awareServers = ConcurrentHashMap<String, ServerSocket>()
    private val awareNetworks = ConcurrentHashMap<String, Network>()
    private val awareConnecting = ConcurrentHashMap.newKeySet<String>()
    private val awareRetryCounts = ConcurrentHashMap<String, Int>()
    private val awareSubscribeHandles = ConcurrentHashMap<String, PeerHandle>()
    private val awarePublishHandles = ConcurrentHashMap<String, PeerHandle>()
    private val awareSocketOpening = ConcurrentHashMap.newKeySet<String>()
    private val awareConnectRequests = ConcurrentHashMap.newKeySet<String>()
    // A verified discovery identity is not a connection request. Only peers
    // explicitly selected by the user may open/reopen a NAN data path.
    private val awareUserInitiatedPeers = ConcurrentHashMap.newKeySet<String>()
    private val awareReconnectScheduled = ConcurrentHashMap.newKeySet<String>()
    private val awarePort = 39773
    private val awareMaxPacketBytes = 1024 * 1024
    private val wifiAwarePeers = ConcurrentHashMap<PeerHandle, Pair<String, String>>()
    private val wifiVerifiedPeerKeys = ConcurrentHashMap<String, String>()
    private val wifiPassphrases = ConcurrentHashMap<String, String>()
    private val wifiVerifiedSubscribeHandles = ConcurrentHashMap<String, PeerHandle>()
    private val wifiVerifiedPublishHandles = ConcurrentHashMap<String, PeerHandle>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val serverRunning = AtomicBoolean(false)
    @Volatile private var backgroundRuntime: BlousabBackgroundService? = null
    @Volatile private var backgroundRuntimeBound = false
    private val backgroundRuntimeConnection = object : android.content.ServiceConnection {
        override fun onServiceConnected(name: android.content.ComponentName?, binder: android.os.IBinder?) {
            val runtime = (binder as? BlousabBackgroundService.RuntimeBinder)?.service()
            backgroundRuntime = runtime
            if (runtime != null) {
                if (bluetoothBlousabIdentity.isNotBlank() && bluetoothBlousabUserId.isNotBlank()) {
                    runtime.configureBluetoothHandshake(bluetoothBlousabIdentity, bluetoothBlousabUserId) { text -> signHandshakeTranscript(text) }
                }
                runtime.attachSessionEventConsumer { event -> dispatchServiceSessionEvent(event) }
                runtime.authenticatedPeerSnapshot().forEach { event -> dispatchServiceSessionEvent(event) }
            }
            if (runtime != null && serverRunning.get()) {
                runtime.startBluetoothListener(
                    onAccepted = { socket -> runtime.authenticateIncomingSocket(socket) },
                    onError = { message -> emit("serverError", message = message); serverRunning.set(false) }
                )
            }
        }
        override fun onServiceDisconnected(name: android.content.ComponentName?) {
            backgroundRuntime = null
            backgroundRuntimeBound = false
        }
    }
    private val sockets = ConcurrentHashMap<String, BluetoothSocket>()
    private val serviceManagedBluetoothAddresses = ConcurrentHashMap.newKeySet<String>()
    private val writers = ConcurrentHashMap<String, PrintWriter>()
    private val bluetoothSessionCryptos = ConcurrentHashMap<String, BluetoothSessionCrypto>()
    private val discovered = ConcurrentHashMap<String, BluetoothDevice>()
    @Volatile private var discoveryReceiver: BroadcastReceiver? = null

    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val pendingBluetoothEvents = java.util.concurrent.ConcurrentLinkedQueue<Map<String, Any>>()
    @Volatile private var bluetoothBlousabIdentity: String = ""
    @Volatile private var bluetoothBlousabUserId: String = ""
    @Volatile private var bluetoothMethodChannel: MethodChannel? = null
    @Volatile private var serverSocket: BluetoothServerSocket? = null

    private val adapter: BluetoothAdapter?
        get() = BluetoothAdapter.getDefaultAdapter()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.blousab.messenger/background_runtime")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            val intent = Intent(this, BlousabBackgroundService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                ContextCompat.startForegroundService(this, intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        }
                        "stop" -> {
                            stopService(Intent(this, BlousabBackgroundService::class.java))
                            result.success(true)
                        }
                        "isSupported" -> result.success(true)
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("BACKGROUND_RUNTIME", e.message ?: "تعذر تشغيل خدمة الخلفية", null)
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    while (true) {
                        val pending = pendingBluetoothEvents.poll() ?: break
                        events?.success(pending)
                    }
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.blousab.messenger/battery")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "isIgnoringBatteryOptimizations" -> {
                            result.success(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                                powerManager.isIgnoringBatteryOptimizations(packageName)
                            } else true)
                        }
                        "requestIgnoreBatteryOptimizations" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                    .setData(Uri.parse("package:$packageName"))
                                if (intent.resolveActivity(packageManager) != null) startActivity(intent)
                                else startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("BATTERY_SETTINGS", e.message ?: "تعذر فتح إعدادات البطارية", null)
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.blousab.messenger/wifi_aware_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    wifiAwareEventSink = events
                    // The app may start discovery before a screen subscribes. Replay
                    // queued peer events so the first nearby users are not lost.
                    while (true) {
                        val pending = pendingWifiAwareEvents.poll() ?: break
                        events?.success(pending)
                    }
                }
                override fun onCancel(arguments: Any?) { wifiAwareEventSink = null }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.blousab.messenger/wifi_aware")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getAndroidSdk" -> result.success(Build.VERSION.SDK_INT)
                        "isSupported" -> result.success(Build.VERSION.SDK_INT >= 26 && wifiAwareManager != null && packageManager.hasSystemFeature("android.hardware.wifi.aware"))
                        "isAvailable" -> result.success(Build.VERSION.SDK_INT >= 26 && wifiAwareManager?.isAvailable == true)
                        "start" -> {
                            val userId = call.argument<String>("userId") ?: "blousab-user"
                            val userName = call.argument<String>("userName") ?: "مستخدم بلوساب"
                            startWifiAware(userId, userName, result)
                        }
                        "stop" -> { stopWifiAware(); result.success(true) }
                        "connectPeer" -> {
                            val peerId = call.argument<String>("peerId") ?: ""
                            val handle = awareSubscribeHandles[peerId]
                            if (peerId.isBlank() || !wifiVerifiedPeerKeys.containsKey(peerId) || handle == null || wifiVerifiedSubscribeHandles[peerId] != handle) {
                                result.error("WIFI_PEER_UNVERIFIED", "لا يمكن الاتصال قبل نجاح المصافحة التشفيرية مع جلسة Wi-Fi الحالية", null)
                                return@setMethodCallHandler
                            }
                            val session = wifiSubscribeSession
                            if (handle == null || session == null) {
                                result.error("PEER_NOT_DISCOVERED", "لم يعد المستخدم ظاهرًا في اكتشاف Wi-Fi المباشر", null)
                            } else {
                                awareUserInitiatedPeers.add(peerId)
                                sendWifiAwareConnectRequest(handle, peerId,
                                    wifiAwarePeers.values.firstOrNull { it.first == peerId }?.second ?: "مستخدم بلوساب", session)
                                result.success(true)
                            }
                        }
                        "sendPacket" -> {
                            val peerId = call.argument<String>("peerId") ?: ""
                            val payload = call.argument<String>("payload") ?: ""
                            if (peerId.isBlank() || !awareUserInitiatedPeers.contains(peerId) ||
                                !wifiVerifiedPeerKeys.containsKey(peerId) || !awareSockets.containsKey(peerId)) {
                                result.error("WIFI_AWARE_UNVERIFIED_OR_NOT_SELECTED", "لا يمكن الإرسال قبل توثيق المستخدم واختياره وفتح قناة Wi-Fi Aware", null)
                                return@setMethodCallHandler
                            }
                            executor.execute {
                                try {
                                    sendWifiAwarePacket(peerId, payload)
                                    mainHandler.post { result.success(true) }
                                } catch (e: Exception) {
                                    mainHandler.post { result.error("WIFI_AWARE_SEND", e.message ?: "تعذر إرسال الحزمة عبر Wi-Fi Aware", null) }
                                }
                            }
                        }
                        "connectedPeers" -> result.success(awareSockets.keys.filter {
                            awareUserInitiatedPeers.contains(it) && wifiVerifiedPeerKeys.containsKey(it)
                        })
                        else -> result.notImplemented()
                    }
                } catch (e: SecurityException) {
                    wifiAwareStarting = false
                    result.error("WIFI_AWARE_PERMISSION", e.message ?: "صلاحية Wi-Fi القريب غير متاحة", null)
                } catch (e: Exception) {
                    wifiAwareStarting = false
                    result.error("WIFI_AWARE_ERROR", e.message ?: "تعذر تشغيل اكتشاف Wi-Fi المباشر", null)
                }
            }

        val bluetoothChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHODS)
        bluetoothMethodChannel = bluetoothChannel
        bluetoothChannel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "setIdentity" -> {
                            val userId = call.argument<String>("userId") ?: ""
                            val signedPayload = call.argument<String>("signedPayload") ?: ""
                            val signature = call.argument<String>("signature") ?: ""
                            val publicKey = call.argument<String>("publicKey") ?: ""
                            if (userId.isBlank() || signedPayload.isBlank() || signature.isBlank() || publicKey.isBlank()) {
                                result.error("IDENTITY", "بيانات الهوية الموقعة ناقصة", null)
                            } else {
                                val payloadBytes = try { android.util.Base64.decode(signedPayload, android.util.Base64.DEFAULT) } catch (_: Exception) { byteArrayOf() }
                                val payload = try { JSONObject(String(payloadBytes, Charsets.UTF_8)) } catch (_: Exception) { JSONObject() }
                                if (payload.optString("type") != "blousab_discovery_identity" ||
                                    payload.optInt("version") != 2 || payload.optString("userId") != userId ||
                                    payload.optString("publicKey") != publicKey || !verifyEd25519(publicKey, payloadBytes, signature)) {
                                    result.error("IDENTITY_SIGNATURE", "تعذر التحقق من توقيع هوية بلوساب المحلية", null)
                                } else {
                                    fun enc(value: String) = android.util.Base64.encodeToString(value.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP or android.util.Base64.URL_SAFE)
                                    val envelope = JSONObject().put("payload", signedPayload).put("signature", signature).put("publicKey", publicKey).toString()
                                    bluetoothBlousabIdentity = "BLUSAB_HELLO|2|${enc(envelope)}"
                                    bluetoothBlousabUserId = userId
                                    backgroundRuntime?.configureBluetoothHandshake(bluetoothBlousabIdentity, bluetoothBlousabUserId) { text -> signHandshakeTranscript(text) }
                                    result.success(true)
                                }
                            }
                        }
                        "isSupported" -> result.success(adapter != null)
                        "getAndroidSdk" -> result.success(Build.VERSION.SDK_INT)
                        "isEnabled" -> {
                            if (!hasConnectPermission()) {
                                result.error("PERMISSION", "امنح صلاحية البلوتوث أولاً", null)
                            } else result.success(adapter?.isEnabled == true)
                        }
                        "requestEnable" -> {
                            if (!hasConnectPermission()) {
                                result.error("PERMISSION", "امنح صلاحية البلوتوث أولاً", null)
                            } else {
                                startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
                                result.success(true)
                            }
                        }
                        "requestDiscoverable" -> {
                            if (!hasConnectPermission() || !hasAdvertisePermission()) {
                                result.error("PERMISSION", "صلاحية إظهار البلوتوث للأجهزة القريبة غير متاحة", null)
                            } else {
                                startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300))
                                result.success(true)
                            }
                        }
                        "startDiscovery" -> {
                            if (!hasConnectPermission() || !hasScanPermission()) {
                                result.error("PERMISSION", "صلاحيات البحث عن أجهزة البلوتوث غير متاحة", null)
                            } else {
                                startDiscovery(result)
                            }
                        }
                        "cancelDiscovery" -> {
                            try { adapter?.cancelDiscovery() } catch (_: Exception) {}
                            result.success(true)
                        }
                        "getPairedDevices" -> {
                            if (!hasConnectPermission()) {
                                result.error("PERMISSION", "صلاحية البلوتوث غير متاحة", null)
                            } else {
                                val devices = adapter?.bondedDevices?.map {
                                    mapOf("name" to (it.name ?: "جهاز"), "address" to it.address)
                                } ?: emptyList<Map<String, String>>()
                                result.success(devices)
                            }
                        }
                        "startServer" -> {
                            if (!hasConnectPermission()) result.error("PERMISSION", "صلاحية البلوتوث غير متاحة", null)
                            else startServer(result)
                        }
                        "connect" -> {
                            if (!hasConnectPermission()) {
                                result.error("PERMISSION", "صلاحية البلوتوث غير متاحة", null)
                            } else {
                                val address = call.argument<String>("address")
                                if (address.isNullOrBlank()) result.error("ADDRESS", "عنوان الجهاز مطلوب", null)
                                else connect(address, result)
                            }
                        }
                        "verifyCandidate" -> {
                            if (!hasConnectPermission() || !hasScanPermission()) {
                                result.error("PERMISSION", "صلاحيات البلوتوث غير متاحة للتحقق من المستخدم القريب", null)
                            } else {
                                val address = call.argument<String>("address")
                                val runtime = backgroundRuntime
                                if (address.isNullOrBlank()) {
                                    result.error("ADDRESS", "عنوان الجهاز مطلوب", null)
                                } else if (runtime == null) {
                                    result.error("BACKGROUND_RUNTIME", "خدمة بلوساب الخلفية غير جاهزة؛ أعد المحاولة بعد لحظة", null)
                                } else if (bluetoothBlousabIdentity.isBlank() || bluetoothBlousabUserId.isBlank()) {
                                    result.error("IDENTITY", "هوية بلوساب غير مهيأة؛ أعد فتح التطبيق", null)
                                } else {
                                    runtime.configureBluetoothHandshake(bluetoothBlousabIdentity, bluetoothBlousabUserId) { text -> signHandshakeTranscript(text) }
                                    runtime.verifyDiscoveryCandidate(address) { success, message ->
                                        mainHandler.post {
                                            try {
                                                if (!serverRunning.get() && adapter?.isEnabled == true && hasScanPermission()) {
                                                    adapter?.startDiscovery()
                                                }
                                            } catch (_: Exception) {}
                                            if (success) result.success(true)
                                            else result.success(false)
                                        }
                                    }
                                }
                            }
                        }
                        "ackSessionEvent" -> {
                            val eventId = call.argument<Number>("eventId")?.toLong()
                            if (eventId == null || eventId <= 0L) {
                                result.error("EVENT_ID", "معرّف الحدث غير صالح", null)
                            } else {
                                result.success(backgroundRuntime?.acknowledgeSessionEvent(eventId) ?: false)
                            }
                        }
                        "sendMessage" -> {
                            val address = call.argument<String>("address")
                            val message = call.argument<String>("message")
                            if (address.isNullOrBlank() || message == null) {
                                result.error("ARGUMENT", "بيانات الرسالة ناقصة", null)
                            } else {
                                executor.execute {
                                    try {
                                        val runtime = backgroundRuntime
                                        if (runtime != null) {
                                            runtime.sendAuthenticatedMessage(address, message)
                                            mainHandler.post { result.success(true) }
                                            return@execute
                                        }
                                        val targets = if (address == "*") writers.entries.toList() else {
                                            val writer = writers[address]
                                                ?: throw IllegalStateException("الجهاز غير متصل")
                                            listOf(java.util.AbstractMap.SimpleEntry(address, writer))
                                        }
                                        if (targets.isEmpty()) throw IllegalStateException("لا توجد أجهزة متصلة")
                                        var sent = 0
                                        var lastError: Exception? = null
                                        for ((peerAddress, writer) in targets) {
                                            try {
                                                val crypto = bluetoothSessionCryptos[peerAddress]
                                                    ?: throw SecurityException("مفتاح جلسة Bluetooth غير متاح")
                                                synchronized(writer) {
                                                    writer.println(crypto.encrypt(message))
                                                    writer.flush()
                                                    if (writer.checkError()) throw java.io.IOException("فشل الإرسال")
                                                }
                                                sent++
                                            } catch (e: Exception) {
                                                lastError = e
                                                closePeer(peerAddress)
                                            }
                                        }
                                        if (sent == 0) throw (lastError ?: java.io.IOException("فشل الإرسال"))
                                        mainHandler.post { result.success(true) }
                                    } catch (e: Exception) {
                                        mainHandler.post {
                                            result.error("SEND", e.message ?: "فشل إرسال الرسالة", null)
                                        }
                                    }
                                }
                            }
                        }
                        "disconnect" -> {
                            val address = call.argument<String>("address")
                            val runtime = backgroundRuntime
                            if (runtime != null) runtime.closeAuthenticatedPeer(address) else {
                                if (address.isNullOrBlank()) closeAll() else closePeer(address)
                            }
                            result.success(true)
                        }
                        "stopServer" -> {
                            stopServer()
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: SecurityException) {
                    result.error("PERMISSION", e.message ?: "صلاحية البلوتوث غير متاحة", null)
                } catch (e: Exception) {
                    result.error("NATIVE_ERROR", e.message ?: "حدث خطأ في البلوتوث", null)
                }
            }
    }

    private fun dispatchServiceSessionEvent(event: Map<String, Any>) {
        mainHandler.post {
            val sink = eventSink
            if (sink != null) sink.success(event)
            else {
                if (pendingBluetoothEvents.size >= 100) pendingBluetoothEvents.poll()
                pendingBluetoothEvents.offer(event)
            }
        }
    }

    private fun hasWifiAwarePermission(): Boolean = if (Build.VERSION.SDK_INT >= 33) {
        ContextCompat.checkSelfPermission(this, Manifest.permission.NEARBY_WIFI_DEVICES) == PackageManager.PERMISSION_GRANTED
    } else {
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }

    private fun emitWifiAware(type: String, userId: String? = null, userName: String? = null, message: String? = null, fingerprint: String? = null, publicKey: String? = null) {
        val event = mutableMapOf<String, Any>("type" to type)
        userId?.let { event["userId"] = it }
        userName?.let { event["userName"] = it }
        message?.let { event["message"] = it }
        fingerprint?.let { event["publicKeyFingerprint"] = it }
        publicKey?.let { event["publicKey"] = it }
        if (type == "wifiVerified" && message != null) event["profilePhoto"] = message
        mainHandler.post {
            val sink = wifiAwareEventSink
            if (sink != null) {
                sink.success(event)
            } else if (type != "dataPacket") {
                // Keep discovery/status events while no Flutter listener is attached.
                // Media frames are intentionally not queued in memory; feed reconciliation
                // requests any missed content after the UI reconnects.
                if (pendingWifiAwareEvents.size >= 100) pendingWifiAwareEvents.poll()
                pendingWifiAwareEvents.offer(event)
            }
        }
    }

    private fun startWifiAware(userId: String, userName: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 26) {
            result.error("WIFI_AWARE_UNSUPPORTED", "يتطلب Wi-Fi Aware أندرويد 8 أو أحدث", null); return
        }
        val manager = wifiAwareManager
        if (manager == null || !packageManager.hasSystemFeature("android.hardware.wifi.aware")) {
            result.error("WIFI_AWARE_UNSUPPORTED", "هذا الهاتف لا يدعم Wi-Fi Aware", null); return
        }
        if (!hasWifiAwarePermission()) {
            result.error("WIFI_AWARE_PERMISSION", "امنح صلاحية الأجهزة القريبة عبر Wi-Fi أولاً", null); return
        }
        if (!manager.isAvailable) {
            result.error("WIFI_AWARE_UNAVAILABLE", "Wi-Fi Aware غير متاح الآن. تحقق من تشغيل Wi-Fi ودعم الهاتف", null); return
        }
        if (wifiAwareStarted) {
            emitWifiAware("started", message = "بث بلوساب والبحث المباشر يعملان بالفعل")
            result.success(true)
            return
        }
        if (wifiAwareStarting) {
            result.success(true)
            return
        }
        wifiAwareStarting = true
        wifiAwareUserId = userId
        // Advertise only an opaque key fingerprint, never the OS device name or
        // an unauthenticated display name. The fingerprint is only a candidate hint;
        // the live signed identity + mutual nonce exchange below establishes possession.
        val localIdentity = parseSignedBlousabHello(bluetoothBlousabIdentity)
        if (localIdentity.userId != userId) {
            wifiAwareStarting = false
            result.error("WIFI_AWARE_IDENTITY", "هوية Wi-Fi لا تطابق هوية بلوساب المهيأة", null)
            return
        }
        val localFingerprint = publicKeyFingerprint(localIdentity.publicKey)
        wifiAwareIdentity = "BLUSAB2|" + userId.take(48) + "|" + localFingerprint
        val runtime = backgroundRuntime
        if (runtime == null) {
            val intent = Intent(this, BlousabBackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ContextCompat.startForegroundService(this, intent)
            else startService(intent)
            if (!backgroundRuntimeBound) {
                backgroundRuntimeBound = bindService(intent, backgroundRuntimeConnection, Context.BIND_AUTO_CREATE)
            }
            mainHandler.postDelayed({
                wifiAwareStarting = false
                if (backgroundRuntime != null) startWifiAware(userId, userName, result)
                else result.error("BACKGROUND_BIND", "تعذر ربط خدمة Wi-Fi Aware بالخلفية", null)
            }, 400)
            return
        }
        try {
            runtime.configureWifiAwareHandshake(
                localHello = bluetoothBlousabIdentity,
                localUserId = userId,
                signer = { text -> signHandshakeTranscript(text) },
                onVerified = { peerHandle, session, peer, passphrase, sendKey, receiveKey, sendPrefix, receivePrefix ->
                    mainHandler.post {
                        val oldKey = wifiVerifiedPeerKeys[peer.userId]
                        if (oldKey != null && oldKey != peer.publicKey) {
                            emitWifiAware("handshakeFailed", peer.userId, message = "معرّف بلوساب مرتبط بمفتاح مختلف")
                            return@post
                        }
                        wifiAwarePeers[peerHandle] = Pair(peer.userId, peer.userName)
                        wifiVerifiedPeerKeys[peer.userId] = peer.publicKey
                    wifiPassphrases[peer.userId] = passphrase
                        wifiPassphrases[peer.userId] = passphrase
                        if (session is SubscribeDiscoverySession) {
                            wifiVerifiedSubscribeHandles[peer.userId] = peerHandle
                            awareSubscribeHandles[peer.userId] = peerHandle
                        } else if (session is PublishDiscoverySession) {
                            wifiVerifiedPublishHandles[peer.userId] = peerHandle
                            awarePublishHandles[peer.userId] = peerHandle
                        }
                        runtime.installWifiAwarePacketKeys(peer.userId, sendKey, receiveKey, sendPrefix, receivePrefix)
                        emitWifiAware("wifiVerified", peer.userId, peer.userName,
                            message = "", fingerprint = publicKeyFingerprint(peer.publicKey), publicKey = peer.publicKey)
                    }
                },
                onFailure = { peerHandle, message ->
                    val peer = wifiAwarePeers[peerHandle]
                    emitWifiAware("handshakeFailed", peer?.first, peer?.second, message)
                }
            )
            runtime.startWifiAware(
                identityAdvertisement = wifiAwareIdentity,
                publishStartedCallback = { discoverySession ->
                    wifiPublishSession = discoverySession
                    markWifiAwareStarted()
                },
                subscribeStartedCallback = { discoverySession ->
                    wifiSubscribeSession = discoverySession
                    markWifiAwareStarted()
                },
                serviceDiscoveredCallback = { peerHandle, serviceSpecificInfo, discoverySession ->
                    val raw = try { serviceSpecificInfo?.toString(Charsets.UTF_8) ?: "" } catch (_: Exception) { "" }
                    if (raw.startsWith("BLUSAB2|")) {
                        val parts = raw.split("|", limit = 3)
                        if (parts.size == 3 && parts[1].isNotBlank() && parts[2].matches(Regex("[0-9a-f]{64}"))) {
                            val candidateId = parts[1]
                            val candidateFingerprint = parts[2]
                            wifiAwarePeers[peerHandle] = Pair(candidateId, "مستخدم بلوساب")
                            awareSubscribeHandles[candidateId] = peerHandle
                            emitWifiAware("candidateFound", candidateId, "مستخدم بلوساب", fingerprint = candidateFingerprint)
                            if (Build.VERSION.SDK_INT < 29) {
                                emitWifiAware("dataUnavailable", candidateId, "مستخدم بلوساب", "نقل Wi-Fi Aware المباشر يحتاج Android 10 أو أحدث؛ سيبقى الاكتشاف متاحًا")
                            }
                        }
                    }
                },
                messageReceivedCallback = { peerHandle, discoverySession, message ->
                    handleWifiAwareHandshakeMessage(peerHandle, discoverySession, message)
                },
                serviceLostCallback = { peerHandle, reason ->
                    val peer = wifiAwarePeers.remove(peerHandle)
                    if (peer != null) {
                        if (wifiVerifiedSubscribeHandles[peer.first] == peerHandle) {
                            awareUserInitiatedPeers.remove(peer.first)
                            wifiVerifiedSubscribeHandles.remove(peer.first)
                            wifiVerifiedPublishHandles.remove(peer.first)
                            wifiVerifiedPeerKeys.remove(peer.first)
                            wifiPassphrases.remove(peer.first)
                            backgroundRuntime?.removeWifiAwarePacketKeys(peer.first)
                            awarePublishHandles.remove(peer.first)
                        }
                        closeWifiAwarePeer(peer.first)
                        awareRetryCounts.remove(peer.first)
                        awareSubscribeHandles.remove(peer.first)
                        awarePublishHandles.remove(peer.first)
                        awareReconnectScheduled.remove(peer.first)
                        emitWifiAware("candidateLost", peer.first, peer.second)
                    }
                },
                onError = { message ->
                    emitWifiAware("error", message = message)
                    stopWifiAware()
                }
            )
        } catch (e: Exception) {
            wifiAwareStarting = false
            result.error("WIFI_AWARE_ERROR", e.message ?: "تعذر تشغيل اكتشاف Wi-Fi المباشر", null)
            return
        }
        result.success(true)
    }

    /** Only user-selected NAN data-path control remains in the Activity.
     * HELLO/IDENTITY/PROOF are consumed exclusively by the service engine. */
    private fun handleWifiAwareHandshakeMessage(peerHandle: PeerHandle, session: DiscoverySession?, message: ByteArray) {
        if (session == null) return
        val incoming = String(message, Charsets.UTF_8)
        if (incoming.startsWith("BLOUSAB_CONNECT|")) {
            if (session !is PublishDiscoverySession) return
            val parts = incoming.split("|", limit = 3)
            if (parts.size == 3 && parts[1].isNotBlank() && wifiVerifiedPeerKeys.containsKey(parts[1]) &&
                wifiVerifiedPublishHandles[parts[1]] == peerHandle) {
                awareUserInitiatedPeers.add(parts[1])
                val peerName = wifiAwarePeers[peerHandle]?.second ?: "مستخدم بلوساب"
                if (Build.VERSION.SDK_INT >= 29) startWifiAwareServerDataPath(peerHandle, parts[1], peerName)
                else emitWifiAware("dataUnavailable", parts[1], peerName, "مسار بيانات Wi-Fi Aware يحتاج Android 10 أو أحدث")
            } else emitWifiAware("dataError", message = "رُفض طلب اتصال Wi-Fi غير موثق")
            return
        }
        if (incoming.startsWith("BLOUSAB_READY|")) {
            if (session !is SubscribeDiscoverySession) return
            val parts = incoming.split("|", limit = 2)
            val peer = wifiAwarePeers[peerHandle]
            if (parts.size == 2 && peer != null && parts[1] == peer.first &&
                awareUserInitiatedPeers.contains(peer.first) && wifiVerifiedSubscribeHandles[peer.first] == peerHandle) {
                startWifiAwareClientDataPath(peerHandle, peer.first, peer.second, session)
            }
        }
    }

    @Synchronized private fun markWifiAwareStarted() {
        if (wifiPublishSession != null && wifiSubscribeSession != null && !wifiAwareStarted) {
            wifiAwareStarted = true
            wifiAwareStarting = false
            emitWifiAware("started", message = "يتم بث إشارة بلوساب والبحث عن الأجهزة القريبة مباشرة")
        }
    }

    @android.annotation.TargetApi(29)
    private fun wifiAwarePassphrase(peerId: String, peerHandle: PeerHandle): String {
        val verifiedPeer = wifiAwarePeers[peerHandle]
        val passphrase = wifiPassphrases[peerId]
        if (verifiedPeer == null || verifiedPeer.first != peerId || passphrase.isNullOrBlank() ||
            wifiVerifiedSubscribeHandles[peerId] != peerHandle && wifiVerifiedPublishHandles[peerId] != peerHandle)
            throw SecurityException("مفتاح جلسة Wi-Fi غير مرتبط بطرف موثق")
        return passphrase.toString()
    }

    private fun sendWifiAwareConnectRequest(
        peerHandle: PeerHandle,
        peerId: String,
        peerName: String,
        subscribeSession: SubscribeDiscoverySession
    ) {
        if (!awareUserInitiatedPeers.contains(peerId) || !wifiVerifiedPeerKeys.containsKey(peerId) ||
            wifiVerifiedSubscribeHandles[peerId] != peerHandle ||
            awareNetworkCallbacks.containsKey(peerId) || awareSockets.containsKey(peerId) || !awareConnectRequests.add(peerId)) return
        try {
            val message = "BLOUSAB_CONNECT|$wifiAwareUserId|مستخدم بلوساب".toByteArray(Charsets.UTF_8)
            subscribeSession.sendMessage(peerHandle, (System.currentTimeMillis() and 0x7fffffff).toInt(), message)
            scheduleWifiAwareReconnect(peerId) // L2 discovery messages are short and may need retry.
        } catch (e: Exception) {
            awareConnectRequests.remove(peerId)
            emitWifiAware("dataError", peerId, peerName, e.message ?: "تعذر طلب اتصال Wi-Fi Aware")
            scheduleWifiAwareReconnect(peerId)
        }
    }

    @android.annotation.TargetApi(29)
    private fun startWifiAwareServerDataPath(peerHandle: PeerHandle, peerId: String, peerName: String) {
        val publishSession = wifiPublishSession
        if (publishSession == null || !awareUserInitiatedPeers.contains(peerId) ||
            !wifiVerifiedPeerKeys.containsKey(peerId) || wifiVerifiedPublishHandles[peerId] != peerHandle) return
        if (awareSockets.containsKey(peerId)) return
        if (awareNetworkCallbacks.containsKey(peerId)) {
            try { publishSession.sendMessage(peerHandle, (System.currentTimeMillis() and 0x7fffffff).toInt(),
                "BLOUSAB_READY|$wifiAwareUserId".toByteArray(Charsets.UTF_8)) } catch (_: Exception) {}
            return
        }
        if (!awareConnecting.add(peerId)) return
        val server = try { ServerSocket(0) } catch (e: Exception) {
            awareConnecting.remove(peerId)
            emitWifiAware("dataError", peerId, peerName, e.message ?: "تعذر فتح منفذ استقبال Wi-Fi Aware")
            return
        }
        awareServers[peerId] = server
        executor.execute {
            try {
                val socket = server.accept()
                attachWifiAwareSocket(peerId, peerName, socket)
            } catch (e: Exception) {
                if (!server.isClosed) {
                    emitWifiAware("dataError", peerId, peerName, e.message ?: "فشل استقبال اتصال Wi-Fi Aware")
                    closeWifiAwarePeer(peerId)
                    scheduleWifiAwareReconnect(peerId)
                }
            } finally {
                awareServers.remove(peerId)
                try { server.close() } catch (_: Exception) {}
            }
        }

        try {
            val specifier = WifiAwareNetworkSpecifier.Builder(publishSession, peerHandle)
                .setPskPassphrase(wifiAwarePassphrase(peerId, peerHandle))
                .setPort(server.localPort)
                .setTransportProtocol(6) // IANA IPPROTO_TCP; server-side only.
                .build()
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
                .setNetworkSpecifier(specifier)
                .build()
            val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    awareNetworks[peerId] = network
                    // The publisher owns the listening socket. The subscriber
                    // requests its side after receiving this short READY message.
                }
                override fun onUnavailable() {
                    closeWifiAwarePeer(peerId)
                    emitWifiAware("dataUnavailable", peerId, peerName, "تعذر إنشاء مسار بيانات Wi-Fi Aware")
                    scheduleWifiAwareReconnect(peerId)
                }
                override fun onLost(network: Network) {
                    closeWifiAwarePeer(peerId)
                    emitWifiAware("dataDisconnected", peerId, peerName, "انقطع اتصال Wi-Fi Aware")
                    scheduleWifiAwareReconnect(peerId)
                }
            }
            awareNetworkCallbacks[peerId] = callback
            connectivity.requestNetwork(request, callback, mainHandler)
            // Notify the subscriber to request its matching side of the NDP.
            publishSession.sendMessage(peerHandle, (System.currentTimeMillis() and 0x7fffffff).toInt(),
                "BLOUSAB_READY|$wifiAwareUserId".toByteArray(Charsets.UTF_8))
        } catch (e: Exception) {
            closeWifiAwarePeer(peerId)
            emitWifiAware("dataError", peerId, peerName, e.message ?: "تعذر طلب مسار بيانات Wi-Fi Aware")
            scheduleWifiAwareReconnect(peerId)
        }
    }

    @android.annotation.TargetApi(29)
    private fun startWifiAwareClientDataPath(
        peerHandle: PeerHandle,
        peerId: String,
        peerName: String,
        subscribeSession: SubscribeDiscoverySession
    ) {
        awareConnectRequests.remove(peerId)
        if (!awareUserInitiatedPeers.contains(peerId) || !wifiVerifiedPeerKeys.containsKey(peerId) ||
            wifiVerifiedSubscribeHandles[peerId] != peerHandle) return
        if (awareNetworkCallbacks.containsKey(peerId) || !awareConnecting.add(peerId)) return
        try {
            val specifier = WifiAwareNetworkSpecifier.Builder(subscribeSession, peerHandle)
                .setPskPassphrase(wifiAwarePassphrase(peerId, peerHandle))
                .build() // Client side: do not set the publisher's port.
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
                .setNetworkSpecifier(specifier)
                .build()
            val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    awareNetworks[peerId] = network
                }
                override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                    val info = networkCapabilities.transportInfo as? WifiAwareNetworkInfo ?: return
                    val address = info.peerIpv6Addr
                    val port = info.port
                    if (address == null || port !in 1..65535 || awareSockets.containsKey(peerId) || !awareSocketOpening.add(peerId)) return
                    executor.execute {
                        try {
                            val socket = network.socketFactory.createSocket(address, port)
                            attachWifiAwareSocket(peerId, peerName, socket)
                        } catch (e: Exception) {
                            awareSocketOpening.remove(peerId)
                            closeWifiAwarePeer(peerId)
                            emitWifiAware("dataError", peerId, peerName, e.message ?: "تعذر الاتصال بمنفذ Wi-Fi Aware")
                            scheduleWifiAwareReconnect(peerId)
                        }
                    }
                }
                override fun onUnavailable() {
                    closeWifiAwarePeer(peerId)
                    emitWifiAware("dataUnavailable", peerId, peerName, "تعذر إنشاء مسار بيانات Wi-Fi Aware")
                    scheduleWifiAwareReconnect(peerId)
                }
                override fun onLost(network: Network) {
                    closeWifiAwarePeer(peerId)
                    emitWifiAware("dataDisconnected", peerId, peerName, "انقطع اتصال Wi-Fi Aware")
                    scheduleWifiAwareReconnect(peerId)
                }
            }
            awareNetworkCallbacks[peerId] = callback
            connectivity.requestNetwork(request, callback, mainHandler)
        } catch (e: Exception) {
            closeWifiAwarePeer(peerId)
            emitWifiAware("dataError", peerId, peerName, e.message ?: "تعذر طلب مسار بيانات Wi-Fi Aware")
            scheduleWifiAwareReconnect(peerId)
        }
    }

    private fun scheduleWifiAwareReconnect(peerId: String) {
        if (!awareReconnectScheduled.add(peerId)) return
        val attempts = (awareRetryCounts[peerId] ?: 0) + 1
        awareRetryCounts[peerId] = attempts
        if (attempts > 3) {
            awareReconnectScheduled.remove(peerId)
            return
        }
        mainHandler.postDelayed({
            awareReconnectScheduled.remove(peerId)
            if (!wifiAwareStarted || !awareUserInitiatedPeers.contains(peerId) ||
                !wifiVerifiedPeerKeys.containsKey(peerId) || awareSockets.containsKey(peerId) ||
                awareNetworkCallbacks.containsKey(peerId)) return@postDelayed
            if (wifiAwareUserId.compareTo(peerId) < 0) {
                awareConnectRequests.remove(peerId)
                val handle = awareSubscribeHandles[peerId] ?: return@postDelayed
                val session = wifiSubscribeSession ?: return@postDelayed
                sendWifiAwareConnectRequest(handle, peerId, "مستخدم بلوساب", session)
            } else {
                val handle = awarePublishHandles[peerId] ?: return@postDelayed
                startWifiAwareServerDataPath(handle, peerId, "مستخدم بلوساب")
            }
        }, 2500L)
    }

    /**
     * Registers a connected Wi-Fi Aware TCP socket and continuously receives
     * length-prefixed UTF-8 packets from the remote Blousab client.
     */
    private fun attachWifiAwareSocket(peerId: String, peerName: String, socket: Socket) {
        if (!awareUserInitiatedPeers.contains(peerId) || !wifiVerifiedPeerKeys.containsKey(peerId)) {
            try { socket.close() } catch (_: Exception) {}
            emitWifiAware("dataError", peerId, peerName, "رُفض مقبس Wi-Fi غير مرتبط بهوية موثقة ومختارة")
            return
        }
        try {
            socket.tcpNoDelay = true
            socket.keepAlive = true
            // Replace any stale connection for this peer before publishing the new one.
            closeWifiAwareSocketOnly(peerId)
            val input = DataInputStream(socket.getInputStream())
            val output = DataOutputStream(socket.getOutputStream())
            awareSockets[peerId] = socket
            awareWriters[peerId] = output
            awareConnecting.remove(peerId)
            awareSocketOpening.remove(peerId)
            awareRetryCounts.remove(peerId)
            emitWifiAware("dataConnected", peerId, peerName, "اتصل الجهاز عبر Wi-Fi Aware")

            executor.execute {
                try {
                    while (!socket.isClosed) {
                        val packetLength = input.readInt()
                        if (packetLength <= 0 || packetLength > awareMaxPacketBytes) {
                            throw java.io.IOException("حجم حزمة Wi-Fi Aware غير صالح")
                        }
                        val packet = ByteArray(packetLength)
                        input.readFully(packet)
                        val clearPacket = backgroundRuntime?.decryptWifiAwarePacket(peerId, packet) ?: throw IllegalStateException("خدمة Wi-Fi Aware غير متاحة")
                        emitWifiAware("dataPacket", peerId, peerName, clearPacket)
                    }
                } catch (e: Exception) {
                    if (!socket.isClosed) {
                        emitWifiAware("dataDisconnected", peerId, peerName,
                            e.message ?: "انقطع اتصال Wi-Fi Aware")
                    }
                } finally {
                    if (awareSockets[peerId] === socket) {
                        closeWifiAwareSocketOnly(peerId)
                        awareConnecting.remove(peerId)
                        awareSocketOpening.remove(peerId)
                        if (wifiAwareStarted) scheduleWifiAwareReconnect(peerId)
                    } else {
                        try { socket.close() } catch (_: Exception) {}
                    }
                }
            }
        } catch (e: Exception) {
            awareConnecting.remove(peerId)
            awareSocketOpening.remove(peerId)
            try { socket.close() } catch (_: Exception) {}
            emitWifiAware("dataError", peerId, peerName,
                e.message ?: "تعذر تهيئة قناة بيانات Wi-Fi Aware")
        }
    }

    private fun sendWifiAwarePacket(peerId: String, payload: String) {
        val output = awareWriters[peerId] ?: throw IllegalStateException("لا توجد قناة Wi-Fi Aware جاهزة لهذا الجهاز")
        // Encryption and TCP write share one lock so counter order always matches
        // the byte order observed by the receiver, even with concurrent senders.
        synchronized(output) {
            val bytes = backgroundRuntime?.encryptWifiAwarePacket(peerId, payload) ?: throw IllegalStateException("خدمة Wi-Fi Aware غير متاحة")
            if (bytes.isEmpty() || bytes.size > awareMaxPacketBytes) throw IllegalArgumentException("حجم الحزمة المشفرة يتجاوز الحد المسموح")
            output.writeInt(bytes.size)
            output.write(bytes)
            output.flush()
        }
    }

    private fun closeWifiAwareSocketOnly(peerId: String) {
        awareWriters.remove(peerId)
        try { awareSockets.remove(peerId)?.close() } catch (_: Exception) {}
    }

    private fun closeWifiAwarePeer(peerId: String) {
        closeWifiAwareSocketOnly(peerId)
        try { awareServers.remove(peerId)?.close() } catch (_: Exception) {}
        awareNetworks.remove(peerId)
        awareConnecting.remove(peerId)
        awareSocketOpening.remove(peerId)
        awareConnectRequests.remove(peerId)
        val callback = awareNetworkCallbacks.remove(peerId)
        if (callback != null) {
            try { (getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).unregisterNetworkCallback(callback) } catch (_: Exception) {}
        }
    }

    private fun stopWifiAware() {
        wifiAwareStarted = false
        wifiAwareStarting = false
        try { backgroundRuntime?.stopWifiAware() } catch (_: Exception) {}
        wifiPublishSession = null
        wifiSubscribeSession = null
        wifiAwarePeers.clear()
        wifiPassphrases.clear()
        wifiVerifiedPeerKeys.clear()
        wifiVerifiedSubscribeHandles.clear()
        wifiVerifiedPublishHandles.clear()
        awareRetryCounts.clear()
        awareSubscribeHandles.clear()
        awarePublishHandles.clear()
        awareSocketOpening.clear()
        awareConnectRequests.clear()
        awareUserInitiatedPeers.clear()
        awareReconnectScheduled.clear()
        awareNetworkCallbacks.keys.toList().forEach { closeWifiAwarePeer(it) }
        awareSockets.keys.toList().forEach { closeWifiAwarePeer(it) }
        wifiAwareSession = null
        emitWifiAware("stopped")
    }

    private fun hasConnectPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasScanPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasAdvertisePermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_ADVERTISE) ==
            PackageManager.PERMISSION_GRANTED

    private fun startDiscovery(result: MethodChannel.Result) {
        val bluetooth = adapter
        if (bluetooth == null || !bluetooth.isEnabled) {
            result.error("BLUETOOTH_OFF", "شغّل البلوتوث أولاً", null)
            return
        }
        try {
            try { bluetooth.cancelDiscovery() } catch (_: Exception) {}
            discoveryReceiver?.let {
                try { unregisterReceiver(it) } catch (_: Exception) {}
            }
            discovered.clear()
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action != BluetoothDevice.ACTION_FOUND) return
                    @Suppress("DEPRECATION")
                    val device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE) as? BluetoothDevice ?: return
                    try {
                        val address = device.address ?: return
                        val name = try { device.name ?: "جهاز بلوتوث" } catch (_: SecurityException) { "جهاز بلوتوث" }
                        discovered[address] = device
                        emit("deviceFound", address, name)
                    } catch (_: SecurityException) { }
                }
            }
            discoveryReceiver = receiver
            val filter = IntentFilter(BluetoothDevice.ACTION_FOUND)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(receiver, filter)
            }
            val started = bluetooth.startDiscovery()
            if (!started) {
                try { unregisterReceiver(receiver) } catch (_: Exception) {}
                discoveryReceiver = null
                result.error("DISCOVERY_FAILED", "تعذر بدء البحث عن أجهزة قريبة", null)
            } else result.success(true)
        } catch (e: Exception) {
            result.error("DISCOVERY_FAILED", e.message ?: "تعذر البحث عن الأجهزة", null)
        }
    }

    private fun emit(type: String, address: String? = null, name: String? = null, message: String? = null) {
        val event = mutableMapOf<String, Any>("type" to type)
        address?.let { event["address"] = it }
        name?.let { event["name"] = it }
        message?.let { event["message"] = it }
        mainHandler.post { eventSink?.success(event) }
    }

    private fun startServer(result: MethodChannel.Result) {
        val bluetooth = adapter
        if (bluetooth == null) {
            result.error("UNSUPPORTED", "هذا الجهاز لا يدعم البلوتوث", null)
            return
        }
        if (!bluetooth.isEnabled) {
            result.error("BLUETOOTH_OFF", "شغّل البلوتوث أولاً", null)
            return
        }
        if (!serverRunning.compareAndSet(false, true)) {
            result.success(true)
            return
        }
        try {
            // The foreground host owns the RFCOMM listener, candidate verification,
            // shared handshake coordinator, and encrypted peer session I/O.
            // Flutter supplies the existing identity envelope and narrow signer callback.
            val intent = Intent(this, BlousabBackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ContextCompat.startForegroundService(this, intent)
            else startService(intent)
            if (!backgroundRuntimeBound) {
                backgroundRuntimeBound = bindService(intent, backgroundRuntimeConnection, Context.BIND_AUTO_CREATE)
            }
            val runtime = backgroundRuntime
            if (runtime != null) {
                runtime.startBluetoothListener(
                    onAccepted = { socket -> runtime.authenticateIncomingSocket(socket) },
                    onError = { message -> emit("serverError", message = message); serverRunning.set(false) }
                )
                emit("serverStarted")
                result.success(true)
            } else {
                // onServiceConnected completes the listener start asynchronously.
                mainHandler.postDelayed({
                    val connectedRuntime = backgroundRuntime
                    if (connectedRuntime != null && serverRunning.get()) {
                        connectedRuntime.startBluetoothListener(
                            onAccepted = { socket -> connectedRuntime.authenticateIncomingSocket(socket) },
                            onError = { message -> emit("serverError", message = message); serverRunning.set(false) }
                        )
                        emit("serverStarted")
                        result.success(true)
                    } else {
                        serverRunning.set(false)
                        result.error("BACKGROUND_BIND", "تعذر ربط خدمة استقبال Bluetooth", null)
                    }
                }, 350)
            }
        } catch (e: Exception) {
            serverRunning.set(false)
            result.error("SERVER_START", e.message ?: "تعذر تشغيل استقبال Bluetooth", null)
        }
    }

    /**
     * Verifies a scan result using a short-lived RFCOMM socket. This is discovery
     * only: unlike connect(), the socket is always closed and is never registered
     * as a chat/data connection.
     */
    private fun publicKeyFingerprint(publicKeyBase64: String): String {
        val rawKey = android.util.Base64.decode(publicKeyBase64, android.util.Base64.DEFAULT)
        require(rawKey.size == 32) { "مفتاح Ed25519 غير صالح" }
        val hex = MessageDigest.getInstance("SHA-256").digest(rawKey)
            .joinToString("") { "%02x".format(it) }
        return hex
    }

    private fun verifyEd25519(publicKeyBase64: String, payload: ByteArray, signatureBase64: String): Boolean {
        return try {
            if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
                Security.addProvider(BouncyCastleProvider())
            }
            val rawKey = android.util.Base64.decode(publicKeyBase64, android.util.Base64.DEFAULT)
            val sigBytes = android.util.Base64.decode(signatureBase64, android.util.Base64.DEFAULT)
            if (rawKey.size != 32 || sigBytes.size != 64) return false
            // RFC 8410 SubjectPublicKeyInfo prefix for a raw Ed25519 public key.
            val prefix = byteArrayOf(0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00)
            val encoded = prefix + rawKey
            val key = KeyFactory.getInstance("Ed25519", "BC").generatePublic(X509EncodedKeySpec(encoded))
            val verifier = Signature.getInstance("Ed25519", "BC")
            verifier.initVerify(key)
            verifier.update(payload)
            verifier.verify(sigBytes)
        } catch (_: Exception) { false }
    }

    private data class VerifiedBlousabIdentity(val userId: String, val userName: String, val photo: String, val publicKey: String, val discoveryOnly: Boolean = false)

    private fun parseSignedBlousabHello(line: String): VerifiedBlousabIdentity {
        val parts = line.split("|")
        if (parts.size != 3 || parts[0] != "BLUSAB_HELLO" || parts[1] != "2") {
            throw IllegalStateException("الجهاز لا يدعم مصافحة بلوساب الموقعة")
        }
        val envelopeBytes = android.util.Base64.decode(parts[2], android.util.Base64.NO_WRAP or android.util.Base64.URL_SAFE)
        val envelope = JSONObject(String(envelopeBytes, Charsets.UTF_8))
        val payloadEncoded = envelope.getString("payload")
        val signature = envelope.getString("signature")
        val publicKey = envelope.getString("publicKey")
        val payloadBytes = android.util.Base64.decode(payloadEncoded, android.util.Base64.DEFAULT)
        if (!verifyEd25519(publicKey, payloadBytes, signature)) {
            throw SecurityException("توقيع هوية بلوساب غير صحيح")
        }
        val payload = JSONObject(String(payloadBytes, Charsets.UTF_8))
        if (payload.optString("type") != "blousab_discovery_identity" ||
            payload.optInt("version") != 2 || payload.optString("publicKey") != publicKey) {
            throw SecurityException("بنية هوية بلوساب غير صالحة")
        }
        val id = payload.optString("userId").trim()
        if (id.isEmpty()) throw SecurityException("معرّف مستخدم بلوساب فارغ")
        return VerifiedBlousabIdentity(id, payload.optString("userName", "مستخدم بلوساب"), payload.optString("profilePhoto", ""), publicKey)
    }

    /** Ask the Dart identity service to sign a fresh transcript with the same
     * Ed25519 key used by QR/LAN. The worker waits while Flutter handles the
     * callback on the main thread; no UI thread is blocked. */
    private fun signHandshakeTranscript(text: String): String {
        val latch = CountDownLatch(1)
        var signature = ""
        mainHandler.post {
            val channel = bluetoothMethodChannel
            if (channel == null) {
                latch.countDown()
            } else {
                channel.invokeMethod("signHandshakeTranscript", mapOf("text" to text), object : MethodChannel.Result {
                    override fun success(result: Any?) { signature = result?.toString() ?: ""; latch.countDown() }
                    override fun error(code: String, message: String?, details: Any?) { latch.countDown() }
                    override fun notImplemented() { latch.countDown() }
                })
            }
        }
        if (!latch.await(7, TimeUnit.SECONDS) || signature.isBlank()) {
            throw SecurityException("تعذر توقيع تحدي المصافحة بهوية بلوساب")
        }
        return signature
    }

    private fun readProtocolLine(reader: BufferedReader, label: String): String =
        reader.readLine() ?: throw SecurityException("انقطع الاتصال أثناء $label")

    /** Symmetric nonce challenge-response. Both peers send identity, exchange
     * independent 256-bit nonces, then sign the same canonical transcript. */
    private data class BluetoothSessionCrypto(
        val localId: String,
        val peerId: String,
        val sendKey: ByteArray,
        val receiveKey: ByteArray,
        val sendPrefix: ByteArray,
        val receivePrefix: ByteArray,
        var sendCounter: Long = 0L,
        var receiveCounter: Long = 0L
    ) {
        @Synchronized fun encrypt(plainText: String): String {
            if (sendCounter == Long.MAX_VALUE) throw SecurityException("انتهى عداد تشفير Bluetooth؛ أعد الاتصال")
            val nonce = ByteBuffer.allocate(12).put(sendPrefix).putLong(sendCounter).array()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(sendKey, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD("blousab-bluetooth-frame-v2|$localId|$peerId".toByteArray(Charsets.UTF_8))
            val encrypted = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
            sendCounter++
            return JSONObject().put("type", "blousab_bt_secure_frame_v2")
                .put("nonce", android.util.Base64.encodeToString(nonce, android.util.Base64.NO_WRAP))
                .put("cipherText", android.util.Base64.encodeToString(encrypted, android.util.Base64.NO_WRAP)).toString()
        }

        @Synchronized fun decrypt(frame: String): String {
            val obj = JSONObject(frame)
            if (obj.optString("type") != "blousab_bt_secure_frame_v2") throw SecurityException("إطار Bluetooth غير مشفر أو بإصدار غير مدعوم")
            val nonce = android.util.Base64.decode(obj.getString("nonce"), android.util.Base64.DEFAULT)
            val encrypted = android.util.Base64.decode(obj.getString("cipherText"), android.util.Base64.DEFAULT)
            if (nonce.size != 12) throw SecurityException("Nonce Bluetooth غير صالح")
            val buffer = ByteBuffer.wrap(nonce)
            val prefix = ByteArray(4).also { buffer.get(it) }
            val counter = buffer.long
            if (!prefix.contentEquals(receivePrefix) || counter != receiveCounter || counter < 0L)
                throw SecurityException("عداد Bluetooth غير صحيح أو حزمة مكررة")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(receiveKey, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD("blousab-bluetooth-frame-v2|$peerId|$localId".toByteArray(Charsets.UTF_8))
            val clear = cipher.doFinal(encrypted)
            receiveCounter++
            return String(clear, Charsets.UTF_8)
        }

        fun destroy() {
            java.util.Arrays.fill(sendKey, 0); java.util.Arrays.fill(receiveKey, 0)
            java.util.Arrays.fill(sendPrefix, 0); java.util.Arrays.fill(receivePrefix, 0)
            sendCounter = 0L; receiveCounter = 0L
        }
    }

    private data class AuthenticatedBluetoothPeer(
        val identity: VerifiedBlousabIdentity,
        val crypto: BluetoothSessionCrypto
    )

    private fun hkdfSha256Bluetooth(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        val out = java.io.ByteArrayOutputStream()
        var previous = byteArrayOf()
        var counter = 1
        while (out.size() < length) {
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(previous); mac.update(info); mac.update(counter.toByte())
            previous = mac.doFinal(); out.write(previous); counter++
        }
        java.util.Arrays.fill(prk, 0); java.util.Arrays.fill(previous, 0)
        return out.toByteArray().copyOf(length)
    }

    /** Identity + mutual nonce + ephemeral X25519 proof. The resulting directional
     * AES-GCM keys are bound to both identities and this fresh transcript. */
    private fun performAuthenticatedHandshake(
        writer: PrintWriter,
        reader: BufferedReader,
        localDiscoveryOnly: Boolean
    ): AuthenticatedBluetoothPeer {
        val localHello = bluetoothBlousabIdentity
        if (localHello.isBlank()) throw IllegalStateException("هوية بلوساب المحلية غير مهيأة")
        val localMode = if (localDiscoveryOnly) "DISCOVERY" else "SESSION"
        writer.println("BLUSAB_MODE|1|$localMode"); writer.flush()
        val peerModeParts = readProtocolLine(reader, "تحديد غرض الاتصال").split("|")
        if (peerModeParts.size != 3 || peerModeParts[0] != "BLUSAB_MODE" || peerModeParts[1] != "1" ||
            peerModeParts[2] !in setOf("DISCOVERY", "SESSION")) throw SecurityException("غرض اتصال بلوساب غير صالح")
        writer.println(localHello); writer.flush()
        val peer = parseSignedBlousabHello(readProtocolLine(reader, "تبادل الهوية"))

        val localId = bluetoothBlousabUserId
        if (localId.isBlank() || localId == peer.userId) throw SecurityException("معرّف مستخدم بلوساب غير صالح")
        val localNonceBytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val localNonce = android.util.Base64.encodeToString(localNonceBytes, android.util.Base64.NO_WRAP or android.util.Base64.URL_SAFE)
        val localEphemeralPrivate = X25519PrivateKeyParameters(SecureRandom())
        val localEphemeralPublic = localEphemeralPrivate.generatePublicKey().encoded
        val localEphemeral = android.util.Base64.encodeToString(localEphemeralPublic, android.util.Base64.NO_WRAP)
        writer.println("BLUSAB_CHALLENGE|2|$localNonce|$localEphemeral"); writer.flush()

        val challenge = readProtocolLine(reader, "تحدي X25519 للطرف الآخر").split("|")
        if (challenge.size != 4 || challenge[0] != "BLUSAB_CHALLENGE" || challenge[1] != "2")
            throw SecurityException("تحدي Bluetooth غير صالح")
        val peerNonce = challenge[2]
        val peerNonceBytes = try { android.util.Base64.decode(peerNonce, android.util.Base64.NO_WRAP or android.util.Base64.URL_SAFE) } catch (_: Exception) { byteArrayOf() }
        val peerEphemeral = try { android.util.Base64.decode(challenge[3], android.util.Base64.DEFAULT) } catch (_: Exception) { byteArrayOf() }
        if (peerNonceBytes.size != 32 || peerEphemeral.size != 32 || localNonce == peerNonce)
            throw SecurityException("قيم تحدي X25519 غير صالحة")

        data class Side(val id: String, val nonce: String, val ephemeral: String)
        val sides = listOf(Side(localId, localNonce, localEphemeral), Side(peer.userId, peerNonce, challenge[3])).sortedBy { it.id }
        val transcript = "BLUSAB_X25519_PROOF|2|${sides[0].id}|${sides[0].nonce}|${sides[0].ephemeral}|${sides[1].id}|${sides[1].nonce}|${sides[1].ephemeral}"
        val localSignature = signHandshakeTranscript(transcript)
        writer.println("BLUSAB_PROOF|2|$localSignature"); writer.flush()
        val response = readProtocolLine(reader, "إثبات مفتاح X25519 للطرف الآخر").split("|")
        if (response.size != 3 || response[0] != "BLUSAB_PROOF" || response[1] != "2" ||
            !verifyEd25519(peer.publicKey, transcript.toByteArray(Charsets.UTF_8), response[2]))
            throw SecurityException("فشل توقيع مفاتيح جلسة Bluetooth")

        val agreement = X25519Agreement()
        agreement.init(localEphemeralPrivate)
        val shared = ByteArray(agreement.agreementSize)
        agreement.calculateAgreement(X25519PublicKeyParameters(peerEphemeral, 0), shared, 0)
        if (shared.all { it == 0.toByte() }) throw SecurityException("سر X25519 غير صالح")
        val salt = MessageDigest.getInstance("SHA-256").digest(transcript.toByteArray(Charsets.UTF_8))
        val sendMaterial = hkdfSha256Bluetooth(shared, salt, "blousab-bt-v2|$localId|${peer.userId}".toByteArray(), 36)
        val receiveMaterial = hkdfSha256Bluetooth(shared, salt, "blousab-bt-v2|${peer.userId}|$localId".toByteArray(), 36)
        java.util.Arrays.fill(shared, 0)
        val crypto = BluetoothSessionCrypto(localId, peer.userId,
            sendMaterial.copyOfRange(0, 32), receiveMaterial.copyOfRange(0, 32),
            sendMaterial.copyOfRange(32, 36), receiveMaterial.copyOfRange(32, 36))
        java.util.Arrays.fill(sendMaterial, 0); java.util.Arrays.fill(receiveMaterial, 0)
        return AuthenticatedBluetoothPeer(peer.copy(discoveryOnly = localDiscoveryOnly || peerModeParts[2] == "DISCOVERY"), crypto)
    }

    private fun connect(address: String, result: MethodChannel.Result) {
        val runtime = backgroundRuntime
        if (runtime == null) {
            result.error("BACKGROUND_RUNTIME", "خدمة بلوساب الخلفية غير جاهزة؛ أعد المحاولة بعد لحظة", null)
            return
        }
        if (bluetoothBlousabIdentity.isBlank() || bluetoothBlousabUserId.isBlank()) {
            result.error("IDENTITY", "هوية بلوساب غير مهيأة؛ أعد فتح التطبيق", null)
            return
        }
        runtime.configureBluetoothHandshake(bluetoothBlousabIdentity, bluetoothBlousabUserId) { text -> signHandshakeTranscript(text) }
        runtime.connectAuthenticatedPeer(address) { success, message ->
            mainHandler.post {
                if (success) result.success(true)
                else result.error("CONNECT_FAILED", message ?: "تعذر الاتصال بمستخدم بلوساب", null)
            }
        }
    }

    // Legacy Activity-owned session path retained temporarily for source compatibility;
    // normal user-initiated connections now route through BlousabBackgroundService.
    private fun registerPeer(socket: BluetoothSocket) {
        val address = socket.remoteDevice.address
        var pendingCrypto: BluetoothSessionCrypto? = null
        // A Bluetooth RFCOMM connection is only a transport candidate. Require a
        // reciprocal Blousab protocol handshake before exposing it as connected.
        try {
            val localIdentity = bluetoothBlousabIdentity
            if (localIdentity.isBlank()) throw IllegalStateException("هوية بلوساب غير مهيأة؛ أعد فتح التطبيق")
            val writer = PrintWriter(OutputStreamWriter(socket.outputStream, Charsets.UTF_8), true)
            val reader = BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
            val authenticated = performAuthenticatedHandshake(writer, reader, localDiscoveryOnly = false)
            val peerIdentity = authenticated.identity
            pendingCrypto = authenticated.crypto
            val peerId = peerIdentity.userId
            if (peerIdentity.discoveryOnly) {
                val discoveredEvent = mutableMapOf<String, Any>(
                    "type" to "blousabVerified", "address" to address,
                    "userId" to peerId, "userName" to peerIdentity.userName,
                    "profilePhoto" to peerIdentity.photo, "publicKey" to peerIdentity.publicKey, "discoveryOnly" to true
                )
                mainHandler.post {
                    val sink = eventSink
                    if (sink != null) sink.success(discoveredEvent)
                    else {
                        if (pendingBluetoothEvents.size >= 100) pendingBluetoothEvents.poll()
                        pendingBluetoothEvents.offer(discoveredEvent)
                    }
                }
                pendingCrypto?.destroy(); pendingCrypto = null
                try { socket.close() } catch (_: Exception) {}
                return
            }
            val peerName = peerIdentity.userName
            val peerPhoto = peerIdentity.photo
            // Keep one socket per physical address to avoid duplicate writers/connections.
            closePeer(address, notify = false)
            sockets[address] = socket
            writers[address] = writer
            bluetoothSessionCryptos.put(address, pendingCrypto!!)?.destroy()
            pendingCrypto = null
            val verified = mutableMapOf<String, Any>("type" to "blousabVerified", "address" to address,
                "userId" to peerId, "userName" to peerName, "profilePhoto" to peerPhoto, "publicKey" to peerIdentity.publicKey)
            mainHandler.post {
                val sink = eventSink
                if (sink != null) sink.success(verified)
                else {
                    if (pendingBluetoothEvents.size >= 100) pendingBluetoothEvents.poll()
                    pendingBluetoothEvents.offer(verified)
                }
            }
            emit("connected", address, peerName)
            val runtime = backgroundRuntime
            if (runtime != null) {
                val sessionCrypto = pendingCrypto ?: bluetoothSessionCryptos[address]
                    ?: throw SecurityException("مفتاح جلسة Bluetooth مفقود")
                runtime.attachSessionEventConsumer { event -> dispatchServiceSessionEvent(event) }
                serviceManagedBluetoothAddresses.add(address)
                runtime.adoptAuthenticatedPeer(
                    address = address,
                    userName = peerName,
                    socket = socket,
                    reader = reader,
                    writer = writer,
                    encrypt = { clear -> sessionCrypto.encrypt(clear) },
                    decrypt = { frame -> sessionCrypto.decrypt(frame) },
                    onClosed = {
                        if (bluetoothSessionCryptos[address] === sessionCrypto) {
                            bluetoothSessionCryptos.remove(address, sessionCrypto)
                            sessionCrypto.destroy()
                        }
                        if (writers[address] === writer) writers.remove(address, writer)
                        if (sockets[address] === socket) {
                            sockets.remove(address, socket)
                            serviceManagedBluetoothAddresses.remove(address)
                        }
                    }
                )
            } else {
                executor.execute {
                    try {
                        while (true) {
                            val line = reader.readLine() ?: break
                            val crypto = bluetoothSessionCryptos[address] ?: throw SecurityException("مفتاح جلسة Bluetooth مفقود")
                            val clear = crypto.decrypt(line)
                            emit("message", address, peerName, clear)
                        }
                    } catch (e: Exception) {
                        emit("connectionError", address, message = e.message ?: "انقطع الاتصال")
                    } finally {
                        if (sockets[address] === socket) closePeer(address)
                        else try { socket.close() } catch (_: Exception) {}
                    }
                }
            }
        } catch (e: Exception) {
            pendingCrypto?.destroy()
            bluetoothSessionCryptos.remove(address)?.destroy()
            writers.remove(address)
            sockets.remove(address)
            serviceManagedBluetoothAddresses.remove(address)
            try { socket.close() } catch (_: Exception) {}
            emit("unverifiedDevice", address, message = e.message ?: "لم تثبت هوية بلوساب؛ تم تجاهل الجهاز")
        }
    }

    private fun closePeer(address: String, notify: Boolean = true) {
        serviceManagedBluetoothAddresses.remove(address)
        writers.remove(address)
        bluetoothSessionCryptos.remove(address)?.destroy()
        try { sockets.remove(address)?.close() } catch (_: Exception) {}
        if (notify) emit("disconnected", address)
    }

    private fun closeAll() {
        sockets.keys.toList().forEach { closePeer(it) }
    }

    private fun stopServer() {
        serverRunning.set(false)
        backgroundRuntime?.stopBluetoothListener()
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        closeAll()
        emit("serverStopped")
    }

    override fun onDestroy() {
        stopWifiAware()
        // Keep the service-owned RFCOMM accept loop alive across Activity
        // recreation. Detach only this Activity's callback; the service queues a
        // small bounded number of accepted sockets until a new host reattaches.
        backgroundRuntime?.detachBluetoothListenerConsumer()
        backgroundRuntime?.clearBluetoothHandshake()
        backgroundRuntime?.detachSessionEventConsumer()
        // Authenticated sessions adopted by the service survive Activity recreation.
        // Any fallback-only sockets still owned by this Activity must be closed.
        sockets.keys.toList().filterNot { serviceManagedBluetoothAddresses.contains(it) }
            .forEach { closePeer(it, notify = false) }
        if (backgroundRuntimeBound) {
            try { unbindService(backgroundRuntimeConnection) } catch (_: Exception) {}
            backgroundRuntimeBound = false
        }
        try { adapter?.cancelDiscovery() } catch (_: Exception) {}
        discoveryReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        discoveryReceiver = null
        executor.shutdownNow()
        super.onDestroy()
    }
}
