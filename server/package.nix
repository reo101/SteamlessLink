{
  lib,
  stdenv,
  zig,
}:

stdenv.mkDerivation {
  pname = "steamless-link-host";
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

    install -Dm755 zig-out/bin/steamless-link-host $out/bin/steamless-link-host

    install -Dm644 60-steamless-link-host.rules $out/lib/udev/rules.d/60-steamless-link-host.rules
    install -Dm644 steamless-link-host.service $out/lib/systemd/system/steamless-link-host.service

    runHook postInstall
  '';

  meta = {
    description = "Steamless Link host for remote controllers";
    mainProgram = "steamless-link-host";
    platforms = lib.platforms.linux;
  };
}
