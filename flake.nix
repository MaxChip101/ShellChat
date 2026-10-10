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

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              zig_0_16
              zls_0_16 # for lsp
              glibc.dev
              pkg-config
              libssh
              postgresql
            ];

            shellHook = ''
              export PGDATA="$PWD/.pg_data"
              export PGHOST="$PWD/.pg_socket"

              if [ ! -d "$PGDATA" ]; then
                mkdir -p "$PGHOST"
                initdb -D "$PGDATA"
                echo "local all all trust" > "$PGDATA/pg_hba.conf"
              fi

              pg_ctl -D "$PGDATA" -o "-k $PGHOST" start
              echo "postgresql started"
            '';
          };
        }
      );
    };
}
