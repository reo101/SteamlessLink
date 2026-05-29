{
  lib,
  stdenv,
  zig,
}:

stdenv.mkDerivation {
  pname = "steamless-uhid-server";
  version = "0.1.0";

  src = ./.;
  nativeBuildInputs = [ zig ];
  hardeningDisable = [ "fortify" ];

  dontConfigure = true;

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
    export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local-cache
  '';

  buildPhase = ''
    runHook preBuild

    zig build \
      --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
      --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
      -Doptimize=ReleaseSafe \
      -Dcpu=baseline

    runHook postBuild
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    zig build test \
      --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
      --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
      -Doptimize=ReleaseSafe \
      -Dcpu=baseline

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 zig-out/bin/steamless-uhid-server $out/bin/steamless-uhid-server

    install -Dm644 60-steamless-uhid.rules $out/lib/udev/rules.d/60-steamless-uhid.rules
    install -Dm644 steamless-uhid.service $out/lib/systemd/system/steamless-uhid.service

    runHook postInstall
  '';

  meta = {
    description = "SteamlessLink raw Triton-to-UHID bridge";
    mainProgram = "steamless-uhid-server";
    platforms = lib.platforms.linux;
  };
}
