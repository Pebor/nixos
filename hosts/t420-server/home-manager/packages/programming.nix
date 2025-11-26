{ pkgs, ...}: {
  home.packages = with pkgs; [
    # Bash
    shellcheck
    bash-language-server

    # Nix
    nil
    nixd

    # Rust
    rustup

    # C/C++
    clang-tools
    gcc
    kdePackages.qtdeclarative

    # "IDE"
    zed-editor-fhs

    # Lisp
    emacs-pgtk
    sbcl
    chicken
    emacs-all-the-icons-fonts
  ];
}
