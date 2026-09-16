# Big/rarely-needed programs split out of packages-apps and
# packages-programming so fresh installs (t14) can skip them and get a
# fast first boot. t490s and desktop import this to stay unchanged.
{
  flake.modules.homeManager.packages-heavy = { pkgs, ... }: {
    home.packages = with pkgs; [
      # GUI apps (from packages-apps)
      vscode
      qemu
      godot
      libreoffice-stable
      hunspell
      hunspellDicts.cs_CZ
      hunspellDicts.en-us

      # Dev tools (from packages-programming)
      kotlin-native
      emacs-pgtk
      emacs-all-the-icons-fonts
      ollama
      zed-editor-fhs
    ];
  };
}
