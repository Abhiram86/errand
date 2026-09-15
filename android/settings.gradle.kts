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

// Automatically patch third-party plugins with AGP 9.0+ deprecations (e.g. proguard-android.txt)
val pluginsDependenciesFile = file("../.flutter-plugins-dependencies")
if (pluginsDependenciesFile.exists()) {
    try {
        val content = pluginsDependenciesFile.readText()
        val regex = Regex(""""path":\s*"([^"]+)"""")
        regex.findAll(content).forEach { match ->
            val pluginPath = match.groupValues[1]
            val buildGradle = File(pluginPath, "android/build.gradle")
            if (buildGradle.exists()) {
                val script = buildGradle.readText()
                if (script.contains("proguard-android.txt")) {
                    buildGradle.writeText(
                        script.replace("proguard-android.txt", "proguard-android-optimize.txt")
                    )
                }
            }
        }
    } catch (_: Exception) {}
}

