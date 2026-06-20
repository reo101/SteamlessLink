inputs:
inputs.flake-parts.lib.mkFlake { inherit inputs; } (
  {
    withSystem,
    flake-parts-lib,
    lib,
    config,
    ...
  }:
  {
    systems = import inputs.systems.outPath;

    imports = [
      inputs.flake-file.flakeModules.default
    ];

    flake-file = {
      nixConfig = {
        commit-lockfile-summary = "chore(flake): update `flake.lock`";
        extra-experimental-features = [
          "pipe-operators"
        ];
      };

      inputs = {
        systems = {
          url = "github:nix-systems/default";
        };

        nixpkgs = {
          url = "github:nixos/nixpkgs/nixos-unstable";
        };

        flake-file = {
          url = "github:vic/flake-file";
        };

        crane = {
          url = "github:ipetkov/crane";
        };

        flake-parts = {
          url = "github:hercules-ci/flake-parts";
          inputs.nixpkgs-lib.follows = "nixpkgs";
        };

        zig-flake = {
          url = "github:silversquirl/zig-flake";
          inputs.nixpkgs.follows = "nixpkgs";
        };

        zls = {
          url = "github:zigtools/zls/0.16.0";
          inputs.nixpkgs.follows = "nixpkgs";
          inputs.zig-flake.follows = "zig-flake";
        };
      };
    };

    debug = true;

    flake =
      let
        steamlessUhidModule =
          { pkgs, lib, ... }:
          {
            imports = [ ./nix/modules/steamless-uhid.nix ];
            services.steamless-uhid.package = lib.mkDefault (
              withSystem pkgs.stdenv.hostPlatform.system ({ self', ... }: self'.packages.steamless-uhid-server)
            );
          };
      in
      {
        nixosModules.steamless-uhid = steamlessUhidModule;
        nixosModules.default = steamlessUhidModule;
      };

    perSystem =
      {
        pkgs,
        system,
        inputs',
        self',
        ...
      }:
      let
        androidPkgs = import inputs.nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
        };

        androidX86_64Pkgs = import inputs.nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
          crossSystem = {
            config = "x86_64-unknown-linux-android";
            rust.rustcTarget = "x86_64-linux-android";
            androidSdkVersion = "35";
            androidNdkVersion = "27";
            useAndroidPrebuilt = true;
          };
        };

        androidComposition = androidPkgs.androidenv.composeAndroidPackages {
          platformVersions = [
            "35"
          ];
          buildToolsVersions = [
            "34.0.0"
            "35.0.0"
          ];
          includeSources = true;
          includeSystemImages = false;
          includeEmulator = false;
          includeNDK = false;
          includeCmake = false;
          extraLicenses = [
            "android-sdk-license"
            "android-sdk-preview-license"
          ];
        };

        androidEmulatorComposition = androidPkgs.androidenv.composeAndroidPackages {
          platformVersions = [ "35" ];
          buildToolsVersions = [
            "34.0.0"
            "35.0.0"
          ];
          abiVersions = [ "x86_64" ];
          systemImageTypes = [ "google_apis" ];
          includeSources = false;
          includeSystemImages = true;
          includeEmulator = true;
          includeNDK = false;
          includeCmake = false;
          extraLicenses = [
            "android-sdk-license"
            "android-sdk-preview-license"
            "android-googletv-license"
            "android-sdk-arm-dbt-license"
            "google-gdk-license"
            "intel-android-extra-license"
            "intel-android-sysimage-license"
          ];
        };

        androidSdk = androidComposition.androidsdk;
        androidEmulatorSdk = androidEmulatorComposition.androidsdk;
        zig = inputs'.zig-flake.packages.zig_0_16_0;
        serverZig = pkgs.zig_0_16 or pkgs.zig;
        craneLib = inputs.crane.mkLib pkgs;
        androidArm64CraneLib = inputs.crane.mkLib androidPkgs.pkgsCross.aarch64-android-prebuilt;
        androidX86_64CraneLib = inputs.crane.mkLib androidX86_64Pkgs;
      in
      {
        packages.steamless-uhid-server = pkgs.callPackage ./server/package.nix { zig = serverZig; };
        packages.steamless-uinput-gamepad = pkgs.callPackage ./nix/uinput-gamepad.nix { zig = serverZig; };
        packages.iroh-android-jni = pkgs.callPackage ./nix/iroh-android-jni.nix {
          craneLibArm64 = androidArm64CraneLib;
          craneLibX86_64 = androidX86_64CraneLib;
        };
        packages.steamless-uhid-iroh-proxy = pkgs.callPackage ./nix/iroh-uhid-proxy.nix {
          inherit craneLib;
        };
        packages.android-emulator-client = pkgs.callPackage ./nix/android-emulator-client.nix {
          androidSdk = androidEmulatorSdk;
        };
        packages.android-emulator-uhid-test = pkgs.callPackage ./nix/android-emulator-uhid-test.nix {
          androidSdk = androidEmulatorSdk;
          steamlessIrohJni = self'.packages.iroh-android-jni;
          steamlessUhidIrohProxy = self'.packages.steamless-uhid-iroh-proxy;
        };
        packages.android-emulator-iroh-test = pkgs.writeShellApplication {
          name = "steamless-android-emulator-iroh-test";
          runtimeInputs = [ self'.packages.android-emulator-uhid-test ];
          text = ''
            STEAMLESS_ANDROID_TEST_IROH=1 exec steamless-android-emulator-uhid-test "$@"
          '';
        };
        packages.android-emulator-uhid-vm-test-driver = pkgs.testers.runNixOSTest (import ./nix/tests/android-emulator-uhid.nix {
          inherit pkgs lib;
          steamlessUhidModule = config.flake.nixosModules.steamless-uhid;
          steamlessUhidPackage = self'.packages.steamless-uhid-server;
          androidEmulatorClient = self'.packages.android-emulator-client;
          androidSdk = androidEmulatorSdk;
        });
        packages.android-emulator-uhid-vm-test = pkgs.callPackage ./nix/android-emulator-uhid-vm-test.nix {
          androidSdk = androidEmulatorSdk;
          testDriver = self'.packages.android-emulator-uhid-vm-test-driver.driver;
        };
        packages.default = self'.packages.steamless-uhid-server;

        apps.steamless-uhid-iroh-proxy = {
          type = "app";
          program = lib.getExe self'.packages.steamless-uhid-iroh-proxy;
          meta.description = "Print an Iroh endpoint ticket and forward it to the local Steamless UHID TCP bridge";
        };
        apps.android-emulator-uhid-test = {
          type = "app";
          program = lib.getExe self'.packages.android-emulator-uhid-test;
          meta.description = "Run the SteamlessLink fake-controller UHID test in an Android emulator";
        };
        apps.android-emulator-iroh-test = {
          type = "app";
          program = lib.getExe self'.packages.android-emulator-iroh-test;
          meta.description = "Run the Android emulator app through Iroh to a fake UHID server";
        };
        apps.android-emulator-uhid-vm-test = {
          type = "app";
          program = lib.getExe self'.packages.android-emulator-uhid-vm-test;
          meta.description = "Run the Android emulator app against a NixOS UHID VM";
        };

        checks = lib.optionalAttrs pkgs.stdenv.isLinux {
          iroh-proxy-roundtrip = pkgs.runCommand "steamless-uhid-iroh-proxy-roundtrip" { nativeBuildInputs = [ pkgs.python3 pkgs.coreutils ]; } ''
            set -euo pipefail
            proxy=${lib.getExe self'.packages.steamless-uhid-iroh-proxy}
            tmp=$(mktemp -d)
            cleanup() { jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$tmp"; }
            trap cleanup EXIT

            python -u - "$tmp/port" <<'PY' &
            import socket, sys
            port_file=sys.argv[1]
            s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(1)
            open(port_file,'w').write(str(s.getsockname()[1]))
            conn,_=s.accept()
            while True:
                data=conn.recv(65536)
                if not data: break
                conn.sendall(data)
            conn.close(); s.close()
            PY

            while [ ! -s "$tmp/port" ]; do sleep 0.05; done
            port=$(cat "$tmp/port")
            STEAMLESS_IROH_BIND_ADDR=127.0.0.1:0 "$proxy" "127.0.0.1:$port" >"$tmp/ticket" 2>"$tmp/proxy.log" &
            for i in $(seq 1 100); do [ -s "$tmp/ticket" ] && break; sleep 0.1; done
            ticket=$(head -n1 "$tmp/ticket")
            printf steamless-iroh-ok | STEAMLESS_IROH_BIND_ADDR=127.0.0.1:0 timeout 30 "$proxy" connect "$ticket" >"$tmp/out"
            test "$(cat "$tmp/out")" = steamless-iroh-ok
            touch $out
          '';
          steamless-uhid-nixos = pkgs.testers.runNixOSTest (import ./nix/tests/steamless-uhid.nix {
            inherit pkgs lib;
            steamlessUhidModule = config.flake.nixosModules.steamless-uhid;
            steamlessUhidPackage = self'.packages.steamless-uhid-server;
          });
          steamless-uinput-gamepad-nixos = pkgs.testers.runNixOSTest (import ./nix/tests/uinput-gamepad.nix {
            inherit pkgs lib;
            uinputGamepadPackage = self'.packages.steamless-uinput-gamepad;
          });
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            androidSdk
            android-tools
            gradle
            jdk17
            zig
            inputs'.zls.packages.default
            kotlin
            kotlin-language-server
            ktlint
            detekt
            jq
            netcat-gnu
            openssl
            usbutils
          ];

          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
          JAVA_HOME = pkgs.jdk17.home;
          IROH_JNI = self'.packages.iroh-android-jni.outPath;
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/libexec/android-sdk/build-tools/35.0.0/aapt2";

          shellHook = ''
            echo "SteamlessLink Android/Kotlin dev shell"
            echo "  ANDROID_HOME=$ANDROID_HOME"
            echo "  JAVA_HOME=$JAVA_HOME"
            echo "  IROH_JNI=$IROH_JNI"
          '';
        };
      };
  }
)
