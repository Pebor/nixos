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
        bind | split-window -h -c "#{pane_current_path}"
        bind \\ split-window -v -c "#{pane_current_path}"
        bind c new-window -c "#{pane_current_path}"

        # --- floating panes (tmux >= 3.8) --------------------------------------
        # b = scratch shell over the current work, closed with prefix x
        bind b new-pane -c "#{pane_current_path}" -x 90% -y 85% -X 5% -Y 5%

        # --- copy mode (vi) ----------------------------------------------------
        bind -T copy-mode-vi v send -X begin-selection
        bind -T copy-mode-vi V send -X select-line
        bind -T copy-mode-vi y send -X copy-selection-and-cancel
        bind -T copy-mode-vi Y send -X copy-line

        # --- look: one flat bar, nothing per-pane ------------------------------
        setw -g pane-border-lines single
        setw -g pane-border-status bottom-floating
        setw -g pane-active-border-style "fg=colour8"
        set -g pane-scrollbars modal
        set -g renumber-windows on
        set -g set-titles on
        set -g set-titles-string "#S:#I:#W"

        # --- status line: flat, no clock, no hostname, accent = active --------
        # Colours are ANSI slots, so a stylix theme switch carries them along.
        set -g status-position bottom
        set -g status-justify left
        set -g status-interval 5
        set -g status-style "bg=default,fg=colour8"
        set -g status-left-length 40
        set -g status-left "#[fg=colour3,bold] #S #[fg=colour8]│#[default] "
        set -g status-right-length 20
        set -g status-right "#[fg=colour3]#{?client_prefix,^B ,}#[fg=colour8]#{?window_zoomed_flag,Z ,}#[default] "
        setw -g window-status-style "bg=default,fg=colour8"
        setw -g window-status-current-style "bg=default,fg=colour3,bold"
        setw -g window-status-format " #[fg=colour8]#I:#W "
        setw -g window-status-current-format " #[fg=colour3,bold]#I:#W "
        setw -g window-status-separator ""
        setw -g window-status-activity-style "fg=colour3"
        setw -g window-status-bell-style "fg=colour1,bold"

        # --- niceties ----------------------------------------------------------
        set -g detach-on-destroy off
        set -g display-time 2000
        bind r source-file ~/.config/tmux/tmux.conf \; display "tmux.conf reloaded"
      '';
    };
  };
}
