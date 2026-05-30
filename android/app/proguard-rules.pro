# R8 keep rules for youtubedl-android and friends.
#
# Symptom this file fixes:
#   PlatformException(INIT_FAILED, ExceptionInInitializerError →
#     RuntimeException: class S2.a is not a concrete class)
#
# Root cause: R8 obfuscates + may strip / make-abstract classes the library
# discovers reflectively (jackson polymorphic deserializers, the Python
# bridge classes shipped inside the AAR). The library's static initializer
# then fails on the first YoutubeDL.init(...) call. Keeping the relevant
# packages whole is the minimum needed.

# --- youtubedl-android (JunkFood02 fork + upstream yausername packages) ---
-keep class com.yausername.** { *; }
-keep interface com.yausername.** { *; }
-dontwarn com.yausername.**

-keep class io.github.junkfood02.** { *; }
-keep interface io.github.junkfood02.** { *; }
-dontwarn io.github.junkfood02.**

# --- Jackson (used to parse yt-dlp's --dump-json output) ---
# Jackson uses reflection on @JsonProperty/@JsonCreator and on polymorphic
# type info — stripping or renaming any of these blows up at init time.
-keep class com.fasterxml.jackson.** { *; }
-keep interface com.fasterxml.jackson.** { *; }
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
-dontwarn com.fasterxml.jackson.**

# --- Kotlin Reflect / Metadata (jackson-module-kotlin uses these) ---
-keep class kotlin.Metadata { *; }
-keep class kotlin.reflect.** { *; }
-dontwarn kotlin.reflect.**
-dontwarn kotlinx.coroutines.**

# Don't strip the no-arg constructors jackson needs to instantiate POJOs.
-keepclassmembers class * {
    @com.fasterxml.jackson.annotation.JsonCreator <init>(...);
    @com.fasterxml.jackson.annotation.JsonProperty <fields>;
    @com.fasterxml.jackson.annotation.JsonProperty <methods>;
}

# General: enums need their values()/valueOf() kept for Jackson lookups.
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
