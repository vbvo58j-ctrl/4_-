package com.plosap.myapp

import android.util.Base64
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.json.JSONObject
import java.io.BufferedReader
import java.io.PrintWriter
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Security
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Service-side RFCOMM protocol coordinator. Private identity signing remains
 * delegated to the existing Flutter Secure Storage identity via signTranscript. */
internal class BlousabBluetoothHandshake(
    private val localHello: String,
    private val localUserId: String,
    private val signTranscript: (String) -> String
) {
    data class PeerIdentity(val userId: String, val userName: String, val photo: String, val publicKey: String, val discoveryOnly: Boolean)
    data class Result(val identity: PeerIdentity, val crypto: SessionCrypto)

    class SessionCrypto(
        private val localId: String, private val peerId: String,
        private val sendKey: ByteArray, private val receiveKey: ByteArray,
        private val sendPrefix: ByteArray, private val receivePrefix: ByteArray
    ) {
        private var sendCounter = 0L
        private var receiveCounter = 0L
        @Synchronized fun encrypt(plainText: String): String {
            check(sendCounter != Long.MAX_VALUE) { "انتهى عداد تشفير Bluetooth؛ أعد الاتصال" }
            val nonce = ByteBuffer.allocate(12).put(sendPrefix).putLong(sendCounter).array()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(sendKey, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD("blousab-bluetooth-frame-v2|$localId|$peerId".toByteArray(Charsets.UTF_8))
            val encrypted = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8)); sendCounter++
            return JSONObject().put("type", "blousab_bt_secure_frame_v2")
                .put("nonce", Base64.encodeToString(nonce, Base64.NO_WRAP))
                .put("cipherText", Base64.encodeToString(encrypted, Base64.NO_WRAP)).toString()
        }
        @Synchronized fun decrypt(frame: String): String {
            val obj = JSONObject(frame)
            if (obj.optString("type") != "blousab_bt_secure_frame_v2") throw SecurityException("إطار Bluetooth غير مشفر أو بإصدار غير مدعوم")
            val nonce = Base64.decode(obj.getString("nonce"), Base64.DEFAULT)
            val encrypted = Base64.decode(obj.getString("cipherText"), Base64.DEFAULT)
            if (nonce.size != 12) throw SecurityException("Nonce Bluetooth غير صالح")
            val buffer = ByteBuffer.wrap(nonce); val prefix = ByteArray(4).also { buffer.get(it) }; val counter = buffer.long
            if (!prefix.contentEquals(receivePrefix) || counter != receiveCounter || counter < 0L) throw SecurityException("عداد Bluetooth غير صحيح أو حزمة مكررة")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(receiveKey, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD("blousab-bluetooth-frame-v2|$peerId|$localId".toByteArray(Charsets.UTF_8))
            val clear = cipher.doFinal(encrypted); receiveCounter++
            return String(clear, Charsets.UTF_8)
        }
        fun destroy() {
            java.util.Arrays.fill(sendKey, 0); java.util.Arrays.fill(receiveKey, 0)
            java.util.Arrays.fill(sendPrefix, 0); java.util.Arrays.fill(receivePrefix, 0)
            sendCounter = 0; receiveCounter = 0
        }
    }

    fun authenticate(writer: PrintWriter, reader: BufferedReader, localDiscoveryOnly: Boolean = false): Result {
        if (localHello.isBlank() || localUserId.isBlank()) throw IllegalStateException("هوية بلوساب المحلية غير مهيأة")
        val localMode = if (localDiscoveryOnly) "DISCOVERY" else "SESSION"
        writer.println("BLUSAB_MODE|1|$localMode"); writer.flush()
        val peerMode = readLine(reader, "تحديد غرض الاتصال").split("|")
        if (peerMode.size != 3 || peerMode[0] != "BLUSAB_MODE" || peerMode[1] != "1" || peerMode[2] !in setOf("DISCOVERY", "SESSION")) throw SecurityException("غرض اتصال بلوساب غير صالح")
        writer.println(localHello); writer.flush()
        val peer = parseHello(readLine(reader, "تبادل الهوية"))
        if (localUserId == peer.userId) throw SecurityException("معرّف مستخدم بلوساب غير صالح")

        val localNonceBytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val localNonce = Base64.encodeToString(localNonceBytes, Base64.NO_WRAP or Base64.URL_SAFE)
        val ephemeralPrivate = X25519PrivateKeyParameters(SecureRandom())
        val localEphemeralBytes = ephemeralPrivate.generatePublicKey().encoded
        val localEphemeral = Base64.encodeToString(localEphemeralBytes, Base64.NO_WRAP)
        writer.println("BLUSAB_CHALLENGE|2|$localNonce|$localEphemeral"); writer.flush()
        val challenge = readLine(reader, "تحدي X25519 للطرف الآخر").split("|")
        if (challenge.size != 4 || challenge[0] != "BLUSAB_CHALLENGE" || challenge[1] != "2") throw SecurityException("تحدي Bluetooth غير صالح")
        val peerNonceBytes = try { Base64.decode(challenge[2], Base64.NO_WRAP or Base64.URL_SAFE) } catch (_: Exception) { byteArrayOf() }
        val peerEphemeral = try { Base64.decode(challenge[3], Base64.DEFAULT) } catch (_: Exception) { byteArrayOf() }
        if (peerNonceBytes.size != 32 || peerEphemeral.size != 32 || localNonce == challenge[2]) throw SecurityException("قيم تحدي X25519 غير صالحة")
        data class Side(val id: String, val nonce: String, val ephemeral: String)
        val sides = listOf(Side(localUserId, localNonce, localEphemeral), Side(peer.userId, challenge[2], challenge[3])).sortedBy { it.id }
        val transcript = "BLUSAB_X25519_PROOF|2|${sides[0].id}|${sides[0].nonce}|${sides[0].ephemeral}|${sides[1].id}|${sides[1].nonce}|${sides[1].ephemeral}"
        writer.println("BLUSAB_PROOF|2|${signTranscript(transcript)}"); writer.flush()
        val proof = readLine(reader, "إثبات مفتاح X25519 للطرف الآخر").split("|")
        if (proof.size != 3 || proof[0] != "BLUSAB_PROOF" || proof[1] != "2" || !verifyEd25519(peer.publicKey, transcript.toByteArray(Charsets.UTF_8), proof[2])) throw SecurityException("فشل توقيع مفاتيح جلسة Bluetooth")

        val agreement = X25519Agreement(); agreement.init(ephemeralPrivate)
        val shared = ByteArray(agreement.agreementSize)
        agreement.calculateAgreement(X25519PublicKeyParameters(peerEphemeral, 0), shared, 0)
        if (shared.all { it == 0.toByte() }) throw SecurityException("سر X25519 غير صالح")
        val salt = MessageDigest.getInstance("SHA-256").digest(transcript.toByteArray(Charsets.UTF_8))
        val send = hkdf(shared, salt, "blousab-bt-v2|$localUserId|${peer.userId}".toByteArray(), 36)
        val receive = hkdf(shared, salt, "blousab-bt-v2|${peer.userId}|$localUserId".toByteArray(), 36)
        java.util.Arrays.fill(shared, 0)
        val crypto = SessionCrypto(localUserId, peer.userId, send.copyOfRange(0,32), receive.copyOfRange(0,32), send.copyOfRange(32,36), receive.copyOfRange(32,36))
        java.util.Arrays.fill(send, 0); java.util.Arrays.fill(receive, 0)
        return Result(peer.copy(discoveryOnly = localDiscoveryOnly || peerMode[2] == "DISCOVERY"), crypto)
    }

    private fun readLine(reader: BufferedReader, label: String) = reader.readLine() ?: throw SecurityException("انقطع الاتصال أثناء $label")
    private fun parseHello(line: String): PeerIdentity {
        val parts = line.split("|")
        if (parts.size != 3 || parts[0] != "BLUSAB_HELLO" || parts[1] != "2") throw SecurityException("الجهاز لا يدعم مصافحة بلوساب الموقعة")
        val bytes = Base64.decode(parts[2], Base64.NO_WRAP or Base64.URL_SAFE)
        val envelope = JSONObject(String(bytes, Charsets.UTF_8))
        val payloadEncoded = envelope.getString("payload"); val signature = envelope.getString("signature"); val publicKey = envelope.getString("publicKey")
        val payloadBytes = Base64.decode(payloadEncoded, Base64.DEFAULT)
        if (!verifyEd25519(publicKey, payloadBytes, signature)) throw SecurityException("توقيع هوية بلوساب غير صحيح")
        val payload = JSONObject(String(payloadBytes, Charsets.UTF_8))
        if (payload.optString("type") != "blousab_discovery_identity" || payload.optInt("version") != 2 || payload.optString("publicKey") != publicKey) throw SecurityException("بنية هوية بلوساب غير صالحة")
        val id = payload.optString("userId").trim(); if (id.isEmpty()) throw SecurityException("معرّف مستخدم بلوساب فارغ")
        return PeerIdentity(id, payload.optString("userName", "مستخدم بلوساب"), payload.optString("profilePhoto", ""), publicKey, false)
    }
    private fun verifyEd25519(publicKeyBase64: String, payload: ByteArray, signatureBase64: String): Boolean {
        return try {
            if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
                Security.addProvider(BouncyCastleProvider())
            }
            val raw = Base64.decode(publicKeyBase64, Base64.DEFAULT)
            val sig = Base64.decode(signatureBase64, Base64.DEFAULT)
            if (raw.size != 32 || sig.size != 64) {
                false
            } else {
                val prefix = byteArrayOf(0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00)
                val key = KeyFactory.getInstance("Ed25519", "BC").generatePublic(X509EncodedKeySpec(prefix + raw))
                Signature.getInstance("Ed25519", "BC").run {
                    initVerify(key)
                    update(payload)
                    verify(sig)
                }
            }
        } catch (_: Exception) {
            false
        }
    }
    private fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256"); mac.init(SecretKeySpec(salt, "HmacSHA256")); val prk = mac.doFinal(ikm)
        val out = java.io.ByteArrayOutputStream(); var previous = byteArrayOf(); var counter = 1
        while (out.size() < length) { mac.init(SecretKeySpec(prk, "HmacSHA256")); mac.update(previous); mac.update(info); mac.update(counter.toByte()); previous = mac.doFinal(); out.write(previous); counter++ }
        java.util.Arrays.fill(prk, 0); java.util.Arrays.fill(previous, 0); return out.toByteArray().copyOf(length)
    }
}
