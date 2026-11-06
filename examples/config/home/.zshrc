# Oh My Zsh and its plugins come from the setup steps in ender-chest.toml.
if [[ -d ~/.oh-my-zsh ]]; then
  export ZSH=~/.oh-my-zsh
  plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
  fpath+=("$ZSH/custom/plugins/zsh-completions/src")
  source "$ZSH/oh-my-zsh.sh"
fi
# Optional Node version manager.
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd --shell zsh)"
fi
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
