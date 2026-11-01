# إصلاح أخطاء Kotlin الظاهرة في سجل البناء

تم إصلاح الأخطاء الظاهرة في صور سجل KlenCode:
- توحيد أسماء callbacks في MainActivity مع واجهة `BlousabBackgroundService.startWifiAware`.
- تمرير callbacks المطلوبة: بدء النشر، بدء الاشتراك، اكتشاف الخدمة، استقبال الرسائل، وفقدان الخدمة.
- إضافة مخزن `wifiPassphrases` وربطه بنتيجة المصافحة الموثقة قبل السماح بمسار بيانات Wi-Fi.
- إزالة استخدام `BluetoothSocket.soTimeout` لأنه ليس خاصية متاحة في Android BluetoothSocket.

مهم: تم إصلاح الأخطاء المحددة في الصور فقط. لم يتم تشغيل Gradle/Kotlin compiler أو اختبار APK/هاتفين هنا؛ قد تظهر أخطاء أخرى عند إعادة البناء.
