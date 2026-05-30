{
  lib,
  stdenv,
  zig,
}:

stdenv.mkDerivation {
  pname = "steamless-uinput-gamepad";
  version = "0.1.0";
  src = lib.cleanSource ../.;

  nativeBuildInputs = [ zig ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    zig build-exe \
      -O ReleaseSafe \
      -fstrip \
      -femit-bin=steamless-uinput-gamepad \
      native/src/uinput_gamepad.zig
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 steamless-uinput-gamepad \
      $out/bin/steamless-uinput-gamepad
    runHook postInstall
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    zig test native/src/uinput_gamepad.zig
    runHook postCheck
  '';

  meta = {
    description = "SteamlessLink local uinput Xbox gamepad helper";
    mainProgram = "steamless-uinput-gamepad";
    platforms = lib.platforms.linux;
  };
}
