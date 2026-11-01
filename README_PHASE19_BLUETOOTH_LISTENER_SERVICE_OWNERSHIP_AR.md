# المرحلة 19 — نقل ملكية مستمع Bluetooth RFCOMM إلى خدمة Android

## ما تغيّر فعلياً
- أصبح `BlousabBackgroundService` يملك `BluetoothServerSocket` الخاص بمستمع RFCOMM، ويشغّل حلقة `accept()` عبر منفّذ مستقل داخل الخدمة.
- أضيف Binder محلي يسمح لـ `MainActivity` بالارتباط بالخدمة وتمرير المقبس المقبول إلى مسار تسجيل النظير الحالي.
- لم يتم تجاوز مصافحة بلوساب: المقبس المقبول ما زال يمر عبر `registerPeer()` ثم `performAuthenticatedHandshake()`، مع التحقق من هوية Ed25519 وتحدي nonce ومفتاح X25519 وتشفير AES-GCM كما في المسار السابق.
- عند إيقاف الاستقبال صراحةً، تغلق الخدمة مستمع RFCOMM. وعند تدمير `MainActivity` يتم إيقاف المستمع وإغلاق جلسات الأقران النشطة لتجنب callbacks مرتبطة بنشاط قديم.

## حدود هذه المرحلة — مهمة
- هذه ليست بعدُ خدمة نقل تعمل مستقلة بعد إغلاق واجهة التطبيق؛ تدمير `MainActivity` يوقف مستمع RFCOMM وجلسات الأقران النشطة عمداً.
- جلسات RFCOMM المقبولة ومعالجة المصافحة/التشفير/قراءة الرسائل ما زالت تعتمد على `MainActivity` وFlutter MethodChannel لتوقيع transcript. لم ننقلها إلى الخدمة لأن ذلك يتطلب نقل توقيع الهوية إلى Android Keystore أو إبقاء FlutterEngine موثوقاً حياً، دون إضعاف هوية QR.
- اكتشاف Bluetooth وWi-Fi Aware واتصالات Wi-Fi Aware ما زالت مرتبطة بـ `MainActivity`، ولم تُنقل في هذه المرحلة.
- لم نضف BootReceiver أو WorkManager؛ لا توجد بعد آلية استعادة آمنة كاملة للهوية وجلسات Ratchet والنقل.

## التحقق المنفذ
- فحص ساكن لتأكد وجود Binder وملكية `BluetoothServerSocket` في الخدمة، وربط Activity بالخدمة، وبقاء `registerPeer()` بوابة المصافحة.
- فحص XML للـ Manifest واختبار سلامة أرشيف ZIP.
- لم يتم تنفيذ Gradle build أو `flutter analyze` أو اختبار فعلي بين هاتفين؛ أدوات البناء غير متاحة في بيئة العمل الحالية.
