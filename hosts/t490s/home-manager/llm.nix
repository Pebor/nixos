
{ pkgs, ... } : {
  home.packages = with pkgs; [
    llm
    llm.withPlugins {
      llm-ollama = true;
    }
  ];

}
