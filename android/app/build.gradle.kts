import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取 release 签名配置（android/key.properties，由 CI 从 Secrets 生成或本地手写）。
// 未配置时回退 debug 签名：本地 debug.keystore 固定故可持久；但 GitHub Actions 每次运行
// 都会生成全新 debug 密钥，导致各次 Release 签名互不相同，应用内升级必报"与已安装应用签名不同"。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.cloudtunnelx"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
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
            // 配置了 key.properties 时使用稳定签名密钥，保证应用内更新可覆盖安装；
            // 否则回退 debug 签名以便 `flutter run --release` 本地可用。
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
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
    // 桌面图标数字徽标：ShortcutBadger 已停更且 Android 8.0+ 不显示，
    // 现由 MainActivity 通过「setNumber 静默通知」原生实现（不依赖第三方库）
}

flutter {
    source = "../.."
}
