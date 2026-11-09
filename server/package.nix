{
  lib,
  pkgs,
  stdenv,
  zig,
}:
let
  # Upstream Zig links a native Linux program against musl. Build for the
  # host's glibc and set the NixOS loader so the daemon and its tests run.
  zigFlags = [
    "-Dtarget=${stdenv.hostPlatform.parsed.cpu.name}-linux-gnu"
    "-Ddynamic-linker=${pkgs.glibc}/lib/${
      {
        x86_64 = "ld-linux-x86-64.so.2";
        aarch64 = "ld-linux-aarch64.so.1";
        i686 = "ld-linux.so.2";
        armv7l = "ld-linux-armhf.so.3";
      }
      .${stdenv.hostPlatform.parsed.cpu.name}
    }"
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "steamless-link-host";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../core
      ../server
    ];
  };
  sourceRoot = "${finalAttrs.src.name}/server";
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
      -Doptimize=ReleaseSafe \
      -Dcpu=baseline \
      ${lib.escapeShellArgs zigFlags}

    runHook postBuild
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    zig build test \
      --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
      -Doptimize=ReleaseSafe \
      -Dcpu=baseline \
      ${lib.escapeShellArgs zigFlags}

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
})
