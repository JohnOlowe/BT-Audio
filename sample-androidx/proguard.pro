# Rules for the R8 release build (toolchain/build.sh --release).
# AndroidX code carries optional references to libraries that are not in this
# minimal checkout (Kotlin stdlib, profileinstaller on old devices, ...): warn
# instead of failing, and keep the manifest-referenced entry points.
-dontwarn androidx.**
-dontwarn com.google.android.**

-keep class com.example.axsample.MainActivity { *; }
-keep class com.example.axsample.MainActivity$* { *; }
