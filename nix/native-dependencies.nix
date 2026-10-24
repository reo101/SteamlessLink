{
  lib,
  stdenvNoCC,
  zig,
  git,
  cacert,
}:
stdenvNoCC.mkDerivation {
  pname = "steamless-native-dependencies";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../core
      ../native
    ];
  };
  nativeBuildInputs = [
    zig
    git
    cacert
  ];
  dontConfigure = true;
  dontFixup = true;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = "sha256-Aot5Wby7AYl9Y96pmEUyHC69gtHW2jwPCTL01Fo/Yko=";
  buildPhase = ''
    export HOME="$TMPDIR/home"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    mkdir -p "$HOME"
    cd native
    zig build --fetch
  '';
  installPhase = ''
    cp -r zig-pkg "$out"
  '';
}
