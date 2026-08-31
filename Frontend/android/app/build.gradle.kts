import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- release signing -------------------------------------------------------
// Credentials resolve from android/key.properties (local release builds) or the
// ANDROID_* environment variables (CI decodes ANDROID_KEYSTORE_BASE64 into
// place). Both are absent on a plain checkout, and the release build then falls
// back to the debug key so `flutter run --release` keeps working.
val keystoreProperties =
    Properties().apply {
        val file = rootProject.file("key.properties")
        if (file.exists()) file.inputStream().use { load(it) }
    }

// Explicit null/blank handling: an empty secret in CI must count as "absent",
// not as an empty password that fails deep inside the signing task.
fun signingValue(
    propertyKey: String,
    envKey: String,
): String? =
    (keystoreProperties.getProperty(propertyKey) ?: System.getenv(envKey))
        ?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")

val hasReleaseSigning =
    releaseStoreFile != null &&
        releaseStorePassword != null &&
        releaseKeyAlias != null &&
        releaseKeyPassword != null &&
        rootProject.file(releaseStoreFile).exists()

// Printed at configuration time so the CI log states the signing identity
// outright, instead of it having to be inferred from the artifact.
logger.lifecycle(
    if (hasReleaseSigning) {
        "SignMind signing: release builds use the configured upload keystore."
    } else {
        "SignMind signing: no release keystore resolved — release builds fall back to the DEBUG key."
    },
)

android {
    namespace = "com.signmind.signmind"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // MediaPipe .task models are already compressed; storing them uncompressed
    // lets the Tasks runtime mmap them directly from the APK.
    androidResources {
        noCompress += "task"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.signmind.signmind"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Real upload key when key.properties or the ANDROID_* env vars are
            // present; otherwise the debug key, exactly as before. A debug-signed
            // build canNOT be installed as an update over a Play-signed one — the
            // "SignMind signing:" line in the build log says which was used.
            signingConfig =
                signingConfigs.findByName("release")
                    ?: signingConfigs.getByName("debug")
            // Keeps MediaPipe's protobuf-lite reflection fields (see
            // proguard-rules.pro) — without this the scanner is dead in
            // release builds.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // Compress native libs so the OS extracts them at install time,
    // working around 16 KB page-alignment issues in third-party .so
    // files (MediaPipe, CameraX, libflutter.so) until upstream ships
    // aligned binaries.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // CameraX for the native scanner preview + MediaPipe analysis (Stage B).
    val cameraxVersion = "1.3.4"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-view:$cameraxVersion")

    // MediaPipe Tasks Vision: on-device HandLandmarker + PoseLandmarker (Stage B3).
    implementation("com.google.mediapipe:tasks-vision:0.10.14")
}
