# Pinned Hermes Agent v0.23.1 — one definition for every consumer (the service
# unit, the dashboard unit, the `hermes` CLI wrapper, packages.hermes-agent).
#
# What we patch: Telegram DM topic labels. Upstream mirrors the whole session
# title onto the topic ("Opravit push do mobilu přes správný port"), so the
# sidebar fills up with sentence-long names and never shortens. The shortening
# lived in the container-era images/hermes/patches/patch_topic_names.py, which
# the 2026-11-11 native cutover dropped — see that script for the rules (cap 24
# chars by default, `telegram.extra.topic_name_max_chars` to change it, 120 =
# old behaviour).
#
# Why PYTHONPATH and not a source patch: the python tree is the venv the
# upstream flake builds (`hermesVenv`). Its site-packages/gateway is a symlink
# into the app package, both are read-only store paths, and the venv's
# interpreter shim is bound to its own store path — so a copied venv cannot be
# relocated. Instead a copy of the `gateway` package is patched and put FIRST on
# PYTHONPATH for the wrapped binaries; the patched sources are byte-identical to
# the venv's apart from the shortening, so nothing can drift.
{ inputs, pkgs }:
let
  upstream =
    inputs.hermesAgentSrc.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
      version = "0.23.1";
    };

  gatewayPatched = pkgs.runCommandLocal "hermes-gateway-topic-labels" { } ''
    site=$(ls -d ${upstream.hermesVenv}/lib/python*/site-packages | head -1)
    src=$(readlink -f "$site/gateway")
    [ -f "$src/run_topics.py" ] || { echo "topic-label patch: no $src/run_topics.py" >&2; exit 1; }
    mkdir -p $out
    cp -a "$src" $out/gateway
    chmod -R u+w $out/gateway
    TOPIC_PATCH_TARGET=$out/gateway/run_topics.py \
      ${pkgs.python3}/bin/python3 ${../images/hermes/patches/patch_topic_names.py}
  '';
in
pkgs.symlinkJoin {
  name = "hermes-agent-0.23.1-topic-labels";
  paths = [ upstream ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  # The patch only refuses to write a file it cannot verify, so a failed import
  # here would mean the shortening silently did not apply.
  postBuild = ''
    for bin in hermes hermes-acp hermes-agent; do
      [ -e $out/bin/$bin ] || continue
      wrapProgram $out/bin/$bin --prefix PYTHONPATH : ${gatewayPatched}
    done
  '';
}
