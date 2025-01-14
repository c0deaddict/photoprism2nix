# https://github.com/andir/infra/blob/0edaea917ac9baaa63017d959659c6593e8451ed/config/modules/photoprism.nix
# https://github.com/andir/infra/blob/a19923352c9abcc6a905e6a2b919a41d6c378ef7/nix/packages/photoprism/default.nix

{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-22.05";
    ranz2nix = {
      url = "github:andir/ranz2nix";
      flake = false;
    };
    photoprism = {
      url = "github:photoprism/photoprism/220528-efb5d710";
      flake = false;
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    flake-utils.url = "github:numtide/flake-utils";
    gomod2nix = {
      url = "github:tweag/gomod2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nasnet = {
      url = "https://dl.photoprism.org/tensorflow/nasnet.zip";
      flake = false;
    };
    nsfw = {
      url = "https://dl.photoprism.org/tensorflow/nsfw.zip";
      flake = false;
    };
    facenet = {
      url = "https://dl.photoprism.org/tensorflow/facenet.zip";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, ranz2nix, photoprism, flake-utils, gomod2nix
    , flake-compat, nasnet, nsfw, facenet }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" "i686-linux" ]
    (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlay gomod2nix.overlay ];
          config = { allowUnsupportedSystem = true; };
        };
      in with pkgs; rec {
        packages = flake-utils.lib.flattenTree {
          photoprism = pkgs.photoprism;
          gomod2nix = pkgs.gomod2nix;
        };

        defaultPackage = packages.photoprism;

        checks.build = packages.photoprism;

        devShell = mkShell {
          shellHook = ''
            # ${pkgs.photoprism}/bin/photoprism --admin-password photoprism --import-path ~/Pictures \
            #  --assets-path ${pkgs.photoprism.assets} start
          '';
        };
      }) // {
        nixosModules.photoprism = { lib, pkgs, config, ... }:
          let cfg = config.services.photoprism;
          in {
            options = with lib; {
              services.photoprism = {
                enable = mkOption {
                  type = types.bool;
                  default = false;
                };

                mysql = mkOption {
                  type = types.bool;
                  default = false;
                };

                port = mkOption {
                  type = types.int;
                  default = 2342;
                };

                host = mkOption {
                  type = types.str;
                  default = "127.0.0.1";
                };

                keyFile = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    for sops path
                     sops.secrets.photoprism-password = {
                       owner = "photoprism";
                       sopsFile = ../../secrets/secrets.yaml;
                       path = "/var/lib/photoprism/keyFile";
                     };
                     #PHOTOPRISM_ADMIN_PASSWORD=<yourpassword>
                  '';
                };

                dataDir = mkOption {
                  type = types.path;
                  default = "/var/lib/photoprism";
                  description = ''
                    Data directory for photoprism
                  '';
                };

                package = mkOption {
                  type = types.package;
                  default = self.outputs.packages."${pkgs.system}".photoprism;
                  description = "The photoprism package.";
                };
              };
            };

            config = with lib;
              mkIf cfg.enable {
                users.users.photoprism = {
                  isSystemUser = true;
                  group = "photoprism";
                };

                users.groups.photoprism = { };

                services.mysql = mkIf cfg.mysql {
                  enable = true;
                  ensureDatabases = [ "photoprism" ];
                  ensureUsers = [{
                    name = "photoprism";
                    ensurePermissions = { "photoprism.*" = "ALL PRIVILEGES"; };
                  }];
                };

                systemd.services.photoprism = {
                  enable = true;
                  after = [ "network-online.target" ]
                    ++ lib.optional cfg.mysql "mysql.service";
                  wantedBy = [ "multi-user.target" ];

                  confinement = {
                    enable = true;
                    binSh = null;
                    packages = [
                      cfg.package
                      cfg.package.libtensorflow-bin
                      pkgs.cacert
                      pkgs.coreutils
                      pkgs.darktable
                      pkgs.ffmpeg
                      pkgs.exiftool
                      pkgs.libheif
                    ];
                  };

                  path = [
                    pkgs.coreutils
                    pkgs.darktable
                    pkgs.ffmpeg
                    pkgs.exiftool
                    pkgs.libheif
                  ];

                  script = ''
                    exec ${cfg.package}/bin/photoprism --assets-path ${cfg.package.assets} start
                  '';

                  serviceConfig = {
                    User = "photoprism";
                    BindPaths = [ "/var/lib/photoprism" ]
                      ++ lib.optionals cfg.mysql [
                        "-/run/mysqld"
                        "-/var/run/mysqld"
                      ];
                    RuntimeDirectory = "photoprism";
                    CacheDirectory = "photoprism";
                    StateDirectory = "photoprism";
                    SyslogIdentifier = "photoprism";
                    PrivateTmp = true;
                    PrivateUsers = true;
                    PrivateDevices = true;
                    ProtectClock = true;
                    ProtectKernelLogs = true;
                    SystemCallArchitectures = "native";
                    RestrictNamespaces = true;
                    RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
                    RestrictSUIDSGID = true;
                    NoNewPrivileges = true;
                    RemoveIPC = true;
                    LockPersonality = true;
                    ProtectHome = true;
                    ProtectHostname = true;
                    RestrictRealtime = true;
                    SystemCallFilter =
                      [ "@system-service" "~@privileged" "~@resources" ];
                    SystemCallErrorNumber = "EPERM";
                    EnvironmentFile = mkIf cfg.keyFile "${cfg.dataDir}/keyFile";
                  };

                  environment = {
                    SSL_CERT_DIR = "${pkgs.cacert}/etc/ssl/certs";
                  } // (lib.mapAttrs'
                    (n: v: lib.nameValuePair "PHOTOPRISM_${n}" (toString v)) {
                      DATABASE_DRIVER =
                        if !cfg.mysql then "sqlite" else "mysql";
                      DATABASE_DSN = if !cfg.mysql then
                        "${cfg.dataDir}/photoprism.sqlite"
                      else
                        "photoprism@unix(/run/mysqld/mysqld.sock)/photoprism?charset=utf8mb4,utf8&parseTime=true";
                      ORIGINALS_LIMIT = "1000000";
                      HTTP_HOST = "${cfg.host}";
                      HTTP_PORT = "${toString cfg.port}";
                      HTTP_MODE = "release";
                      PUBLIC = "false";
                      READONLY = "false";
                      SIDECAR_PATH = "${cfg.dataDir}/sidecar";
                      STORAGE_PATH = "${cfg.dataDir}/storage";
                      ASSETS_PATH = "${cfg.package.assets}";
                      ORIGINALS_PATH = "${cfg.dataDir}/originals";
                      IMPORT_PATH = "${cfg.dataDir}/import";
                      UPLOAD_NSFW = "true";
                      DETECT_NSFW = "true";
                      # prefer darktable?
                      DISABLE_RAWTHERAPEE = "true";
                    } // (if !cfg.keyFile then {
                      ADMIN_PASSWORD = "photoprism";
                    } else
                      { }));
                };
              };
          };

        overlay = final: prev: {
          go = prev.go_1_18;
          photoprism = with final;
            (let
              src = photoprism;

              libtensorflow-bin = pkgs.libtensorflow-bin.overrideAttrs (old: {
                # 21.05 does not have libtensorflow-bin 1.x anymore & photoprism isn't compatible with tensorflow 2.x yet
                # https://github.com/photoprism/photoprism/issues/222
                src = fetchurl {
                  url =
                    "https://dl.photoprism.app/tensorflow/amd64/libtensorflow-amd64-avx2-1.15.2.tar.gz";
                  sha256 =
                    "sha256-zu50uqgT/7DIjLzvJNJ624z+bTXjEljS5Gfq0fK7CjQ=";
                };

                buildCommand = old.buildCommand + ''
                  ln -sf $out/lib/libtensorflow.so $out/lib/libtensorflow.so.1
                  ln -sf $out/lib/libtensorflow_framework.so $out/lib/libtensorflow_framework.so.1
                '';
              });
            in buildGoApplication {
              name = "photoprism";
              inherit src;

              subPackages = [ "cmd/photoprism" ];

              modules = ./gomod2nix.toml;

              CGO_ENABLED = "1";
              # https://github.com/mattn/go-sqlite3/issues/803
              CGO_CFLAGS = "-Wno-return-local-addr";

              buildInputs = [ libtensorflow-bin ];

              prePatch = ''
                substituteInPlace internal/commands/passwd.go --replace '/bin/stty' "${coreutils}/bin/stty"
                sed -i 's/zip.Deflate/zip.Store/g' internal/api/download_zip.go
              '';

              passthru = rec {
                inherit libtensorflow-bin;
                frontend = let
                  noderanz = callPackage ranz2nix {
                    nodejs = nodejs-14_x;
                    sourcePath = src + "/frontend";
                  };
                  node_modules = noderanz.patchedBuild;
                in stdenv.mkDerivation {
                  name = "photoprism-frontend";
                  nativeBuildInputs = [ nodejs-14_x ];

                  inherit src;

                  sourceRoot = "source/frontend";

                  postUnpack = ''
                    chmod -R +rw .
                  '';

                  NODE_ENV = "production";

                  buildPhase = ''
                    export HOME=$(mktemp -d)
                    ln -sf ${node_modules}/node_modules node_modules
                    ln -sf ${node_modules.lockFile} package-lock.json
                    npm run build
                  '';
                  installPhase = ''
                    cp -rv ../assets/static/build $out
                  '';
                };

                assets = runCommand "photoprism-assets" { } ''
                  cp -rv ${src}/assets $out
                  chmod -R +rw $out
                  rm -rf $out/static/build
                  cp -rv ${frontend} $out/static/build
                  ln -s ${nsfw} $out/nsfw
                  ln -s ${nasnet} $out/nasnet
                  ln -s ${facenet} $out/facenet
                '';
              };
            });
        };

        checks.x86_64-linux.integration = let
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            overlays = [ self.overlay ];
          };
        in pkgs.nixosTest (import ./integration-test.nix {
          photoprismModule = self.nixosModules.photoprism;
        });
      };
}
