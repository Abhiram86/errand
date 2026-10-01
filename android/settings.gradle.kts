pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

// NOTE: this file deliberately does NOT modify plugin sources under the pub
// cache. An earlier version rewrote each plugin's android/build.gradle here,
// substituting the AGP-9 renamed `proguard-android.txt` for
// `proguard-android-optimize.txt`. That mutated files outside the repository at
// configure time, which breaks build reproducibility and is rejected by
// F-Droid's scanner (the cache is read-only and scanned before the build).
// No replacement convention was needed: no plugin in the current dependency
// set references the legacy default (verified against
// .flutter-plugins-dependencies), so the block was dead code. If a future
// dependency genuinely needs the substitution, add it as a Gradle convention
// in android/build.gradle.kts — never as a write to the pub cache.

