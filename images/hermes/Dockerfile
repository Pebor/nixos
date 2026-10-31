# Derived Hermes image: the upstream image plus our source patches and our own
# plugins/scripts baked in.
#
# Why: code applied at runtime under /opt/hermes or kept in the state volume
# (/opt/data/plugins) is duct tape — an image pull, a container re-create or a
# lost volume drops it silently. Everything here is git-tracked, so the running
# code is reproducible and reviewable (card #52).
#
# Build (host):
#   docker build -t hermes-agent:patched /home/server/nixos/images/hermes
# In practice systemd does it: hermes-image-build.service, which
# docker-hermes.service requires, so a failed build leaves the previous image in
# place instead of a container that cannot start.
FROM nousresearch/hermes-agent:latest

# 1) Patches. Each script is idempotent and refuses to write on an anchor
#    mismatch, so an upstream rewrite breaks the BUILD here instead of shipping
#    half-patched code.
COPY patches/ /opt/hermes-patches/
RUN /opt/hermes/.venv/bin/python /opt/hermes-patches/patch_topic_names.py \
 && /opt/hermes/.venv/bin/python /opt/hermes-patches/patch_dm_topic_thread.py \
 && /opt/hermes/.venv/bin/python -c "import py_compile; \
      py_compile.compile('/opt/hermes/gateway/run_topics.py', doraise=True); \
      py_compile.compile('/opt/hermes/plugins/platforms/telegram/adapter.py', doraise=True); \
      print('patched sources compile')"

# 2) Our code. Plugins land in the bundled plugin root (`/opt/hermes/plugins`,
#    scanned before $HERMES_HOME/plugins) so they load like any shipped plugin;
#    the sweep scripts live outside it and are symlinked into $HERMES_HOME by
#    cont-init below (the cron runner resolves script names there).
COPY plugins/ /opt/hermes/plugins/
COPY scripts/ /opt/hermes-local/scripts/
RUN chmod 0755 /opt/hermes-local/scripts/*.sh

# 3) Boot wiring: park a stale $HERMES_HOME/plugins copy so it cannot shadow the
#    image (later sources win), and point the sweep scripts at the image copies.
#    Idempotent, runs on every container start.
COPY cont-init/03-hermes-local /etc/cont-init.d/03-hermes-local
RUN chmod 0755 /etc/cont-init.d/03-hermes-local
