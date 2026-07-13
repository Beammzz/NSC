# R8 optimization inlines MediaPipe's caller-sensitive native-library
# loader, crashing Graph.<clinit> with "no caller found on the stack".
# AGP no longer accepts the non-optimize default proguard file, so disable
# optimization here instead (the AGP-suggested escape hatch).
-dontoptimize

# MediaPipe Tasks resolves protobuf-lite message fields by reflection
# (GeneratedMessageLite looks up fields like `platform_` by name). R8
# renaming/stripping those fields crashes both landmarkers on every frame
# in release builds:
#   RuntimeException: Field platform_ for <obfuscated> not found
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}

# MediaPipe also loads its native library via caller-sensitive stack
# inspection (Graph.<clinit>) and binds JNI callbacks by name; keep the
# whole runtime un-renamed rather than chasing individual entry points.
-keep class com.google.mediapipe.** { *; }

# tasks-vision's AAR references profiling/template protos it doesn't ship;
# they are never used at runtime on this code path.
-dontwarn com.google.mediapipe.proto.**
