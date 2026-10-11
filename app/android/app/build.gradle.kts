plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Ladybird's helpers, libwebby.so, its resources and the launcher icon are copied in by scripts/android/build_apk.sh,
// which then runs `flutter build apk`.
android {
    namespace = "dev.webby.webby"
    compileSdk = flutter.compileSdkVersion
    // The NDK scripts/android/build_ladybird.sh builds Ladybird with.
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "dev.webby.webby"
        // Ladybird's Android build targets API 30 (Android 11).
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // Ladybird is only built for arm64.
            abiFilters += listOf("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            // Install native libraries as real files. Ladybird's helper processes (libWebContent.so, ...) are
            // executables the app runs from its native library directory, the one place Android lets an app
            // execute files from.
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // No release keystore yet; sign with the debug key so the APK installs.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
