package com.plosap.myapp

import android.net.wifi.aware.DiscoverySession
import android.net.wifi.aware.PeerHandle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.json.JSONObject
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.Security
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.util.concurrent.Executors
import java.security.spec.X509EncodedKeySpec
import java.util.Arrays
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal data class BlousabWifiPeerIdentity(
    val userId: String, val userName: String, val photo: String, val publicKey: String
)

/** Owns the Wi-Fi Aware HELLO/IDENTITY/PROOF protocol and X25519 session derivation.
 * Flutter is used only as a narrowly-scoped Ed25519 signing oracle for the local key. */
internal class BlousabWifiAwareHandshakeEngine(
    private val localHello: String,
    private val localUserId: String,
    private val signer: (String) -> String,
    private val onVerified: (PeerHandle, DiscoverySession, BlousabWifiPeerIdentity, String, ByteArray, ByteArray, ByteArray, ByteArray) -> Unit,
    private val onFailure: (PeerHandle, String) -> Unit
) {
    private data class State(
        val session: DiscoverySession,
        val localNonce: String,
        val privateKey: X25519PrivateKeyParameters,
        val localEphemeral: String,
        val expectedPeerId: String = "",
        val expectedFingerprint: String = "",
        @Volatile var peerId: String = "",
        @Volatile var peerNonce: String = "",
        @Volatile var peerEphemeral: String = "",
        @Volatile var peer: BlousabWifiPeerIdentity? = null,
        @Volatile var identitySent: Boolean = false,
        @Volatile var proofSent: Boolean = false,
        @Volatile var proofVerified: Boolean = false,
        @Volatile var emitted: Boolean = false
    )
    private val states = ConcurrentHashMap<PeerHandle, State>()
    private val handler = Handler(Looper.getMainLooper())
    private val protocolExecutor = Executors.newSingleThreadExecutor()
    private val localPublicKey: String
    private val localName: String

    init {
        val p = localHello.split('|')
        require(p.size == 3 && p[0] == "BLUSAB_HELLO" && p[1] == "2") { "هوية Wi-Fi المحلية غير صالحة" }
        val envelopeBytes = Base64.decode(p[2], Base64.NO_WRAP or Base64.URL_SAFE)
        val envelope = JSONObject(String(envelopeBytes, Charsets.UTF_8))
        val payloadBytes = Base64.decode(envelope.getString("payload"), Base64.DEFAULT)
        localPublicKey = envelope.getString("publicKey")
        val payload = JSONObject(String(payloadBytes, Charsets.UTF_8))
        require(payload.optString("userId") == localUserId && payload.optString("publicKey") == localPublicKey)
        localName = payload.optString("userName", "مستخدم بلوساب").take(48)
    }

    fun start(peer: PeerHandle, session: DiscoverySession, expectedPeerId: String = "", expectedFingerprint: String = "") {
        if (states.containsKey(peer)) return
        val nonce = b64(ByteArray(32).also { SecureRandom().nextBytes(it) })
        val ephemeral = X25519PrivateKeyParameters(SecureRandom())
        val state = State(session, nonce, ephemeral, b64(ephemeral.generatePublicKey().encoded), expectedPeerId, expectedFingerprint)
        if (states.putIfAbsent(peer, state) != null) return
        handler.postDelayed({
            if (!state.emitted && states.remove(peer, state)) onFailure(peer, "انتهت مهلة مصافحة Wi-Fi Aware")
        }, 20_000L)
        try {
            send(peer, state, "BLUSAB_WIFI_HELLO|1|${b64(localUserId.toByteArray(Charsets.UTF_8))}|$nonce")
        } catch (e: Exception) {
            states.remove(peer, state)
            onFailure(peer, e.message ?: "تعذر إرسال تحدي Wi-Fi Aware")
        }
    }

    fun onMessage(peer: PeerHandle, session: DiscoverySession, bytes: ByteArray) {
        val copy = bytes.copyOf()
        try { protocolExecutor.execute { processMessage(peer, session, copy) } }
        catch (_: java.util.concurrent.RejectedExecutionException) { }
    }

    private fun processMessage(peer: PeerHandle, session: DiscoverySession, bytes: ByteArray) {
        val message = String(bytes, Charsets.UTF_8)
        if (!message.startsWith("BLUSAB_WIFI_")) return
        try {
            val activeState = states[peer]
            if (activeState != null && activeState.session !== session)
                throw SecurityException("رسالة مصافحة واردة من جلسة Wi-Fi مختلفة")
            val parts = message.split('|', limit = 6)
            when (parts.firstOrNull()) {
                "BLUSAB_WIFI_HELLO" -> {
                    if (parts.size != 4 || parts[1] != "1") throw SecurityException("رسالة HELLO غير صالحة")
                    val peerId = String(unb64(parts[2]), Charsets.UTF_8)
                    if (peerId.isBlank() || peerId.length > 128 || peerId == localUserId || unb64(parts[3]).size != 32)
                        throw SecurityException("هوية أو تحدي Wi-Fi غير صالح")
                    val expected = states[peer]?.expectedPeerId.orEmpty()
                    if (expected.isNotBlank() && expected != peerId) throw SecurityException("هوية المصافحة لا تطابق إعلان Wi-Fi")
                    var state = states[peer]
                    if (state == null) {
                        start(peer, session)
                        state = states[peer]
                    }
                    val active = state ?: throw SecurityException("حالة المصافحة غير متاحة")
                    synchronized(active) {
                        if (active.peerId.isNotEmpty() && (active.peerId != peerId || active.peerNonce != parts[3]))
                            throw SecurityException("تغير التحدي أثناء المصافحة")
                        active.peerId = peerId
                        active.peerNonce = parts[3]
                    }
                    sendIdentity(peer, active)
                    sendProofIfReady(peer, active)
                }
                "BLUSAB_WIFI_ID" -> {
                    if (parts.size != 6 || parts[1] != "2") throw SecurityException("رسالة الهوية غير صالحة")
                    val state = states[peer] ?: throw SecurityException("وصلت الهوية قبل التحدي")
                    if (state.peerId.isBlank() || state.peerNonce.isBlank()) throw SecurityException("تحدي الطرف الآخر غير موجود")
                    val keyBytes = unb64(parts[2]); if (keyBytes.size != 32) throw SecurityException("مفتاح Wi-Fi غير صالح")
                    val pub = Base64.encodeToString(keyBytes, Base64.NO_WRAP)
                    val expectedFingerprint = state.expectedFingerprint
                    if (expectedFingerprint.isNotBlank() && fingerprint(keyBytes) != expectedFingerprint)
                        throw SecurityException("بصمة مفتاح الهوية لا تطابق إعلان Wi-Fi")
                    val name = String(unb64(parts[3]), Charsets.UTF_8).take(48).ifBlank { "مستخدم بلوساب" }
                    if (unb64(parts[4]).size != 32) throw SecurityException("مفتاح الجلسة المؤقت غير صالح")
                    val transcript = "BLUSAB_WIFI_IDENTITY|2|${state.peerId}|${parts[2]}|${parts[3]}|${parts[4]}"
                    if (!verify(pub, transcript.toByteArray(Charsets.UTF_8), b64(unb64(parts[5]))))
                        throw SecurityException("توقيع هوية Wi-Fi غير صحيح")
                    if (state.peerEphemeral.isNotEmpty() && state.peerEphemeral != parts[4]) throw SecurityException("تغير المفتاح المؤقت")
                    state.peerEphemeral = parts[4]
                    state.peer = BlousabWifiPeerIdentity(state.peerId, name, "", pub)
                    sendProofIfReady(peer, state)
                }
                "BLUSAB_WIFI_PROOF" -> {
                    if (parts.size != 3 || parts[1] != "2") throw SecurityException("رسالة إثبات Wi-Fi غير صالحة")
                    val state = states[peer] ?: throw SecurityException("حالة إثبات Wi-Fi غير موجودة")
                    val identity = state.peer ?: throw SecurityException("لم يتم التحقق من مفتاح الطرف")
                    val signature = b64(unb64(parts[2]))
                    if (!verify(identity.publicKey, proofTranscript(state).toByteArray(Charsets.UTF_8), signature))
                        throw SecurityException("توقيع إثبات تحدي Wi-Fi غير صحيح")
                    state.proofVerified = true
                    complete(peer, state)
                }
            }
        } catch (e: Exception) {
            states.remove(peer)?.let { Arrays.fill(it.privateKey.encoded, 0) }
            onFailure(peer, e.message ?: "فشلت مصافحة Wi-Fi Aware")
        }
    }

    private fun sendIdentity(peer: PeerHandle, s: State) {
        if (s.identitySent) return
        val key = b64(Base64.decode(localPublicKey, Base64.DEFAULT))
        val name = b64(localName.toByteArray(Charsets.UTF_8))
        val transcript = "BLUSAB_WIFI_IDENTITY|2|$localUserId|$key|$name|${s.localEphemeral}"
        val signature = b64(Base64.decode(signer(transcript), Base64.DEFAULT))
        send(peer, s, "BLUSAB_WIFI_ID|2|$key|$name|${s.localEphemeral}|$signature")
        s.identitySent = true
    }

    private fun sendProofIfReady(peer: PeerHandle, s: State) {
        if (s.proofSent || s.peer == null || s.peerNonce.isBlank()) return
        val signature = b64(Base64.decode(signer(proofTranscript(s)), Base64.DEFAULT))
        send(peer, s, "BLUSAB_WIFI_PROOF|2|$signature")
        s.proofSent = true
        complete(peer, s)
    }

    private fun complete(peer: PeerHandle, s: State) {
        val identity = s.peer ?: return
        if (!s.proofSent || !s.proofVerified || s.emitted || s.peerEphemeral.isBlank()) return
        synchronized(s) {
            if (s.emitted) return
            val agreement = X25519Agreement(); agreement.init(s.privateKey)
            val shared = ByteArray(32)
            agreement.calculateAgreement(X25519PublicKeyParameters(unb64(s.peerEphemeral), 0), shared, 0)
            if (shared.all { it == 0.toByte() }) throw SecurityException("سر جلسة X25519 غير صالح")
            try {
                val transcript = proofTranscript(s).toByteArray(Charsets.UTF_8)
                val salt = MessageDigest.getInstance("SHA-256").digest(transcript)
                val psk = hkdf(shared, salt, "Blousab-WiFi-Aware-NDP-PSK-v2".toByteArray(), 32)
                val localSend = hkdf(shared, salt, "Blousab-WiFi-Aware-Packet-v1|$localUserId|${identity.userId}".toByteArray(), 36)
                val peerSend = hkdf(shared, salt, "Blousab-WiFi-Aware-Packet-v1|${identity.userId}|$localUserId".toByteArray(), 36)
                val passphrase = psk.joinToString("") { "%02x".format(it) }.take(63)
                if (passphrase.length !in 8..63) throw SecurityException("مفتاح جلسة Wi-Fi غير صالح")
                s.emitted = true
                onVerified(peer, s.session, identity, passphrase,
                    localSend.copyOfRange(0, 32), peerSend.copyOfRange(0, 32),
                    localSend.copyOfRange(32, 36), peerSend.copyOfRange(32, 36))
                states.remove(peer, s)
                Arrays.fill(psk, 0); Arrays.fill(localSend, 0); Arrays.fill(peerSend, 0)
            } finally { Arrays.fill(shared, 0) }
        }
    }

    private fun proofTranscript(s: State): String {
        val peer = s.peer ?: throw SecurityException("هوية الطرف المقابل غير متاحة")
        val rows = listOf(Triple(localUserId, s.localNonce, s.localEphemeral), Triple(peer.userId, s.peerNonce, s.peerEphemeral)).sortedBy { it.first }
        if (rows[0].first == rows[1].first) throw SecurityException("تعارض هوية طرفي جلسة Wi-Fi")
        return "BLUSAB_WIFI_X25519_PROOF|2|${rows[0].first}|${rows[0].second}|${rows[0].third}|${rows[1].first}|${rows[1].second}|${rows[1].third}"
    }

    private fun send(peer: PeerHandle, s: State, value: String) {
        s.session.sendMessage(peer, (System.nanoTime() and 0x7fffffff).toInt(), value.toByteArray(Charsets.UTF_8))
    }
    fun remove(peer: PeerHandle) { states.remove(peer) }
    fun clear() { states.clear(); protocolExecutor.shutdownNow() }
    private fun fingerprint(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
    private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
    private fun unb64(value: String) = Base64.decode(value, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
    private fun verify(publicKey: String, payload: ByteArray, signature: String): Boolean {
        return try {
            if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) Security.addProvider(BouncyCastleProvider())
            val rawKey = Base64.decode(publicKey, Base64.DEFAULT)
            val sigBytes = Base64.decode(signature, Base64.DEFAULT)
            if (rawKey.size != 32 || sigBytes.size != 64) false else {
                val prefix = byteArrayOf(0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00)
                val key = KeyFactory.getInstance("Ed25519", "BC").generatePublic(X509EncodedKeySpec(prefix + rawKey))
                Signature.getInstance("Ed25519", "BC").run { initVerify(key); update(payload); verify(sigBytes) }
            }
        } catch (_: Exception) { false }
    }
    private fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256"); mac.init(SecretKeySpec(salt, "HmacSHA256")); val prk = mac.doFinal(ikm)
        val out = java.io.ByteArrayOutputStream(); var previous = ByteArray(0); var counter = 1
        while (out.size() < length) { mac.init(SecretKeySpec(prk, "HmacSHA256")); mac.update(previous); mac.update(info); mac.update(counter.toByte()); previous = mac.doFinal(); out.write(previous); counter++ }
        Arrays.fill(prk, 0); return out.toByteArray().copyOf(length)
    }
}
