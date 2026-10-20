import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

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

// AGP 9 removed the built-in Kotlin Gradle plugin requirement: a module only gets
// Kotlin compilation from AGP's built-in Kotlin (`android.builtInKotlin=true`, the
// AGP 9 default) or from `org.jetbrains.kotlin.android` applied to that module.
// `android.builtInKotlin=false` is still forced here because package_info_plus and
// shared_preferences_android apply the external plugin, which AGP 9 rejects while
// built-in Kotlin is on. Plugins that already target AGP 9 (file_picker) therefore
// skip the external plugin and their Kotlin sources would never be compiled, which
// breaks `:app:compileDebugJavaWithJavac` with "cannot find symbol
// com.mr.flutter.plugin.filepicker.FilePickerPlugin".
//
// Re-apply the Kotlin plugin to any Android library module that ships Kotlin
// sources without it, so the whole build stays on the external Kotlin plugin.
// Delete this block (and set `android.builtInKotlin=true`) once every Android
// plugin in pubspec.yaml supports AGP 9 built-in Kotlin.
subprojects {
    plugins.withId("com.android.library") {
        val hasKotlinSources = file("src").walkTopDown().any { it.isDirectory && it.name == "kotlin" }
        if (hasKotlinSources && !plugins.hasPlugin("org.jetbrains.kotlin.android")) {
            apply(plugin = "org.jetbrains.kotlin.android")
            // AGP 9 modules skip their own `kotlinOptions`, so pin the target to
            // match the Java toolchain (KGP would otherwise default to the JDK).
            extensions.configure<KotlinAndroidProjectExtension> {
                compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
