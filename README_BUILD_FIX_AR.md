إصلاح خطأ Core Library Desugaring

تم تفعيل coreLibraryDesugaringEnabled في android/app/build.gradle وإضافة الاعتماد:
com.android.tools:desugar_jdk_libs:2.1.4

بعد استيراد المشروع، أعد بناء APK. لم يتم اختبار بناء Flutter فعليًا في هذه البيئة.
