# Programming toolchains (superset of the old per-host copies).
{
  flake.modules.homeManager.packages-programming = { pkgs, ... }: {
    home.packages = with pkgs; [
      devenv

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

      # Typst
      typst
      tinymist

      # Python
      uv

      # Nim
      nim
      nimble
      nimlangserver

      # Go
      go
      gopls
      golangci-lint
      golangci-lint-langserver
      delve

      # AI
      ollama

      # Kotlin
      kotlin
      kotlin-native
      kotlin-language-server

      # js/ts :(
      bun
      typescript-language-server

      # crystal
      crystal
      shards
      ameba
      ameba-ls

      # vlang
      vlang
    ];
  };
}
