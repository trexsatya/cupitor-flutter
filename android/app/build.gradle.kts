plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.satya.cupitor"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // flutter_local_notifications 18 needs Java 8+ API desugaring to
        // support scheduled notifications back to older Android versions.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.satya.cupitor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // youtubedl-android requires minSdk 24+ (it ships Python + native libs
        // that only build for Android 7.0+). Flutter's default would be lower
        // but every device we target is well above this.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 OFF for release.
            //
            // youtubedl-android bundles three layers that R8 can't reason
            // about statically: jackson polymorphic deserializers, the
            // jackson-kotlin-module (kotlin.reflect-driven), and apache
            // commons-compress for unpacking the Python interpreter tarball.
            // Each of these does reflective concrete-class lookups inside
            // a static initializer, so any single missed keep rule reproduces
            // the same crash: "INIT_FAILED ... is not a concrete class".
            // Iterating keep rules round-by-round is fragile; the AAR is
            // already ~30 MB (Python + yt-dlp), so the marginal size win from
            // R8 is negligible. proguard-rules.pro is retained as a safety
            // net should anyone re-enable minification later.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // youtubedl-android ships the Python interpreter as a native lib and then
    // forks/execs it as a regular binary, which only works when the .so files
    // are extracted to disk. Modern AGP defaults to packaging natives inside
    // the APK uncompressed (extractNativeLibs=false), which breaks the exec.
    // Force legacy packaging so they land in /data/.../lib/<abi>/.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // youtubedl-android: bundles yt-dlp + Python so we can fetch YouTube
    // captions without fighting YouTube's PO-token wall. Adds ~30 MB to the
    // APK (Python interpreter + yt-dlp). Published on Maven Central by
    // junkfood02 (the upstream README points here) — bump the version when
    // YouTube changes break captions; junkfood02 repackages within days.
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    // Coroutines are required by youtubedl-android internally and we use
    // them in MainActivity to call YoutubeDL off the main thread.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    // androidx.media — MediaSessionCompat lets us claim media key events from
    // wired/Bluetooth headsets while the dialog1 language page is playing
    // YouTube videos in its iframe. Without an active session, headset
    // play/pause/next/prev are routed to whichever app the system thinks
    // owns audio (often the YT iframe's own internal session), and we have no
    // hook to add custom behavior like "repeat previous video".
    implementation("androidx.media:media:1.7.0")
    // Required by flutter_local_notifications 18 (core library desugaring,
    // see compileOptions above).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
