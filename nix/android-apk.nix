{
  lib,
  stdenv,
  gradle,
  jdk17,
  zig,
  androidSdk,
  irohJni,
  nativeDependencies,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "steamlesslink-android-apk";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../app
      ../core
      ../native
      ../build.gradle.kts
      ../settings.gradle.kts
      ../gradle.properties
    ];
  };
  nativeBuildInputs = [
    gradle
    jdk17
    zig
  ];
  mitmCache = gradle.fetchDeps {
    pkg = finalAttrs.finalPackage;
    data = ./gradle-dependencies.json;
  };
  ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
  ANDROID_SDK_ROOT = finalAttrs.ANDROID_HOME;
  JAVA_HOME = jdk17.home;
  IROH_JNI = irohJni;
  STEAMLESS_ZIG_PACKAGES = nativeDependencies;
  GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${finalAttrs.ANDROID_HOME}/build-tools/35.0.0/aapt2";
  preConfigure = ''
    export HOME="$TMPDIR/home"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    mkdir -p "$HOME"
    export ANDROID_USER_HOME="$HOME/.android"
    export GRADLE_OPTS="$GRADLE_OPTS -Duser.home=$HOME"
  '';
  # The dependency replay hook runs after preConfigure. Normalize its proxy
  # address before Zig parses the environment, including during updates.
  preBuild = ''
    if [ -n "''${MITM_CACHE_ADDRESS-}" ]; then
      export http_proxy="http://$MITM_CACHE_ADDRESS"
      export https_proxy="$http_proxy"
    fi
  '';
  gradleFlags = [ "--max-workers=4" ];
  gradleBuildTask = ":app:assembleDebug :app:assembleDebugAndroidTest";
  doCheck = true;
  gradleCheckTask = ":app:testDebugUnitTest :app:lintDebug :app:testZigProtocol :app:testJniEnvironment";
  gradleUpdateTask = "${finalAttrs.gradleBuildTask} ${finalAttrs.gradleCheckTask}";
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    install -m644 app/build/outputs/apk/debug/app-debug.apk "$out/app-debug.apk"
    install -m644 app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk "$out/app-debug-androidTest.apk"
    runHook postInstall
  '';
  meta = {
    description = "SteamlessLink debug app and instrumentation APKs, signed with a public test key";
    platforms = lib.platforms.linux;
  };
})
