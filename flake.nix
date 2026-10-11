{
  description = "An SSH server for chatting and games written in zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          zig = pkgs.zig_0_16;
          server =
            let
              deps = pkgs.callPackage ./build.zig.zon.nix { };
            in
            pkgs.stdenv.mkDerivation {
              pname = "chat_server";
              version = "0.0.1";
              src = ./.;
              nativeBuildInputs = [
                zig.hook
                pkgs.pkg-config
              ];
              buildInputs = [ pkgs.libssh ];
              zigBuildFlags = [
                "--release=fast"
                "--system"
                "${deps}"
              ];
            };

          chatServer = pkgs.writeShellApplication {
            name = "chat_server";
            runtimeInputs = [
              pkgs.postgresql
              pkgs.openssh
              pkgs.coreutils
              pkgs.gnugrep
              server
            ];
            text = ''
              export DB_NAME="''${DB_NAME:-chat_server}"
              STATE="''${CHAT_STATE_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/ssh-chat-server}"
              mkdir -p "$STATE/bin"
              cd "$STATE"

              if [ ! -f bin/ssh_host_ed25519_key ]; then
                ssh-keygen -t ed25519 -f bin/ssh_host_ed25519_key -N "" -q
              fi

              if [ ! -f bin/init.lua ]; then
                cp ${./template.lua} bin/init.lua
                chmod u+w bin/init.lua
              fi

              if [ -z "''${PGHOST:-}" ]; then
                export PGDATA="$STATE/pgdata"
                PGHOST="''${XDG_RUNTIME_DIR:-/tmp}/ssh-chat-pg-$(id -u)"
                export PGHOST
                PGUSER="$(id -un)"
                export PGUSER
                mkdir -p "$PGHOST"
                chmod 700 "$PGHOST"
                [ -d "$PGDATA" ] || initdb -D "$PGDATA" -E UTF8 --locale=C.UTF-8 -A trust >/dev/null
                if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
                  pg_ctl -D "$PGDATA" -l "$STATE/postgres.log" -w \
                    -o "-c listen_addresses= -c unix_socket_directories=$PGHOST" start >/dev/null
                fi
                trap 'pg_ctl -D "$PGDATA" stop -m fast >/dev/null 2>&1' EXIT
                trap 'exit 143' TERM INT
              fi

              psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 \
              || createdb "$DB_NAME"
              psql -q -v ON_ERROR_STOP=1 -d "$DB_NAME" -f ${./init.sql}

              install -m 755 "$(command -v ssh_server)" bin/ssh_server
              ./bin/ssh_server "$@"
            '';
          };
        in
        {
          inherit server;
          default = chatServer;
        }
      );
      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/chat_server";
        };
      });

      devShells = forAllSystems (
        pkgs:
        let
          makeDatabase = pkgs.writeShellApplication {
            name = "make-database";
            runtimeInputs = [
              pkgs.postgresql
              pkgs.gnugrep
            ];
            text = ''
                        DB_NAME="''${DB_NAME:-chat_server}"
              psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 \
                || createdb "$DB_NAME"
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -f ./init.sql
            '';
          };
          resetDatabase = pkgs.writeShellApplication {
            name = "reset-database";
            runtimeInputs = [
              pkgs.postgresql
              makeDatabase
            ];
            text = ''
                        dropdb --if-exists "''${DB_NAME:-chat_server}"
              make-database
            '';
          };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              zig_0_16
              zls_0_16
              glibc.dev
              pkg-config
              libssh
              postgresql
              openssh
              makeDatabase
              resetDatabase
            ];
            shellHook = ''
              export PGDATA="$PWD/.pg_data"
              export PGHOST="$PWD/.pg_socket"
              mkdir -p "$PGHOST"
              [ -d "$PGDATA" ] || initdb -D "$PGDATA" -E UTF8 --locale=C.UTF-8 -A trust >/dev/null
              if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
                pg_ctl -D "$PGDATA" -l "$PWD/.pg_log" -w \
                -o "-c listen_addresses= -c unix_socket_directories=$PGHOST" start >/dev/null
                echo "postgresql started"
              fi
              make-database
              trap 'pg_ctl -D "$PGDATA" stop -m fast >/dev/null 2>&1' EXIT
            '';
          };
        }
      );
    };
}
