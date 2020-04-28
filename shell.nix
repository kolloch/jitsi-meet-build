{ sources ? import ./nix/sources.nix
, pkgs ? import sources.nixpkgs {}
, dependencies ? pkgs.callPackage ./nix/dependencies.nix {}
, lib ? pkgs.lib
}:

pkgs.mkShell {
  buildInputs = lib.attrValues dependencies.dev;

  shellHook = ''
  '';
}
