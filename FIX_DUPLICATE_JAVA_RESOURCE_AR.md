# إصلاح دمج موارد Java — المرحلة 29

سبب الفشل كان وجود الملف نفسه داخل اعتمادَي:
- org.bouncycastle:bcprov-jdk18on:1.80
- org.jspecify:jspecify:1.0.0

أُضيف استثناء محدد داخل android { packaging { resources { excludes } } } في android/app/build.gradle:
`META-INF/versions/9/OSGI-INF/MANIFEST.MF`

هذا يستثني ملف metadata المكرر فقط ولا يستثني أصناف Java أو ملفات التشفير.
التحقق المنفذ: فحص وجود قاعدة الاستثناء وفحص سلامة ZIP.
لم يتم تشغيل Flutter/Gradle build في هذه البيئة؛ أعد تشغيل `flutter build apk --release` للتحقق النهائي.
