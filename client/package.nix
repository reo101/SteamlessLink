{
  lib,
  stdenv,
  zig,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "steamless-hidraw-client";
  version = "0.1.0";

  # The client depends on ../core as a Zig path dependency, so the source
  # tree must contain both directories.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../core
      ../client
    ];
  };
  sourceRoot = "${finalAttrs.src.name}/client";

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

    install -Dm755 zig-out/bin/steamless-hidraw-client $out/bin/steamless-hidraw-client

    runHook postInstall
  '';

  passthru.services.default = {
    imports = [ ./service.nix ];
    steamless-hidraw-client.package = lib.mkDefault finalAttrs.finalPackage;
  };

  meta = {
    description = "SteamlessLink Linux hidraw-to-network controller bridge";
    mainProgram = "steamless-hidraw-client";
    platforms = lib.platforms.linux;
  };
})
