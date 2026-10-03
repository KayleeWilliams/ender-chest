# Optional Node version manager.
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd --shell zsh)"
fi
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
