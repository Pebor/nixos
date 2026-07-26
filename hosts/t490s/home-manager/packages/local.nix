{pkgs,...}:
  let
    rmenuSrc = fetchGit {
      url = "/home/pebor/Documents/Programming/rust/rmenu";
    };
  in
{
    home.packages = [
      (pkgs.callPackage "${rmenuSrc}/package.nix" { })
    ];
}
