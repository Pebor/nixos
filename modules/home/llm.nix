# llm CLI with the ollama plugin.
# NOTE: only the withPlugins variant goes into home.packages — plain `llm`
# and `llm.withPlugins ...` both ship bin/llm and conflict in buildEnv.
{
  flake.modules.homeManager.llm = { pkgs, ... }: {
    home.packages = with pkgs; [
      (llm.withPlugins {
        llm-ollama = true;
      })
    ];
  };
}
