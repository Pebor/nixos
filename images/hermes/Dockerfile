# Derived Hermes image: the upstream image plus our source patches baked in.
#
# Why: patches applied at runtime under /opt/hermes are duct tape — an image pull or a
# container re-create silently drops them. Baking them into a tagged image makes the code
# state reproducible and reviewable (the patch scripts are in this directory, git-tracked).
#
# Build (host):
#   docker build --pull -t hermes-agent:patched /home/server/nixos/images/hermes
# Then the oci-container uses image = "hermes-agent:patched" (pull policy is "missing",
# so a locally built tag is never overwritten by a registry pull).
FROM nousresearch/hermes-agent:latest

COPY patches/ /opt/hermes-patches/

# The patch scripts are idempotent and refuse to write on an anchor mismatch, so an upstream
# rewrite of a patched function breaks the BUILD here instead of shipping half-patched code.
RUN /opt/hermes/.venv/bin/python /opt/hermes-patches/patch_topic_names.py \
 && /opt/hermes/.venv/bin/python -c "import py_compile; py_compile.compile('/opt/hermes/gateway/run_topics.py', doraise=True); print('patched run_topics.py compiles')"
