package com.plosap.myapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareSession
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.os.Handler
import android.os.Looper
import android.content.ComponentName
import android.content.ServiceConnection
import android.os.Binder
import android.content.Intent
import android.os.Build
import android.os.IBinder
import java.util.UUID
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import androidx.core.app.NotificationCompat

/**
 * Foreground runtime host. It owns the RFCOMM listener and authenticated live
 * socket I/O and both inbound/outbound signed Blousab handshakes across Activity
 * recreation. Flutter supplies the public identity envelope and signing callback.
 */
class BlousabBackgroundService : Service() {
    companion object {
        const val CHANNEL_ID = "blousab_background_runtime"
        const val NOTIFICATION_ID = 7318
        const val ACTION_STOP = "com.plosap.myapp.action.STOP_BACKGROUND_RUNTIME"
    }

    private val runtimeBinder = RuntimeBinder()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var wifiAwareSession: WifiAwareSession? = null
    @Volatile private var wifiPublishSession: PublishDiscoverySession? = null
    @Volatile private var wifiSubscribeSession: SubscribeDiscoverySession? = null
    @Volatile private var wifiAwareStarting = false
    @Volatile private var wifiHandshakeEngine: BlousabWifiAwareHandshakeEngine? = null
    @Volatile private var wifiVerifiedCallback: ((PeerHandle, DiscoverySession, BlousabWifiPeerIdentity, String, ByteArray, ByteArray, ByteArray, ByteArray) -> Unit)? = null
    @Volatile private var wifiHandshakeFailureCallback: ((PeerHandle, String) -> Unit)? = null
    @Volatile private var wifiPacketLocalUserId: String = ""
    private val wifiPacketMaxBytes = 1024 * 1024
    private val wifiPacketMagic = byteArrayOf(0x42, 0x53, 0x41, 0x45) // BSAE
    private data class WifiPacketCrypto(
        val sendKey: ByteArray, val receiveKey: ByteArray,
        val sendPrefix: ByteArray, val receivePrefix: ByteArray,
        var sendCounter: Long = 0L, var receiveCounter: Long = 0L
    ) {
        fun destroy() {
            java.util.Arrays.fill(sendKey, 0); java.util.Arrays.fill(receiveKey, 0)
            java.util.Arrays.fill(sendPrefix, 0); java.util.Arrays.fill(receivePrefix, 0)
            sendCounter = 0L; receiveCounter = 0L
        }
    }
    private val wifiPacketCryptos = ConcurrentHashMap<String, WifiPacketCrypto>()
    private val listenerExecutor = Executors.newSingleThreadExecutor()
    private val peerIoExecutor = Executors.newCachedThreadPool()
    private data class ManagedPeer(
        val address: String,
        val userName: String,
        val socket: BluetoothSocket,
        val writer: PrintWriter,
        val encrypt: (String) -> String,
        val decrypt: (String) -> String,
        val onClosed: () -> Unit,
        val closed: AtomicBoolean = AtomicBoolean(false)
    )
    private val managedPeers = ConcurrentHashMap<String, ManagedPeer>()
    private val candidateVerifications = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var sessionEventCallback: ((Map<String, Any>) -> Unit)? = null
    // Events remain pending until Flutter acknowledges their eventId. This is
    // at-least-once delivery across Activity/engine reattachment, bounded to 200.
    private val pendingSessionEvents = java.util.LinkedHashMap<Long, Map<String, Any>>()
    private val sessionEventSequence = AtomicLong(System.nanoTime())
    private val maxPendingSessionEvents = 200
    private val serverRunning = AtomicBoolean(false)
    @Volatile private var bluetoothServerSocket: BluetoothServerSocket? = null
    @Volatile private var acceptedSocketCallback: ((BluetoothSocket) -> Unit)? = null
    @Volatile private var listenerErrorCallback: ((String) -> Unit)? = null
    private val pendingAcceptedSockets = ConcurrentLinkedQueue<BluetoothSocket>()
    private val maxPendingAcceptedSockets = 8
    @Volatile private var handshakeHello: String = ""
    @Volatile private var handshakeUserId: String = ""
    @Volatile private var transcriptSigner: ((String) -> String)? = null


    /** Configure the service-owned Wi-Fi Aware mutual handshake. Flutter provides
     * the existing signed public envelope and a narrow Ed25519 signer callback;
     * private key material never enters this service. */
    internal fun configureWifiAwareHandshake(
        localHello: String,
        localUserId: String,
        signer: (String) -> String,
        onVerified: (PeerHandle, DiscoverySession, BlousabWifiPeerIdentity, String, ByteArray, ByteArray, ByteArray, ByteArray) -> Unit,
        onFailure: (PeerHandle, String) -> Unit
    ) {
        require(localHello.startsWith("BLUSAB_HELLO|2|") && localUserId.isNotBlank())
        wifiHandshakeEngine?.clear()
        wifiPacketLocalUserId = localUserId
        wifiVerifiedCallback = onVerified
        wifiHandshakeFailureCallback = onFailure
        wifiHandshakeEngine = BlousabWifiAwareHandshakeEngine(localHello, localUserId, signer,
            { peer, session, identity, passphrase, sendKey, receiveKey, sendPrefix, receivePrefix ->
                wifiVerifiedCallback?.invoke(peer, session, identity, passphrase, sendKey, receiveKey, sendPrefix, receivePrefix)
            },
            { peer, message -> wifiHandshakeFailureCallback?.invoke(peer, message) })
    }

    /** The foreground service owns the live Wi-Fi packet keys and AES-GCM counters.
     * Only derived session keys are accepted; the long-term private identity key stays in Flutter secure storage. */
    fun installWifiAwarePacketKeys(peerId: String, sendKey: ByteArray, receiveKey: ByteArray,
                                   sendPrefix: ByteArray, receivePrefix: ByteArray) {
        require(peerId.isNotBlank() && sendKey.size == 32 && receiveKey.size == 32 &&
            sendPrefix.size == 4 && receivePrefix.size == 4 && wifiPacketLocalUserId.isNotBlank())
        wifiPacketCryptos.put(peerId, WifiPacketCrypto(sendKey.copyOf(), receiveKey.copyOf(),
            sendPrefix.copyOf(), receivePrefix.copyOf()))?.destroy()
    }

    fun removeWifiAwarePacketKeys(peerId: String) { wifiPacketCryptos.remove(peerId)?.destroy() }

    fun encryptWifiAwarePacket(peerId: String, payload: String): ByteArray {
        val crypto = wifiPacketCryptos[peerId] ?: throw SecurityException("مفتاح تشفير جلسة Wi-Fi غير متاح")
        val clear = payload.toByteArray(Charsets.UTF_8)
        if (clear.isEmpty() || clear.size > wifiPacketMaxBytes - 64) throw IllegalArgumentException("حجم الحزمة يتجاوز الحد المسموح")
        synchronized(crypto) {
            if (crypto.sendCounter == Long.MAX_VALUE) throw SecurityException("انتهى عداد تشفير جلسة Wi-Fi؛ أعد المصافحة")
            val nonce = ByteBuffer.allocate(12).put(crypto.sendPrefix).putLong(crypto.sendCounter).array()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(crypto.sendKey, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD("blousab-wifi-aware-packet-v1|${wifiPacketLocalUserId}|$peerId".toByteArray(Charsets.UTF_8))
            val encrypted = cipher.doFinal(clear)
            crypto.sendCounter++
            return ByteBuffer.allocate(wifiPacketMagic.size + nonce.size + encrypted.size)
                .put(wifiPacketMagic).put(nonce).put(encrypted).array()
        }
    }

    fun decryptWifiAwarePacket(peerId: String, frame: ByteArray): String {
        if (frame.size < 32 || !frame.copyOfRange(0, 4).contentEquals(wifiPacketMagic))
            throw SecurityException("إطار Wi-Fi غير مشفر أو بإصدار غير مدعوم")
        val crypto = wifiPacketCryptos[peerId] ?: throw SecurityException("مفتاح فك تشفير جلسة Wi-Fi غير متاح")
        val nonce = frame.copyOfRange(4, 16); val encrypted = frame.copyOfRange(16, frame.size)
        synchronized(crypto) {
            val nonceBuffer = ByteBuffer.wrap(nonce)
            val prefix = ByteArray(4).also { nonceBuffer.get(it) }; val counter = nonceBuffer.long
            if (!prefix.contentEquals(crypto.receivePrefix) || counter != crypto.receiveCounter || counter < 0L)
                throw SecurityException("عداد الحزمة غير صحيح أو تم تكرارها")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(crypto.receiveKey, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD("blousab-wifi-aware-packet-v1|$peerId|${wifiPacketLocalUserId}".toByteArray(Charsets.UTF_8))
            val clear = cipher.doFinal(encrypted)
            crypto.receiveCounter++
            return String(clear, Charsets.UTF_8)
        }
    }

    /** Service owns attach/publish/subscribe and the signed HELLO/IDENTITY/PROOF
     * state machine. Activity callbacks are now limited to UI and selected NDP data path. */
    fun startWifiAware(
        identityAdvertisement: String,
        publishStartedCallback: (PublishDiscoverySession) -> Unit,
        subscribeStartedCallback: (SubscribeDiscoverySession) -> Unit,
        serviceDiscoveredCallback: (PeerHandle, ByteArray?, SubscribeDiscoverySession) -> Unit,
        messageReceivedCallback: (PeerHandle, DiscoverySession, ByteArray) -> Unit,
        serviceLostCallback: (PeerHandle, Int) -> Unit,
        onError: (String) -> Unit
    ): Boolean {
        if (Build.VERSION.SDK_INT < 26) throw IllegalStateException("يتطلب Wi-Fi Aware أندرويد 8 أو أحدث")
        val manager = getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
            ?: throw IllegalStateException("هذا الهاتف لا يدعم Wi-Fi Aware")
        if (!manager.isAvailable) throw IllegalStateException("Wi-Fi Aware غير متاح الآن")
        if (wifiAwareSession != null) return true
        if (wifiAwareStarting) return true
        wifiAwareStarting = true
        val payload = identityAdvertisement.toByteArray(Charsets.UTF_8).take(220).toByteArray()
        try {
            manager.attach(object : AttachCallback() {
            override fun onAttached(session: WifiAwareSession) {
                wifiAwareSession = session
                wifiAwareStarting = false
                try {
                    session.publish(
                        PublishConfig.Builder().setServiceName("blousab-nearby").setServiceSpecificInfo(payload).build(),
                        object : DiscoverySessionCallback() {
                            override fun onPublishStarted(discoverySession: PublishDiscoverySession) {
                                wifiPublishSession = discoverySession
                                publishStartedCallback(discoverySession)
                            }
                            override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
                                routeWifiAwareMessage(peerHandle, discoverySessionOrPublish(), message, messageReceivedCallback)
                            }
                            override fun onSessionConfigFailed() { failWifiAware(onError, "فشل بدء بث هوية بلوساب عبر Wi-Fi Aware") }
                        }, mainHandler
                    )
                    session.subscribe(
                        SubscribeConfig.Builder().setServiceName("blousab-nearby").build(),
                        object : DiscoverySessionCallback() {
                            override fun onSubscribeStarted(discoverySession: SubscribeDiscoverySession) {
                                wifiSubscribeSession = discoverySession
                                subscribeStartedCallback(discoverySession)
                            }
                            override fun onServiceDiscovered(peerHandle: PeerHandle, serviceSpecificInfo: ByteArray?, matchFilter: List<ByteArray>?) {
                                val active = wifiSubscribeSession ?: return
                                serviceDiscoveredCallback(peerHandle, serviceSpecificInfo, active)
                                val raw = try { serviceSpecificInfo?.toString(Charsets.UTF_8) ?: "" } catch (_: Exception) { "" }
                                if (raw.startsWith("BLUSAB2|")) {
                                    val fields = raw.split("|", limit = 3)
                                    if (fields.size == 3 && fields[1].isNotBlank() && fields[2].matches(Regex("[0-9a-f]{64}")))
                                        wifiHandshakeEngine?.start(peerHandle, active, fields[1], fields[2])
                                }
                            }
                            override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
                                val active = wifiSubscribeSession ?: return
                                routeWifiAwareMessage(peerHandle, active, message, messageReceivedCallback)
                            }
                            override fun onServiceLost(peerHandle: PeerHandle, reason: Int) {
                                wifiHandshakeEngine?.remove(peerHandle)
                                serviceLostCallback(peerHandle, reason)
                            }
                            override fun onSessionConfigFailed() { failWifiAware(onError, "فشل بدء البحث عن مستخدمي بلوساب عبر Wi-Fi Aware") }
                        }, mainHandler
                    )
                } catch (e: Exception) {
                    failWifiAware(onError, e.message ?: "تعذر بدء جلسات Wi-Fi Aware")
                }
            }
            override fun onAttachFailed() { failWifiAware(onError, "فشل تهيئة Wi-Fi Aware على هذا الهاتف") }
            }, mainHandler)
        } catch (e: Exception) {
            wifiAwareStarting = false
            throw e
        }
        return true
    }

    private fun routeWifiAwareMessage(
        peer: PeerHandle,
        session: DiscoverySession,
        message: ByteArray,
        dataPathCallback: (PeerHandle, DiscoverySession, ByteArray) -> Unit
    ) {
        val text = try { String(message, Charsets.UTF_8) } catch (_: Exception) { "" }
        if (text.startsWith("BLUSAB_WIFI_")) {
            wifiHandshakeEngine?.onMessage(peer, session, message)
                ?: wifiHandshakeFailureCallback?.invoke(peer, "منسق مصافحة Wi-Fi Aware غير مهيأ")
        } else {
            dataPathCallback(peer, session, message)
        }
    }

    private fun discoverySessionOrPublish(): DiscoverySession =
        wifiPublishSession ?: throw IllegalStateException("جلسة نشر Wi-Fi Aware غير جاهزة")

    private fun failWifiAware(onError: (String) -> Unit, message: String) {
        wifiAwareStarting = false
        stopWifiAware()
        onError(message)
    }

    fun stopWifiAware() {
        wifiPacketCryptos.values.forEach { it.destroy() }
        wifiPacketCryptos.clear()
        wifiPacketLocalUserId = ""
        wifiAwareStarting = false
        wifiHandshakeEngine?.clear()
        wifiHandshakeEngine = null
        try { wifiPublishSession?.close() } catch (_: Exception) {}
        try { wifiSubscribeSession?.close() } catch (_: Exception) {}
        wifiPublishSession = null
        wifiSubscribeSession = null
        try { wifiAwareSession?.close() } catch (_: Exception) {}
        wifiAwareSession = null
    }

    /** Flutter supplies only the already-signed public identity envelope and a
     * narrow signing callback. The service owns socket protocol I/O and checks. */
    fun configureBluetoothHandshake(localHello: String, localUserId: String, signer: (String) -> String) {
        require(localHello.startsWith("BLUSAB_HELLO|2|") && localUserId.isNotBlank())
        handshakeHello = localHello
        handshakeUserId = localUserId
        transcriptSigner = signer
        drainPendingSockets()
    }

    fun clearBluetoothHandshake() {
        transcriptSigner = null
        handshakeHello = ""
        handshakeUserId = ""
    }

    @Synchronized
    fun authenticateIncomingSocket(socket: BluetoothSocket) {
        if (handshakeHello.isBlank() || transcriptSigner == null) {
            while (pendingAcceptedSockets.size >= maxPendingAcceptedSockets) {
                try { pendingAcceptedSockets.poll()?.close() } catch (_: Exception) {}
            }
            pendingAcceptedSockets.offer(socket)
            return
        }
        authenticateAndAdopt(socket)
    }

    /** Verify a nearby RFCOMM candidate with the shared handshake in discovery-only
     * mode. This never adopts the socket as a chat session and always closes it. */
    fun verifyDiscoveryCandidate(address: String, onComplete: (Boolean, String?) -> Unit) {
        if (address.isBlank()) {
            onComplete(false, "عنوان Bluetooth غير صالح")
            return
        }
        if (handshakeHello.isBlank() || transcriptSigner == null) {
            onComplete(false, "هوية بلوساب أو خدمة التوقيع غير جاهزة")
            return
        }
        if (!candidateVerifications.add(address)) {
            onComplete(false, "يجري التحقق من هذا المستخدم بالفعل")
            return
        }
        try {
            peerIoExecutor.execute {
                var socket: BluetoothSocket? = null
                var crypto: BlousabBluetoothHandshake.SessionCrypto? = null
                try {
                    val adapter = BluetoothAdapter.getDefaultAdapter()
                        ?: throw IllegalStateException("هذا الجهاز لا يدعم البلوتوث")
                    if (!adapter.isEnabled) throw IllegalStateException("شغّل البلوتوث أولاً")
                    try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
                    val device = adapter.getRemoteDevice(address)
                    val candidate = device.createRfcommSocketToServiceRecord(
                        UUID.fromString("f0e1d2c3-b4a5-4678-9012-123456789abc")
                    )
                    socket = candidate
                    candidate.connect()

                    val writer = PrintWriter(java.io.OutputStreamWriter(candidate.outputStream, Charsets.UTF_8), true)
                    val reader = BufferedReader(InputStreamReader(candidate.inputStream, Charsets.UTF_8))
                    val signer = transcriptSigner ?: throw IllegalStateException("خدمة توقيع هوية بلوساب غير جاهزة")
                    val authenticated = BlousabBluetoothHandshake(handshakeHello, handshakeUserId, signer)
                        .authenticate(writer, reader, localDiscoveryOnly = true)
                    crypto = authenticated.crypto
                    val peer = authenticated.identity
                    emitSessionEvent(mapOf(
                        "type" to "blousabVerified", "address" to address,
                        "userId" to peer.userId, "userName" to peer.userName,
                        "profilePhoto" to peer.photo, "publicKey" to peer.publicKey,
                        "discoveryOnly" to true
                    ))
                    crypto.destroy()
                    crypto = null
                    onComplete(true, null)
                } catch (e: Exception) {
                    crypto?.destroy()
                    val message = e.message ?: "تعذر التحقق من هوية مستخدم بلوساب"
                    emitSessionEvent(mapOf("type" to "candidateVerificationFailed", "address" to address, "message" to message))
                    onComplete(false, message)
                } finally {
                    try { socket?.close() } catch (_: Exception) {}
                    candidateVerifications.remove(address)
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            candidateVerifications.remove(address)
            onComplete(false, "خدمة Bluetooth غير متاحة حالياً")
        }
    }

    /** Outgoing RFCOMM uses the exact same service-owned handshake and session
     * adoption path as accepted sockets. The Activity never handles chat frames. */
    fun connectAuthenticatedPeer(address: String, onComplete: (Boolean, String?) -> Unit) {
        if (handshakeHello.isBlank() || transcriptSigner == null) {
            onComplete(false, "هوية بلوساب أو خدمة التوقيع غير جاهزة")
            return
        }
        try {
            peerIoExecutor.execute {
                var socket: BluetoothSocket? = null
                try {
                    val adapter = BluetoothAdapter.getDefaultAdapter()
                        ?: throw IllegalStateException("هذا الجهاز لا يدعم البلوتوث")
                    if (!adapter.isEnabled) throw IllegalStateException("شغّل البلوتوث أولاً")
                    try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
                    val device = adapter.getRemoteDevice(address)
                    val connectedSocket = device.createRfcommSocketToServiceRecord(
                        UUID.fromString("f0e1d2c3-b4a5-4678-9012-123456789abc")
                    )
                    socket = connectedSocket
                    connectedSocket.connect()
                    authenticateAndAdopt(connectedSocket) { ok, message -> onComplete(ok, message) }
                } catch (e: Exception) {
                    try { socket?.close() } catch (_: Exception) {}
                    val message = e.message ?: "تعذر الاتصال بمستخدم بلوساب"
                    emitSessionEvent(mapOf("type" to "connectionError", "address" to address, "message" to message))
                    onComplete(false, message)
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            onComplete(false, "خدمة Bluetooth غير متاحة حالياً")
        }
    }

    private fun authenticateAndAdopt(socket: BluetoothSocket, onComplete: ((Boolean, String?) -> Unit)? = null) {
        try {
            peerIoExecutor.execute {
                var crypto: BlousabBluetoothHandshake.SessionCrypto? = null
                val address = try { socket.remoteDevice.address } catch (_: Exception) { "" }
                try {
                    val hello = handshakeHello
                    val userId = handshakeUserId
                    val signer = transcriptSigner ?: throw IllegalStateException("خدمة توقيع هوية بلوساب غير جاهزة")
                    if (hello.isBlank() || userId.isBlank()) throw IllegalStateException("هوية بلوساب المحلية غير مهيأة")

                    val writer = PrintWriter(java.io.OutputStreamWriter(socket.outputStream, Charsets.UTF_8), true)
                    val reader = BufferedReader(java.io.InputStreamReader(socket.inputStream, Charsets.UTF_8))
                    val authenticated = BlousabBluetoothHandshake(hello, userId, signer).authenticate(writer, reader)
                    val peer = authenticated.identity
                    if (peer.discoveryOnly) {
                        emitSessionEvent(mapOf("type" to "blousabVerified", "address" to address,
                            "userId" to peer.userId, "userName" to peer.userName,
                            "profilePhoto" to peer.photo, "publicKey" to peer.publicKey, "discoveryOnly" to true))
                        authenticated.crypto.destroy()
                        socket.close()
                        onComplete?.invoke(false, "تم التحقق من مستخدم بلوساب بوضع الاكتشاف فقط؛ اختر اتصالاً عادياً")
                        return@execute
                    }
                    crypto = authenticated.crypto

                    emitSessionEvent(mapOf("type" to "blousabVerified", "address" to address,
                        "userId" to peer.userId, "userName" to peer.userName,
                        "profilePhoto" to peer.photo, "publicKey" to peer.publicKey))
                    emitSessionEvent(mapOf("type" to "connected", "address" to address, "userName" to peer.userName))
                    val sessionCrypto = crypto
                    crypto = null
                    adoptAuthenticatedPeer(address, peer.userName, socket, reader, writer,
                        encrypt = { clear -> sessionCrypto!!.encrypt(clear) },
                        decrypt = { frame -> sessionCrypto!!.decrypt(frame) },
                        onClosed = { sessionCrypto!!.destroy() })
                    onComplete?.invoke(true, null)
                } catch (e: Exception) {
                    crypto?.destroy()
                    try { socket.close() } catch (_: Exception) {}
                    val message = e.message ?: "لم تثبت هوية بلوساب؛ تم تجاهل الجهاز"
                    emitSessionEvent(mapOf("type" to "unverifiedDevice", "address" to address, "message" to message))
                    onComplete?.invoke(false, message)
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            try { socket.close() } catch (_: Exception) {}
            onComplete?.invoke(false, "خدمة Bluetooth غير متاحة حالياً")
        }
    }

    private fun deliverOrQueue(socket: BluetoothSocket) {
        val callback = acceptedSocketCallback
        if (callback != null) {
            try { callback.invoke(socket) } catch (_: Exception) { try { socket.close() } catch (_: Exception) {} }
            return
        }
        if (handshakeHello.isNotBlank() && transcriptSigner != null) {
            authenticateIncomingSocket(socket)
            return
        }
        // Activity/Flutter may be recreating. Keep only a small bounded queue;
        // never silently turn an unowned socket into an authenticated peer.
        while (pendingAcceptedSockets.size >= maxPendingAcceptedSockets) {
            try { pendingAcceptedSockets.poll()?.close() } catch (_: Exception) {}
        }
        pendingAcceptedSockets.offer(socket)
    }

    @Synchronized
    private fun drainPendingSockets() {
        val callback = acceptedSocketCallback ?: return
        while (true) {
            val socket = pendingAcceptedSockets.poll() ?: break
            try { callback.invoke(socket) } catch (_: Exception) {
                try { socket.close() } catch (_: Exception) {}
            }
        }
    }

    /** Called when a live Activity/Flutter host is available to authenticate peers. */
    @Synchronized
    fun attachBluetoothListenerConsumer(
        onAccepted: (BluetoothSocket) -> Unit,
        onError: (String) -> Unit
    ) {
        acceptedSocketCallback = onAccepted
        listenerErrorCallback = onError
        drainPendingSockets()
    }

    /** Detach the Activity callback without stopping the service-owned RFCOMM listener. */
    @Synchronized
    fun detachBluetoothListenerConsumer() {
        acceptedSocketCallback = null
        listenerErrorCallback = null
        // Accepted sockets remain queued until the service has a current identity signer.
    }


    /** Attach the current Flutter host to events from service-owned live sessions. */
    @Synchronized
    fun attachSessionEventConsumer(onEvent: (Map<String, Any>) -> Unit) {
        sessionEventCallback = onEvent
        // Do not remove events here. The Dart event stream acknowledges each
        // event only after it has been handed to its broadcast listeners.
        pendingSessionEvents.values.toList().forEach { event ->
            try { onEvent.invoke(event) } catch (_: Exception) { /* retained for retry */ }
        }
    }

    @Synchronized
    fun acknowledgeSessionEvent(eventId: Long): Boolean =
        pendingSessionEvents.remove(eventId) != null

    @Synchronized
    fun detachSessionEventConsumer() {
        sessionEventCallback = null
    }

    @Synchronized
    private fun emitSessionEvent(event: Map<String, Any>) {
        val eventId = sessionEventSequence.incrementAndGet()
        val envelope = HashMap(event)
        envelope["eventId"] = eventId
        pendingSessionEvents[eventId] = envelope
        // Bound memory use. On overflow discard the oldest unacknowledged event;
        // the durable encrypted outbox remains the source of truth for messages.
        while (pendingSessionEvents.size > maxPendingSessionEvents) {
            val oldest = pendingSessionEvents.keys.firstOrNull() ?: break
            pendingSessionEvents.remove(oldest)
        }
        val callback = sessionEventCallback
        if (callback != null) {
            try { callback.invoke(envelope) } catch (_: Exception) { /* retry on reattach */ }
        }
    }

    /**
     * Transfer an already authenticated RFCOMM session into the foreground service.
     * Authentication and key derivation happen before this call in the existing
     * signed Blousab handshake. The service only owns encrypted frame I/O.
     */
    fun adoptAuthenticatedPeer(
        address: String,
        userName: String,
        socket: BluetoothSocket,
        reader: BufferedReader,
        writer: PrintWriter,
        encrypt: (String) -> String,
        decrypt: (String) -> String,
        onClosed: () -> Unit
    ) {
        val session = ManagedPeer(address, userName, socket, writer, encrypt, decrypt, onClosed)
        val previous = managedPeers.put(address, session)
        if (previous != null && previous.socket !== socket) closeManagedPeer(previous, false)
        try {
            peerIoExecutor.execute {
            try {
                while (socket.isConnected) {
                    val line = reader.readLine() ?: break
                    val clear = session.decrypt.invoke(line)
                    emitSessionEvent(mapOf(
                        "type" to "message", "address" to address,
                        "userName" to userName, "message" to clear
                    ))
                }
            } catch (e: Exception) {
                if (socket.isConnected) emitSessionEvent(mapOf(
                    "type" to "connectionError", "address" to address,
                    "message" to (e.message ?: "انقطع الاتصال")
                ))
            } finally {
                if (managedPeers[address] === session) {
                    managedPeers.remove(address, session)
                    closeManagedPeer(session, true)
                } else {
                    closeManagedPeer(session, false)
                }
            }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            managedPeers.remove(address, session)
            closeManagedPeer(session, false)
            throw e
        }
    }

    private fun closeManagedPeer(peer: ManagedPeer, notify: Boolean) {
        if (!peer.closed.compareAndSet(false, true)) return
        try { peer.socket.close() } catch (_: Exception) {}
        try { peer.onClosed.invoke() } catch (_: Exception) {}
        if (notify) emitSessionEvent(mapOf("type" to "disconnected", "address" to peer.address))
    }

    fun sendAuthenticatedMessage(address: String, message: String): Int {
        val targets = if (address == "*") managedPeers.values.toList()
            else listOfNotNull(managedPeers[address])
        if (targets.isEmpty()) throw IllegalStateException("لا توجد جلسة Bluetooth موثقة")
        var sent = 0
        var lastError: Exception? = null
        for (peer in targets) {
            try {
                synchronized(peer.writer) {
                    peer.writer.println(peer.encrypt.invoke(message))
                    peer.writer.flush()
                    if (peer.writer.checkError()) throw java.io.IOException("فشل الإرسال")
                }
                sent++
            } catch (e: Exception) {
                lastError = e
                closeManagedPeer(peer, true)
                managedPeers.remove(peer.address, peer)
            }
        }
        if (sent == 0) throw (lastError ?: java.io.IOException("فشل إرسال الرسالة"))
        return sent
    }

    fun closeAuthenticatedPeer(address: String? = null) {
        val peers = if (address.isNullOrBlank()) managedPeers.values.toList()
            else listOfNotNull(managedPeers[address])
        peers.forEach { peer ->
            managedPeers.remove(peer.address, peer)
            closeManagedPeer(peer, true)
        }
    }

    fun hasAuthenticatedPeer(address: String): Boolean = managedPeers.containsKey(address)

    fun authenticatedPeerSnapshot(): List<Map<String, Any>> = managedPeers.values.map { peer ->
        mapOf("type" to "connected", "address" to peer.address, "userName" to peer.userName)
    }

    inner class RuntimeBinder : Binder() {
        fun service(): BlousabBackgroundService = this@BlousabBackgroundService
    }

    /** The foreground service owns the RFCOMM listener and authenticates accepted
     * sockets through the same coordinator used for outgoing connections. */
    @Synchronized
    fun startBluetoothListener(onAccepted: (BluetoothSocket) -> Unit, onError: (String) -> Unit) {
        // Refresh both callbacks even when the listener is already running. This
        // is essential after Activity/Flutter-engine recreation: the accept loop
        // remains service-owned while its consumer is replaced.
        attachBluetoothListenerConsumer(onAccepted, onError)
        if (!serverRunning.compareAndSet(false, true)) return
        listenerExecutor.execute {
            try {
                val adapter = BluetoothAdapter.getDefaultAdapter()
                    ?: throw IllegalStateException("هذا الجهاز لا يدعم البلوتوث")
                if (!adapter.isEnabled) throw IllegalStateException("شغّل البلوتوث أولاً")
                val listening = adapter.listenUsingRfcommWithServiceRecord(
                    "BlousabRFCOMM",
                    UUID.fromString("f0e1d2c3-b4a5-4678-9012-123456789abc")
                )
                bluetoothServerSocket = listening
                while (serverRunning.get()) {
                    val client = listening.accept()
                    deliverOrQueue(client)
                }
            } catch (e: Exception) {
                if (serverRunning.get()) listenerErrorCallback?.invoke(e.message ?: "تعذر تشغيل استقبال Bluetooth")
            } finally {
                serverRunning.set(false)
                try { bluetoothServerSocket?.close() } catch (_: Exception) {}
                bluetoothServerSocket = null
            }
        }
    }

    @Synchronized
    fun stopBluetoothListener() {
        closeAuthenticatedPeer()
        serverRunning.set(false)
        try { bluetoothServerSocket?.close() } catch (_: Exception) {}
        bluetoothServerSocket = null
        acceptedSocketCallback = null
        listenerErrorCallback = null
        while (true) {
            try { pendingAcceptedSockets.poll()?.close() ?: break } catch (_: Exception) { break }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, buildNotification())
        // Restart the foreground host if Android recreates its process. This is
        // not a promise that transport sockets or Dart state have been restored.
        return START_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "تشغيل بلوساب في الخلفية",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "إشعار استمرار خدمة بلوساب أثناء نشاطها في الخلفية"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("بلوساب يعمل في الخلفية")
            .setContentText("خدمات Bluetooth وWi-Fi Aware تعمل أثناء نشاط بلوساب")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder = runtimeBinder

    override fun onDestroy() {
        stopBluetoothListener()
        stopWifiAware()
        clearBluetoothHandshake()
        detachSessionEventConsumer()
        peerIoExecutor.shutdownNow()
        listenerExecutor.shutdownNow()
        super.onDestroy()
    }
}
