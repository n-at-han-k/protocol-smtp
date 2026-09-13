{
  description = "protocol-smtp — SMTP protocol abstractions for Ruby";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # bundlerEnv builds its own two-file "gemfile-and-lockfile" store dir,
        # but our Gemfile says `gemspec` — which makes bundler look for a
        # *.gemspec beside the Gemfile it is reading. In the store that
        # neighbour does not exist, so resolution dies with "There are no
        # gemspecs at /nix/store/...". extraConfigPaths is cp -r'd into that
        # same dir; the trailing /. copies the contents rather than the
        # hash-named directory itself. version.rb comes along because
        # protocol-smtp.gemspec require_relative's it for the version.
        gemspecFiles = pkgs.runCommand "protocol-smtp-gemspec" { } ''
          mkdir -p $out/lib/protocol/smtp
          cp ${./protocol-smtp.gemspec}           $out/protocol-smtp.gemspec
          cp ${./lib/protocol/smtp/version.rb}    $out/lib/protocol/smtp/version.rb
        '';

        gems = pkgs.bundlerEnv {
          name = "protocol-smtp-gems";
          ruby = pkgs.ruby_3_4;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.lock;
          gemset = ./gemset.nix;
          extraConfigPaths = [ "${gemspecFiles}/." ];
        };

      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = with pkgs; [
            trufflehog
            bundix
            gems
            gems.wrappedRuby
            libyaml
            openssl
          ];

          shellHook = ''
            # bundlerEnv resolves `gemspec` against its store copy, so
            # protocol-smtp itself is a path gem pointing there. Put the
            # working tree ahead of it: edits to lib/ take effect without
            # re-evaluating the flake.
            export RUBYLIB="$PWD/lib''${RUBYLIB:+:$RUBYLIB}"

            if [ ! -f .git/hooks/pre-commit ]; then
              bundle exec lefthook install
            fi
          '';
        };
      }
    );
}
