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
      };
    };

    debug = true;

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

        androidSdk = androidComposition.androidsdk;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            androidSdk
            android-tools
            gradle
            jdk17
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
