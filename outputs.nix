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
      in
      {
        packages.steamless-uhid-server = pkgs.callPackage ./server/package.nix { zig = serverZig; };
        packages.android-emulator-client = pkgs.callPackage ./nix/android-emulator-client.nix {
          androidSdk = androidEmulatorSdk;
        };
        packages.android-emulator-uhid-test = pkgs.callPackage ./nix/android-emulator-uhid-test.nix {
          androidSdk = androidEmulatorSdk;
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

        apps.android-emulator-uhid-test = {
          type = "app";
          program = lib.getExe self'.packages.android-emulator-uhid-test;
          meta.description = "Run the SteamlessLink fake-controller UHID test in an Android emulator";
        };
        apps.android-emulator-uhid-vm-test = {
          type = "app";
          program = lib.getExe self'.packages.android-emulator-uhid-vm-test;
          meta.description = "Run the Android emulator app against a NixOS UHID VM";
        };

        checks = lib.optionalAttrs pkgs.stdenv.isLinux {
          steamless-uhid-nixos = pkgs.testers.runNixOSTest (import ./nix/tests/steamless-uhid.nix {
            inherit pkgs lib;
            steamlessUhidModule = config.flake.nixosModules.steamless-uhid;
            steamlessUhidPackage = self'.packages.steamless-uhid-server;
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
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/libexec/android-sdk/build-tools/35.0.0/aapt2";

          shellHook = ''
            echo "SteamlessLink Android/Kotlin dev shell"
            echo "  ANDROID_HOME=$ANDROID_HOME"
            echo "  JAVA_HOME=$JAVA_HOME"
          '';
        };
      };
  }
)
