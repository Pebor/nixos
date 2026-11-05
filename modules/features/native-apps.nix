# Native desktop apps from ~/launchpad, ~/watcher, ~/webtest.
#
# MyGo binaries dlopen their toolkit at runtime (glib/GTK/WebKit), so they need
# LD_LIBRARY_PATH pointing at the nix store paths. Rather than polluting the
# whole session env, wrap each binary: the wrapper is what lands on PATH, and it
# execs the Go binary that build.sh installs into ~/.local/bin.
{ ... }:
{
  flake.modules.homeManager.native-apps = { pkgs, ... }:
    let
      nativeLibs = with pkgs; [
        libx11 libxcursor libxrandr libxi libxcb libxkbcommon
        mesa vulkan-loader wayland fontconfig freetype
        glib gtk3 pango cairo gdk-pixbuf harfbuzz libepoxy
        webkitgtk_4_1 libsoup_3 glib-networking gtk-layer-shell
      ];
      wrapNative = name: pkgs.writeShellScriptBin name ''
        export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath nativeLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules"
        # tasks-api listens on the tailnet; override per host if that changes
        export TASKS_API="''${TASKS_API:-http://100.103.136.50:8001}"
        exec "$HOME/.local/bin/${name}" "$@"
      '';
    in {
      home.packages = [
        (wrapNative "launchpad")
        (wrapNative "agent-watch")
        (wrapNative "webtest")
      ];
    };
}
