# tmux with modern defaults. Prefix stays C-b so the stock bindings keep
# working; everything else is what you would otherwise paste in by hand:
#   - vi copy-mode, 50k history, mouse, focus events, 1-based indices
#   - one status bar, pane labels only on floating panes
#   - prefix b = floating scratch pane; prefix Tab = stock bottom drawer
# Floating-pane move/resize are built in: prefix g <corner/edge> (Meta
# resizes too), prefix g , = Move menu, prefix g . = Move & Resize menu.
{
  flake.modules.homeManager.tmux = { ... }: {
    programs.tmux = {
      enable = true;

      # Keep the stock prefix.
      shortcut = "b";

      keyMode = "vi";
      baseIndex = 1;
      historyLimit = 50000;
      escapeTime = 10;
      focusEvents = true;
      aggressiveResize = true;
      clock24 = true;
      mouse = true;
      terminal = "tmux-256color";

      extraConfig = ''
        # --- panes / windows ---------------------------------------------------
        # Stock % and " splits are kept as-is (cz-coder has both unshifted).
        # New windows inherit the current pane's directory.
        bind c new-window -c "#{pane_current_path}"

        # --- floating panes (tmux >= 3.8) --------------------------------------
        # b = scratch shell over the current work, closed with prefix x
        bind b new-pane -c "#{pane_current_path}" -x 90% -y 85% -X 5% -Y 5%

        # --- copy mode (vi) ----------------------------------------------------
        bind -T copy-mode-vi v send -X begin-selection
        bind -T copy-mode-vi V send -X select-line
        bind -T copy-mode-vi y send -X copy-selection-and-cancel
        bind -T copy-mode-vi Y send -X copy-line

        # --- look: one bar, nothing per-pane -----------------------------------
        setw -g pane-border-lines single
        setw -g pane-border-status bottom-floating
        set -g pane-scrollbars modal
        set -g status-position bottom
        set -g status-justify left
        set -g renumber-windows on
        set -g set-titles on
        set -g set-titles-string "#S:#I:#W"

        # --- niceties ----------------------------------------------------------
        set -g detach-on-destroy off
        set -g display-time 2000
        bind r source-file ~/.config/tmux/tmux.conf \; display "tmux.conf reloaded"
      '';
    };
  };
}
