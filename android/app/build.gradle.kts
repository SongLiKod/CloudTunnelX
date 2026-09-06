plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.cloudtunnelx"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.cloudtunnelx"
        // 需求（技术文档 5.1）：最低适配 Android 10 (API 29)
        minSdk = 29
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

    // Android 10+ 禁止执行应用可写目录中的文件（W^X 策略），
    // 内置内核必须作为 .so 放在 jniLibs，并由 install 阶段真实解压到 nativeLibraryDir。
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

dependencies {
    // 桌面图标数字徽标（各厂商 ROM 的广播适配），替代已停更的 flutter_app_badger 插件
    implementation("me.leolin:ShortcutBadger:1.1.22@aar")
}

flutter {
    source = "../.."
}
