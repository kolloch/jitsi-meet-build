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
, dependencies ? pkgs.callPackage ./nix/dependencies.nix {}
, kollochNurPackages ? import sources.kollochNurPackages {}
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
          { name = "css"; path = internal.buildCss; }
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
    libs = internal.libBuildLibs;

    /* Just copy the libs directory into nix. Requires them to have been built
       outside nix already.
    */
    libsViaCopyImpure = builtins.path { path = "${builtins.toString jitsiMeetSrc}/libs"; };

    libNodeModules =
      let derivation = pkgs.stdenv.mkDerivation {
            name = "jitsi-meet-node-modules";
            src =
              lib.sourceByRegex
                internal.libsSrc [
                  "package.json"
                  "package-lock.json"
                ];
            phases = [ "unpackPhase" "buildPhase" "fixupPhase" ];
            buildInputs = lib.attrValues dependencies.dev;

            buildPhase = ''
              export HOME=$(pwd)
              npm install --ignore-scripts
              mv node_modules $out
            '';
            outputHash = "sha256:1zj5yflf1szk9hcgxjpawz3dnkmwxy9nrjkj9l1ml2kidg0jfqsc";
            outputHashMode = "recursive";
          };
      in
      kollochNurPackages.lib.rerunFixedDerivationOnChange derivation;

    libNodeModulesPlus = pkgs.stdenv.mkDerivation {
      name = "jitsi-meet-lib-webpack";
      buildInputs = lib.attrValues dependencies.dev;
      src = internal.libsSrc;
      phases = [ "unpackPhase" "buildPhase" ];
      buildPhase = ''
        export HOME=$(pwd)
        set -x
        trap 'set +x' ERR

        [ -r node_modules ] && exit 1

        # mkdir node_modules
        # ln -s ${internal.libNodeModules}/{.bin,*} node_modules
        # rm node_modules/lib-jitsi-meet
        # cp -R ${internal.libNodeModules}/lib-jitsi-meet node_modules

        cp -R ${internal.libNodeModules} node_modules
        chmod -R +w node_modules
        pushd node_modules/lib-jitsi-meet
        ../.bin/webpack -p
        [ -r lib-jitsi-meet.min.js \
          -a -r lib-jitsi-meet.min.map ] || exit 2
        popd

        mv node_modules $out

        { set +x; } 2>/dev/null
      '';
    };

    libBuildLibs = pkgs.stdenv.mkDerivation {
      name = "jitsi-meet-build";
      buildInputs = lib.attrValues dependencies.dev;
      src = internal.libsSrc;
      phases = [ "unpackPhase" "buildPhase" ];
      buildPhase = ''
        export HOME=$(pwd)
        set -x
        cp -R ${internal.libNodeModulesPlus} node_modules
        chmod -R +w node_modules
        make compile
        make deploy-init
        make deploy-appbundle
        make deploy-rnnoise-binary
        make deploy-lib-jitsi-meet
        make deploy-libflac
        mkdir $out
        mv libs $out/
        set +x
      '';
    };

    buildCss = pkgs.stdenv.mkDerivation {
      name = "jitsi-meet-css";
      buildInputs = (lib.attrValues dependencies.dev) ++ [
        pkgs.sassc
      ];
      src = internal.libsSrc;
      phases = [ "unpackPhase" "buildPhase" ];
      buildPhase = ''
        export HOME=$(pwd)
        set -x
        cp -R ${internal.libNodeModules} node_modules
        chmod -R +w node_modules
        mkdir $out
        sassc css/main.scss $out/all.css
        { set +x; } 2>/dev/null
      '';
    };

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
