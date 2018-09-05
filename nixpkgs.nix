import <nixpkgs> {
  overlays = [
    (self: super: {
      nur = super.callPackage (import (builtins.fetchTarball {
        url = https://github.com/nix-community/NUR/archive/master.tar.gz;
      })) {};
    })
  ];
}
