{
  lib,
  stdenv,
  craneLibArm64,
  craneLibX86_64,
  fetchFromGitHub,
}:
let
  src = fetchFromGitHub {
    owner = "n0-computer";
    repo = "iroh-ffi";
    rev = "v1.0.0";
    hash = "sha256-AeXnM091a2MWHEJsMYlY/zy8WXKIKWO4uVdAeehWl8k=";
  };

  buildFor = craneLib: abi: pname:
    let
      commonArgs = {
        inherit pname src;
        version = "1.0.0";
        strictDeps = true;
        doCheck = false;
        cargoExtraArgs = "--lib";
      };
      cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
        cargoHash = "sha256-wUkb240T7icWb6X6JOcR5nfLhul+gjs+j4hL4HfSEdU=";
      });
    in
    craneLib.buildPackage (commonArgs // {
      inherit cargoArtifacts;
      installPhase = ''
        runHook preInstall
        lib=$(find target -path '*/release/libiroh_ffi.so' -print -quit)
        test -n "$lib"
        install -D "$lib" $out/jniLibs/${abi}/libiroh_ffi.so
        runHook postInstall
      '';
    });

  arm64 = buildFor craneLibArm64 "arm64-v8a" "iroh-android-jni-arm64-v8a";
  x86_64 = buildFor craneLibX86_64 "x86_64" "iroh-android-jni-x86_64";
in
stdenv.mkDerivation {
  pname = "iroh-android-jni";
  version = "1.0.0";
  dontUnpack = true;
  installPhase = ''
    install -D ${arm64}/jniLibs/arm64-v8a/libiroh_ffi.so $out/jniLibs/arm64-v8a/libiroh_ffi.so
    install -D ${x86_64}/jniLibs/x86_64/libiroh_ffi.so $out/jniLibs/x86_64/libiroh_ffi.so
  '';

  meta = {
    description = "Android JNI library for official iroh Kotlin FFI";
    license = with lib.licenses; [ mit asl20 ];
    platforms = lib.platforms.linux;
  };
}
