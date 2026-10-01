allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// No proguard-android.txt -> proguard-android-optimize.txt patching here.
// That workaround used to rewrite each Flutter plugin's android/build.gradle on
// disk from settings.gradle.kts, which mutated the pub cache during
// configuration: non-reproducible, and rejected by F-Droid's scanner because
// the cache is read-only and pre-scanned. It was also unnecessary — no plugin
// in the current dependency set references the legacy default (verified against
// .flutter-plugins-dependencies), so the block was dead code added in P6a.
//
// If a future dependency genuinely needs the substitution, add it as a Gradle
// convention here (a `subprojects { plugins.withId("com.android.library") … }`
// block), never as a write to a file under the pub cache.

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
