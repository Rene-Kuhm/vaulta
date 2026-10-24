import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(propertyName: String, envName: String): String? {
    return (keystoreProperties[propertyName] as String?) ?: System.getenv(envName)
}

val releaseStoreFile = signingValue("storeFile", "VAULTA_UPLOAD_STORE_FILE")
val releaseStorePassword = signingValue("storePassword", "VAULTA_UPLOAD_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "VAULTA_UPLOAD_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "VAULTA_UPLOAD_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "com.insyd.gestor_contrasenas"
    compileSdk = flutter.compileSdkVersion
    // androidx.biometric 1.4.0-alpha07 ships AAR metadata that requires
    // compileSdk 36.1 or later. AGP 8.x ignored the minor revision, AGP 9
    // enforces it at `:app:checkDebugAarMetadata`, so pin it explicitly
    // instead of jumping a whole API level.
    compileSdkMinor = 1
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.insyd.gestor_contrasenas"
        // Bumped to 23 so we can use AndroidKeyStore RSA keys with
        // setUserAuthenticationRequired(true). The biometric prompt
        // + androidx.biometric API used by MainActivity requires 23+.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Instrumented tests under android/app/src/androidTest run through
        // AndroidJUnitRunner. The suite drives the real KeystoreChannel
        // method-call surface on the device it runs on, so the API < 30
        // biometric refusal is verified by execution instead of by reading
        // (see docs/verification/api30-biometric-refusal.md).
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // androidx.biometric powers the BiometricPrompt used by
    // MainActivity. androidx.fragment is required transitively by
    // FlutterFragmentActivity when targeting the AndroidX support
    // library. Both are pinned to the Flutter-recommended versions.
    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Release builds must not use debug signing. Provide key.properties
            // (gitignored) or VAULTA_UPLOAD_* environment variables to sign.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// AGP 9 deprecates `android.kotlinOptions`; with the external Kotlin plugin
// (android.builtInKotlin=false) the target is set through the KGP DSL instead.
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // androidx.biometric: 1.4.0-alpha07 is the latest preview on the
    // 1.4 line (alpha builds are functionally stable per the AndroidX
    // release notes). It fixes the API drift that alpha05 was showing
    // on compileSdk 36 and is the version AndroidX now recommends for
    // projects targeting Android 14/15.
    implementation("androidx.biometric:biometric:1.4.0-alpha07")
    implementation("androidx.fragment:fragment-ktx:1.6.2")

    // Instrumented test entry point. `runner` brings AndroidJUnitRunner and
    // InstrumentationRegistry (through androidx.test:monitor); `ext:junit`
    // brings the AndroidJUnit4 runner. Nothing else is needed: the refusal
    // test talks to AndroidKeyStore and BiometricManager, both framework
    // APIs, and instantiates the production channel directly.
    //
    // Versions are pinned to what the `integration_test` dev dependency
    // already puts on the debug runtime classpath (runner 1.3.0, monitor
    // 1.3.0): AGP resolves the androidTest configuration consistently with
    // the app's, so asking for a newer androidx.test here fails with
    // "Cannot find a version of 'androidx.test:runner' that satisfies the
    // version constraints".
    androidTestImplementation("androidx.test:runner:1.3.0")
    androidTestImplementation("androidx.test.ext:junit:1.1.2") {
        // androidx.test:core 1.3.0 declares InstrumentationActivityInvoker's
        // activities without android:exported, which the manifest merger
        // rejects for an app targeting Android 12+. The runner JUnit4 class
        // and InstrumentationRegistry both come from androidx.test:monitor
        // (through runner), so core is not on the path this suite uses.
        exclude(group = "androidx.test", module = "core")
    }
}

flutter {
    source = "../.."
}
