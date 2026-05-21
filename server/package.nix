{
  stdenvNoCC,
  python3,
}:

stdenvNoCC.mkDerivation {
  pname = "steamless-uhid-server";
  version = "0.1.0";

  src = ./.;
  nativeBuildInputs = [ python3 ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 steamless-uhid-server.py $out/bin/steamless-uhid-server
    patchShebangs $out/bin/steamless-uhid-server

    install -Dm644 60-steamless-uhid.rules $out/lib/udev/rules.d/60-steamless-uhid.rules
    install -Dm644 steamless-uhid.service $out/lib/systemd/system/steamless-uhid.service

    runHook postInstall
  '';
}
