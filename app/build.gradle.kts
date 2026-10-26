import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.OutputDirectory
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

abstract class GeneratedDirectoryTask : Exec() {
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
}

val zigVersion = providers.exec { commandLine("zig", "version") }.standardOutput.asText.map(String::trim)
val zigPackages = providers.environmentVariable("STEAMLESS_ZIG_PACKAGES")
val zigDependencyArguments = zigPackages.orNull?.let { listOf("--system", it) }.orEmpty()
val packageZigNative = providers.gradleProperty("steamless.buildZig").map(String::toBoolean).orElse(true)
val packageUinputHelper = providers.gradleProperty("steamless.buildUinputHelper").map(String::toBoolean).orElse(true)
val irohJniLibsDir = providers.gradleProperty("steamless.irohJniLibs")
    .orElse(providers.environmentVariable("STEAMLESS_IROH_JNI_LIBS"))
    .orElse(providers.environmentVariable("IROH_JNI").map { "$it/jniLibs" })
val zigSources = fileTree(rootProject.file("native/src")) { include("**/*.zig") }
val zigCoreSources = fileTree(rootProject.file("core/src")) { include("**/*.zig", "**/*.tsv") }
val zigBuildFiles = rootProject.files("native/build.zig", "native/build.zig.zon", "core/build.zig", "core/build.zig.zon")
val androidTargets = listOf("arm64-v8a" to "aarch64-linux-android", "x86_64" to "x86_64-linux-android")

android {
    namespace = "xyz.reo101.steamlesslink"
    compileSdk = 35
    defaultConfig {
        applicationId = "xyz.reo101.steamlesslink"
        minSdk = 26
        targetSdk = 35
        versionCode = providers.gradleProperty("steamless.versionCode").map(String::toInt).getOrElse(1)
        versionName = providers.gradleProperty("steamless.versionName").getOrElse("0.1.0")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    // Public test key. Never use it for a release or trust it as an identity.
    signingConfigs.getByName("debug") {
        storeFile = file("debug.keystore")
        storePassword = "android"
        keyAlias = "androiddebugkey"
        keyPassword = "android"
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets["test"].resources.srcDir(rootProject.file("core/src/testdata"))
    irohJniLibsDir.orNull?.let { sourceSets["main"].jniLibs.srcDir(file(it)) }
    packaging {
        jniLibs.keepDebugSymbols += listOf("**/libsteamless_protocol.so", "**/libiroh_ffi.so")
        resources.excludes += listOf("darwin-aarch64/**", "win32-x86-64/**")
    }
}
kotlin.compilerOptions.jvmTarget.set(JvmTarget.JVM_17)

val generateProtocolConstants = tasks.register("generateProtocolConstants")
val buildZigNative = tasks.register("buildZigNative")
val buildUinputHelper = tasks.register("buildUinputHelper")

// AGP assigns each generated directory and carries its producer into lint and packaging.
androidComponents.onVariants { variant ->
    val variantName = variant.name.replaceFirstChar(Char::uppercaseChar)
    val protocol = tasks.register<GeneratedDirectoryTask>("generate${variantName}ProtocolConstants") {
        inputs.files(zigCoreSources, zigBuildFiles)
        inputs.property("zigVersion", zigVersion)
        workingDir(rootProject.file("core"))
        doFirst {
            val output = outputDirectory.file("xyz/reo101/steamlesslink/protocol/ProtocolConstants.kt").get().asFile
            output.parentFile.mkdirs()
            commandLine("zig", "build", "generate-kotlin", "-j4", "-Doptimize=ReleaseSafe",
                "-Dkotlin-output=${output.absolutePath}",
                "--cache-dir", layout.buildDirectory.dir("generated/protocol/cache").get().asFile.absolutePath)
        }
    }
    variant.sources.java?.addGeneratedSourceDirectory(protocol) { it.outputDirectory }
    generateProtocolConstants.configure { dependsOn(protocol) }

    for ((abi, target) in androidTargets) {
        val suffix = abi.split('-', '_').joinToString("") { it.replaceFirstChar(Char::uppercaseChar) }
        if (packageZigNative.get()) {
            val library = tasks.register<GeneratedDirectoryTask>("build${variantName}Zig$suffix") {
                inputs.files(zigSources, zigCoreSources, zigBuildFiles)
                inputs.property("zigVersion", zigVersion)
                inputs.property("zigTarget", target)
                inputs.property("zigOptimize", "ReleaseSafe")
                inputs.property("zigStrip", true)
                zigPackages.orNull?.let { inputs.dir(it) }
                workingDir(rootProject.file("native"))
                doFirst {
                    commandLine(listOf("zig", "build", "-j4", "-Dtarget=$target", "-Doptimize=ReleaseSafe", "-Dstrip=true",
                        "--prefix", outputDirectory.dir(abi).get().asFile.absolutePath, "--prefix-lib-dir", ".",
                        "--cache-dir", layout.buildDirectory.dir("generated/zig/cache/$abi").get().asFile.absolutePath,
                    ) + zigDependencyArguments)
                }
            }
            variant.sources.jniLibs?.addGeneratedSourceDirectory(library) { it.outputDirectory }
            buildZigNative.configure { dependsOn(library) }
        }
        if (packageUinputHelper.get()) {
            val helper = tasks.register<GeneratedDirectoryTask>("build${variantName}UinputHelper$suffix") {
                inputs.files(zigSources, zigCoreSources, zigBuildFiles)
                inputs.property("zigVersion", zigVersion)
                inputs.property("zigTarget", target)
                inputs.property("zigOptimize", "ReleaseSafe")
                inputs.property("zigStrip", true)
                zigPackages.orNull?.let { inputs.dir(it) }
                workingDir(rootProject.file("native"))
                doFirst {
                    commandLine(listOf("zig", "build", "uinput", "-j4", "-Dtarget=$target", "-Doptimize=ReleaseSafe", "-Dstrip=true",
                        "--prefix", outputDirectory.dir("uinput/$abi").get().asFile.absolutePath, "--prefix-exe-dir", ".",
                        "--cache-dir", layout.buildDirectory.dir("generated/zig/cache/$abi").get().asFile.absolutePath,
                    ) + zigDependencyArguments)
                }
            }
            variant.sources.assets?.addGeneratedSourceDirectory(helper) { it.outputDirectory }
            buildUinputHelper.configure { dependsOn(helper) }
        }
    }
}

tasks.register<Exec>("testZigProtocol") {
    inputs.files(zigCoreSources, zigBuildFiles)
    inputs.property("zigVersion", zigVersion)
    workingDir(rootProject.file("core"))
    commandLine("zig", "build", "test", "-j4", "-Doptimize=ReleaseSafe")
}
tasks.register<Exec>("testJniEnvironment") {
    inputs.files(zigSources, zigCoreSources, zigBuildFiles)
    inputs.property("zigVersion", zigVersion)
    zigPackages.orNull?.let { inputs.dir(it) }
    workingDir(rootProject.file("native"))
    commandLine(listOf("zig", "build", "test", "-j4", "-Doptimize=ReleaseSafe") + zigDependencyArguments)
}
tasks.named("check") { if (packageZigNative.get()) dependsOn("testZigProtocol", "testJniEnvironment") }

dependencies {
    implementation("computer.iroh:iroh:1.2.0") { exclude(group = "net.java.dev.jna", module = "jna") }
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("junit:junit:4.13.2")
}
