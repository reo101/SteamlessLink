{
  craneLib,
  lib,
}:
let
  src = craneLib.cleanCargoSource ../iroh-proxy;
  commonArgs = {
    pname = "steamless-uhid-iroh-proxy";
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
    description = "Iroh endpoint-ticket proxy for the SteamlessLink UHID TCP bridge";
    license = lib.licenses.mit;
    mainProgram = "steamless-uhid-iroh-proxy";
  };
})
