set -gx PNPM_HOME "$HOME/.local/share/pnpm"
if not contains "$PNPM_HOME/bin" $PATH
    set -gx PATH "$PNPM_HOME/bin" $PATH
end
