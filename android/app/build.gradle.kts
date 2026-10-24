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
    implementation("androidx.fragment:fragment-ktx:1.9.1")
}

flutter {
    source = "../.."
}
