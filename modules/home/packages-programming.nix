# Programming toolchains (superset of the old per-host copies).
# Heavy tools (kotlin-native, emacs, ollama, zed) live in packages-heavy.nix.
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

      # Lisp
      sbcl
      chicken

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

      # Kotlin
      kotlin
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
