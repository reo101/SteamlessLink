{
  craneLib,
  lib,
}:
let
  src = craneLib.cleanCargoSource ../iroh-proxy;
  commonArgs = {
    pname = "steamless-link-iroh-proxy";
    version = "0.1.0";
    inherit src;
    strictDeps = true;
    doCheck = false;
  };

  cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
    cargoHash = "sha256-hIEjRnU+N3mQgaDzyYu5hP9YWlkN9jlfkBDDvCt2tfE=";
  });
in
craneLib.buildPackage (commonArgs // {
  inherit cargoArtifacts;

  meta = {
    description = "Iroh endpoint-ticket proxy for a Steamless Link host";
    license = lib.licenses.mit;
    mainProgram = "steamless-link-iroh-proxy";
  };
})
