# إصلاح أخطاء البناء — بلوساب المرحلة 28

تم إجراء إصلاحات مصدرية على نسخة المرحلة 28 لمعالجة الأخطاء التي ظهرت أثناء `compileFlutterBuildRelease`:

1. `lib/main.dart`: إزالة قوس الإغلاق الزائد في استدعاء `showSnackBar`.
2. `lib/services/local_network_service.dart`: تحويل تدفق `Socket` إلى `Stream<List<int>>` قبل تمريره إلى `utf8.decoder`.
3. `lib/services/pairwise_chain_ratchet_service.dart`: تحويل ناتج `_mac` إلى `Uint8List` عند تحديث سلسلة الاستقبال في الموضعين اللذين ظهرت فيهما أخطاء النوع، مع إضافة استيراد `dart:typed_data`.

## حدود التحقق

تم التحقق من وجود التعديلات في الملفات ومن سلامة أرشيف ZIP بعد إنشائه. لم يتم تشغيل `flutter analyze` أو بناء APK في هذه البيئة؛ لذلك لا يُعد هذا إثباتاً لاجتياز البناء الكامل أو اختبار الاتصال بين هاتفين.
