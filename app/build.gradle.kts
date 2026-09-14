plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val zigJniLibsDir = layout.buildDirectory.dir("generated/zig/jniLibs")
val uinputHelperAssetsDir = layout.buildDirectory.dir("generated/uinput/assets")
val irohJniLibsDir = providers.gradleProperty("steamless.irohJniLibs")
    .orElse(providers.environmentVariable("STEAMLESS_IROH_JNI_LIBS"))
    .orElse(providers.environmentVariable("IROH_JNI").map { "$it/jniLibs" })
val packageZigNative = providers.gradleProperty("steamless.buildZig")
    .map { it.toBoolean() }
    .orElse(true)
val packageUinputHelper = providers.gradleProperty("steamless.buildUinputHelper")
    .map { it.toBoolean() }
    .orElse(true)
val zigSources = fileTree(rootProject.file("native/src")) {
    include("**/*.zig")
}
val zigCoreSources = fileTree(rootProject.file("core/src")) {
    include("**/*.zig")
}
val zigCoreRoot = rootProject.file("core/src/root.zig")
val protocolGenerator = rootProject.file("core/src/generate_kotlin_protocol.zig")
val generatedProtocolDir = layout.buildDirectory.dir("generated/source/protocol/main")
val generatedProtocolFile = generatedProtocolDir.map {
    it.file("xyz/reo101/steamlesslink/protocol/ProtocolConstants.kt")
}
val zigAndroidTargets = listOf(
    "arm64-v8a" to "aarch64-linux-android",
    "x86_64" to "x86_64-linux-android",
)
val uinputHelperTargets = listOf(
    "arm64-v8a" to "aarch64-linux-android",
    "x86_64" to "x86_64-linux-android",
)

android {
    namespace = "xyz.reo101.steamlesslink"
    compileSdk = 35

    defaultConfig {
        applicationId = "xyz.reo101.steamlesslink"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets["main"].java.srcDir(generatedProtocolDir)
    if (packageZigNative.get()) {
        sourceSets["main"].jniLibs.srcDir(zigJniLibsDir)
    }
    if (packageUinputHelper.get()) {
        sourceSets["main"].assets.srcDir(uinputHelperAssetsDir)
    }
    irohJniLibsDir.orNull?.let { sourceSets["main"].jniLibs.srcDir(file(it)) }

    packaging {
        jniLibs.keepDebugSymbols += listOf("**/libsteamless_protocol.so", "**/libiroh_ffi.so")
        resources.excludes += listOf("darwin-aarch64/**", "win32-x86-64/**")
    }
}

val generateProtocolConstants = tasks.register<Exec>("generateProtocolConstants") {
    inputs.files(zigCoreSources, protocolGenerator)
    outputs.file(generatedProtocolFile)

    doFirst {
        generatedProtocolFile.get().asFile.parentFile.mkdirs()
    }

    commandLine(
        "zig",
        "run",
        protocolGenerator.absolutePath,
        "--",
        generatedProtocolFile.get().asFile.absolutePath,
    )
}

val zigNativeTasks = zigAndroidTargets.map { (abi, target) ->
    val taskName = "buildZig" + abi
        .split('-', '_')
        .joinToString("") { part -> part.replaceFirstChar(Char::uppercaseChar) }
    val outputFile = zigJniLibsDir.map { it.file("$abi/libsteamless_protocol.so") }

    tasks.register<Exec>(taskName) {
        inputs.files(zigSources, zigCoreSources)
        inputs.property("zigTarget", target)
        inputs.property("zigOptimize", "ReleaseSafe")
        inputs.property("zigStrip", true)
        outputs.file(outputFile)

        doFirst {
            outputFile.get().asFile.parentFile.mkdirs()
        }

        commandLine(
            "zig",
            "build-lib",
            "-dynamic",
            "-target",
            target,
            "-O",
            "ReleaseSafe",
            "-fstrip",
            "-femit-bin=${outputFile.get().asFile.absolutePath}",
            "--dep",
            "steamless-core",
            "-Mroot=${rootProject.file("native/src/jni.zig").absolutePath}",
            "-Msteamless-core=${zigCoreRoot.absolutePath}",
        )
    }
}

val buildZigNative = tasks.register("buildZigNative") {
    dependsOn(zigNativeTasks)
}

val uinputHelperTasks = uinputHelperTargets.map { (abi, target) ->
    val taskName = "buildUinputHelper" + abi
        .split('-', '_')
        .joinToString("") { part -> part.replaceFirstChar(Char::uppercaseChar) }
    val outputFile = uinputHelperAssetsDir.map { it.file("uinput/$abi/steamless-uinput-gamepad") }

    tasks.register<Exec>(taskName) {
        inputs.file(rootProject.file("native/src/uinput_gamepad.zig"))
        inputs.property("zigTarget", target)
        inputs.property("zigOptimize", "ReleaseSafe")
        inputs.property("zigStrip", true)
        outputs.file(outputFile)

        doFirst {
            outputFile.get().asFile.parentFile.mkdirs()
        }

        commandLine(
            "zig",
            "build-exe",
            "-target",
            target,
            "-O",
            "ReleaseSafe",
            "-fstrip",
            "-femit-bin=${outputFile.get().asFile.absolutePath}",
            rootProject.file("native/src/uinput_gamepad.zig").absolutePath,
        )
    }
}

val buildUinputHelper = tasks.register("buildUinputHelper") {
    dependsOn(uinputHelperTasks)
}

tasks.register<Exec>("testZigProtocol") {
    inputs.files(zigCoreSources)
    commandLine("zig", "test", zigCoreRoot.absolutePath)
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }.configureEach {
    dependsOn(generateProtocolConstants)
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }.configureEach {
    if (packageZigNative.get()) dependsOn(buildZigNative)
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Assets") }.configureEach {
    if (packageUinputHelper.get()) dependsOn(buildUinputHelper)
}

tasks.named("check") {
    if (packageZigNative.get()) dependsOn("testZigProtocol")
}

dependencies {
    implementation("computer.iroh:iroh:1.0.0") {
        exclude(group = "net.java.dev.jna", module = "jna")
    }
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("junit:junit:4.13.2")
}
