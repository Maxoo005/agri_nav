plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.agri_nav"
    // Nadpisane ponad flutter.compileSdkVersion (35) — flutter_secure_storage
    // wymaga kompilacji przeciw SDK 36. Bezpieczne: compileSdk tylko określa,
    // z jakich API korzystamy przy kompilacji, nie wpływa na minimalną wersję
    // Androida potrzebną do uruchomienia apki (to robi minSdk niżej).
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.agri_nav"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Nadpisane ponad flutter.minSdkVersion (21) — flutter_secure_storage
        // wymaga minSdk 23 (Android 6.0, 2015+). Wszystkie realnie używane
        // telefony dawno przekroczyły ten próg.
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../../CMakeLists.txt")
            version = "3.21.0+"
        }
    }
}

flutter {
    source = "../.."
}
