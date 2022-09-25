import <nixpkgs> {
  overlays = [
    (self: super: {
      nur = super.callPackage (import (builtins.fetchTarball {
        url = https://github.com/nix-community/NUR/archive/master.tar.gz;
      })) {};
    })

    (import "${builtins.fetchTarball {
      url = https://github.com/mozilla/nixpkgs-mozilla/archive/master.tar.gz;
    }}/rust-overlay.nix")

    (self: super: {
      inherit (super.nur.repos.tilpner.pkgs) kernelConfig;
    })
  ];
}
