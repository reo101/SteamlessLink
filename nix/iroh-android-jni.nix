{
  lib,
  stdenv,
  craneLibArm64,
  fetchFromGitHub,
}:
let
  src = fetchFromGitHub {
    owner = "n0-computer";
    repo = "iroh-ffi";
    rev = "v1.0.0";
    hash = "sha256-AeXnM091a2MWHEJsMYlY/zy8WXKIKWO4uVdAeehWl8k=";
  };

  commonArgs = {
    pname = "iroh-android-jni-arm64-v8a";
    version = "1.0.0";
    inherit src;
    strictDeps = true;
    doCheck = false;
    cargoExtraArgs = "--lib";
  };

  cargoArtifacts = craneLibArm64.buildDepsOnly (commonArgs // {
    cargoHash = "sha256-wUkb240T7icWb6X6JOcR5nfLhul+gjs+j4hL4HfSEdU=";
  });

  arm64 = craneLibArm64.buildPackage (commonArgs // {
    inherit cargoArtifacts;
    installPhase = ''
      runHook preInstall
      lib=$(find target -path '*/release/libiroh_ffi.so' -print -quit)
      test -n "$lib"
      install -D "$lib" $out/jniLibs/arm64-v8a/libiroh_ffi.so
      runHook postInstall
    '';
  });
in
stdenv.mkDerivation {
  pname = "iroh-android-jni";
  version = "1.0.0";
  dontUnpack = true;
  installPhase = ''
    mkdir -p $out
    cp -r ${arm64}/jniLibs $out/
  '';

  meta = {
    description = "Android JNI library for official iroh Kotlin FFI";
    license = with lib.licenses; [ mit asl20 ];
    platforms = lib.platforms.linux;
  };
}
