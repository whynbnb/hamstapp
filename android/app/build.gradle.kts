plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "me.whynbnb.hamstapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "me.whynbnb.hamstapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Ship arm64-v8a only (smaller APK). Override per build with
        // `flutter build apk --target-platform android-arm64`.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        // App version shown to the system and the user.
        versionName = "1.0"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFile("proguard-rules.pro")
        }
    }

    packaging {
        resources {
            // BouncyCastle ships ~1.2MB of unused resource bundles (PQC Picnic
            // constant tables, X.509 message catalogs, ...). We only use MD4 /
            // AES-CMAC, so drop all of them plus JAR metadata.
            excludes += setOf(
                "org/bouncycastle/**",
                "META-INF/**",
                "DebugProbesKt.bin",
                "kotlin/*.kotlin_builtins",
                "kotlin/**/*.kotlin_builtins",
            )
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
    // Remote APK sources: FTP + SMB (Samba) clients.
    implementation("commons-net:commons-net:3.11.1")
    implementation("eu.agno3.jcifs:jcifs-ng:2.1.10")
}
