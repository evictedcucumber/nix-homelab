{
  projectRootFile = "flake.nix";

  programs = {
    deadnix.enable = true;
    just.enable = true;
    nixfmt.enable = true;
    statix.enable = true;
  };
}
