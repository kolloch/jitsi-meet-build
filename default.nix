{ nixpkgs ? <nixpkgs>
, pkgs ? import nixpkgs {}
, lib ? pkgs.lib
, nodejs ? pkgs.nodejs-12_x
, sources ? import nix/sources.nix
  # If you check out the jitsi-meet sources into ../jitsi-meet,
  # they are automatically picked up.
, jitsiMeetSrc ? if builtins.pathExists ../jitsi-meet
  then
    let
      path = ../jitsi-meet;
    in
      builtins.trace "DEV MODE: Using jitsi-meet sources from ${builtins.toString path}" path
  else sources.jitsi-meet
, gitignoreSrc ? sources.gitignore
, gitignore ? pkgs.callPackage gitignoreSrc {}
}:

rec {
  /* Derives a package including static files and the minified/"compiled" libs. */
  package =
    assert lib.canCleanSource jitsiMeetSrc;
    let
      subDir = name: "${builtins.toString jitsiMeetSrc}/${name}";

      # Copy some directories verbatim into destination.
      staticDirs =
        let subDirInStore = name:
            builtins.path {
              # We want to prevent putting all of the jitsiMeetSrc dir into
              # the store but we DO want to put the sub directory into the store.
              path = subDir name;
              inherit name;
            };
          toSubPathName = name: { inherit name; path = subDirInStore name; };
        in
        builtins.map toSubPathName [
          "connection_optimization"
          "fonts"
          "images"
          "static"
          "sounds"
          "lang"
        ];

      processedDirs =
        let filteredSubDir = name: allowedPatterns:
          assert builtins.isString name;
          assert builtins.isList allowedPatterns;
          {
            inherit name;
            path = lib.sourceByRegex (subDir name) allowedPatterns;
          };
        in
        [
          { name = "libs"; path = internal.libs; }
          # This should also be built and not simply copied
          (filteredSubDir "css" [ "all.css" ])
          (filteredSubDir "resources" [ "robots.css" ])
        ];
      dirs = pkgs.linkFarm "jitsi-meet-dirs" (staticDirs ++ processedDirs);
      staticFiles = lib.sourceByRegex jitsiMeetSrc [
        ''[^.].*\.js''
        ''.*\.html''
        "favicon.ico"
        "LICENSE"
      ];
      joined = pkgs.symlinkJoin {
        name = "jitsi-meet-symlinked";
        paths = [ staticFiles dirs ];
      };
      # Deep copy, ensure no dangling symlinks
    in
      pkgs.runCommand "jitsi-meet-package" {} ''
        cp -RL ${joined} $out
      '';

  internal = {
    # Does not work current. :(
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
      let
        precleaned = lib.cleanSource jitsiMeetSrc;
        prune = name: type:
          let
            baseName = baseNameOf (toString name);
          in
            ! (
              (
                type == "directory" && builtins.elem baseName [
                  "node_modules"
                  "ios"
                  "android"
                  "libs"
                ]
              )
            );
        pruned = lib.cleanSourceWith { filter = prune; src = precleaned; };
      in
        gitignore.gitignoreSource pruned;
  };
}
