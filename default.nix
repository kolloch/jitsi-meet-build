{ nixpkgs ? <nixpkgs>
, pkgs ? import nixpkgs {}
, lib ? pkgs.lib
, nodejs ? pkgs.nodejs-12_x
, sources ? import nix/sources.nix
, jitsiMeetSrc ?
    # if you check out your sources in a parallel directory,
    # they are automatically picked up.
    if builtins.pathExists ../jitsi-meet
    then
        let path = ../jitsi-meet;
        in builtins.trace "DEV MODE: Using jitsi-meet sources from ${builtins.toString path}" path
    else sources.jitsi-meet
}:

rec {
  /* Derives a package including static files and the minified/"compiled" libs. */
  package =
    let
      dirs = pkgs.linkFarm "jitsi-meet-libs" [
        { name = "libs"; path = internal.libs; }
        {
          # This should also be built and not simply copied
          name = "css";
          path =
            lib.sourceByRegex
              "${builtins.toString jitsiMeetSrc}/css"
              [ "all.css" ];
        }
        {
          name = "resources";
          path =
            lib.sourceByRegex
              "${builtins.toString jitsiMeetSrc}/resources"
              [ "robots.txt" ];
        }
      ];
      staticFiles = lib.sourceByRegex jitsiMeetSrc [
        ''[^.].*\.js''
        ''.*\.html''
        "connection_optimization"
        "favicon.ico"
        "fonts"
        "images"
        "static"
        "sounds"
        "LICENSE"
        "lang"
      ];
    in
      pkgs.symlinkJoin {
        name = "jitsi-meet-package";
        paths = [ staticFiles dirs ];
      };

  internal = {
    # libs = internal.libsViaNode2Nix;
    libs = internal.libsViaCopy;

    /* Just copy the libs directory into nix. Requires them to have been built
       outside nix already.
    */
    libsViaCopy = builtins.path { path = "${builtins.toString jitsiMeetSrc}/libs"; };

    libsViaNode2Nix =
      let
        nodeEnv = import ./node2nix/node-env.nix {
          inherit (pkgs) stdenv python2 utillinux runCommand writeTextFile;
          inherit nodejs;
          libtool = if pkgs.stdenv.isDarwin then pkgs.darwin.cctools else null;
        };
        nodePackages = import ./node2nix/node-packages.nix {
          inherit (pkgs) fetchurl fetchgit;
          inherit nodeEnv;
        };
      in
        nodeEnv.buildNodePackage
          (
            nodePackages.args // {
              src = internal.libsSrc;
              dontNpmInstall = true;
              buildInputs = [
                pkgs.nodePackages.webpack-cli
                pkgs.breakpointHook
              ];
              preInstall = ''
                echo "XXXXXXXXXXXXXXX ALIAS FOR webpack XXXXXXXXXXXXXX"
                alias webpack=webpack-cli
              '';
            }
          );

    buildTools = pkgs.callPackage ./node2nix/build-tools/default.nix {};
    webpack = internal.buildTools."webpack-cli-3.1.2";

    /* Returns the cleaned sources for the jtisi-meet libs. */
    libsSrc =
        assert lib.canCleanSource jitsiMeetSrc;
        let precleaned = lib.cleanSource jitsiMeetSrc;
            prune = name: type:
                let baseName = baseNameOf (toString name); in ! (
                    (type == "directory" && builtins.elem baseName [
                        "node_modules"
                        "ios"
                        "android"
                        "libs"
                    ])
                );
            pruned = lib.cleanSourceWith { filter = prune; src = precleaned; };
        in pruned;
  };
}
