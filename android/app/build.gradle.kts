plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mreader.app"
    compileSdk = flutter.compileSdkVersion
    // M3.5-T03（架构 §G.3 ①）ndkVersion 校准记录：规格候选值 27.0.12077973 的
    // 前提是「FRB 在 Flutter ≥3.32 下需 NDK ≥27」；本机 Flutter 3.47.5 默认
    // flutter.ndkVersion = 28.2.13676358 ≥ 27，**满足前提 → 维持默认、不硬编码**，
    // 免去额外安装 NDK 27。真机构建验证（gate ①）若报 NDK 缺失/不匹配再在此改值。
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mreader.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
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
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
