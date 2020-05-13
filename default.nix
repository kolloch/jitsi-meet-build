{ nixpkgs ? <nixpkgs>
, pkgs ? import nixpkgs {}
, lib ? pkgs.lib
, nodejs ? pkgs.nodejs-12_x
, sources ? import nix/sources.nix
, forceSources ? false
  # If you check out the jitsi-meet sources into ../jitsi-meet,
  # they are automatically picked up.
, jitsiMeetSrc ? if !forceSources && builtins.pathExists ../jitsi-meet
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
  /* Copy it all together. */
  package =
    let src = internal.libsSrc;
    in
    pkgs.runCommand "jitsi-meet-package" {} ''
      mkdir $out
      cp ${src}/*.{js,html} $out
      cp ${src}/{favicon.ico,LICENSE,resources/robots.txt} $out
      cp -R ${src}/{connection_optimization,fonts,images,static,sounds,lang} $out

      mkdir $out/css
      cp ${internal.buildCss}/all.css $out/css

      cp -R ${internal.libs}/libs $out
    '';

  internal = {
    # Does not work current. :(
    # libs = internal.libsViaNode2Nix;
    libs = internal.libBuildLibs;

    libNodeModules =
      let install = pkgs.stdenv.mkDerivation {
            name = "jitsi-meet-node-modules";
            src =
              if lib.canCleanSource internal.libsSrc
              then lib.sourceByRegex
                internal.libsSrc [
                  "package.json"
                  "package-lock.json"
                ]
              else internal.libsSrc;

            # No "fixupPhase" because that changes paths
            # dependent on the node version
            phases = [ "unpackPhase" "buildPhase" ];
            buildInputs = lib.attrValues dependencies.dev;

            buildPhase = ''
              export HOME=$(pwd)
              npm install --ignore-scripts
              mv node_modules $out
            '';
            outputHash = "sha256:1c71x1g0dbvbvjxd5ylqhqkncrf620agdh24m4k47rhl5fbl545w";
            outputHashMode = "recursive";
          };

          installOnChange = kollochNurPackages.lib.rerunFixedDerivationOnChange install;

          installFixup = pkgs.stdenv.mkDerivation {
            name = "jitsi-meet-node-modules-fixup";
            src = installOnChange;

            # No "fixupPhase" because that changes paths
            # dependent on the node version
            phases = [ "unpackPhase" "buildPhase" "fixupPhase" ];
            buildInputs = lib.attrValues dependencies.dev;

            buildPhase = ''
              mkdir $out
              cp -R $src/{.[!.]*,*} $out
              chmod -R +w $out
            '';
          };
      in installFixup;

    libNodeModulesPlus = pkgs.stdenv.mkDerivation {
      name = "jitsi-meet-lib-webpack";
      buildInputs = lib.attrValues dependencies.dev;
      src = internal.libsSrc;
      phases = [ "unpackPhase" "buildPhase" ];
      buildPhase = ''
        export HOME=$(pwd)
        (
          set -x
          cp -R ${internal.libNodeModules} node_modules
          chmod -R +w node_modules
          cd node_modules/lib-jitsi-meet
          ../.bin/webpack -p
          [ -r lib-jitsi-meet.min.js \
            -a -r lib-jitsi-meet.min.map ] || exit 2
        )
        mv node_modules $out
      '';
    };

    libBuildLibs = pkgs.stdenv.mkDerivation {
      name = "jitsi-meet-build";
      buildInputs = lib.attrValues dependencies.dev;
      src = internal.libsSrc;
      phases = [ "unpackPhase" "buildPhase" ];
      buildPhase = ''
        export HOME=$(pwd)
        (
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
        )
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
        ln -s ${internal.libNodeModules} node_modules
        mkdir $out
        sassc css/main.scss $out/all.css
        { set +x; } 2>/dev/null
      '';
    };

    /* Returns the cleaned sources for the jtisi-meet libs. */
    libsSrc =
      if lib.isDerivation jitsiMeetSrc || lib.isStorePath jitsiMeetSrc
      then jitsiMeetSrc
      else internal.libsSrcFromLocal;

    /* Clean local sources to speed up initial nix store import. */
    libsSrcFromLocal =
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
