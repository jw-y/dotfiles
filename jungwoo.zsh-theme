# Catppuccin Mocha
ROSEWATER="#f5e0dc" FLAMINGO="#f2cdcd" PINK="#f5c2e7" MAUVE="#cba6f7"
RED="#f38ba8" MAROON="#eba0ac" PEACH="#fab387" YELLOW="#f9e2af"
GREEN="#a6e3a1" TEAL="#94e2d5" SKY="#89dceb" SAPPHIRE="#74c7ec"
BLUE="#89b4fa" LAVENDER="#b4befe"
TEXT="#cdd6f4" SUBTEXT1="#bac2de" SUBTEXT0="#a6adc8"
OVERLAY2="#9399b2" OVERLAY1="#7f849c" OVERLAY0="#6c7086"

function _git_info() {
  local branch ahead dirty marker
  if branch=$(git symbolic-ref --short HEAD 2>/dev/null); then
    ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null)
  elif branch=$(git rev-parse --short HEAD 2>/dev/null); then
    branch="@${branch}"  # mark detached
  else
    return
  fi

  git diff --no-ext-diff --quiet 2>/dev/null || dirty="*"
  git diff --no-ext-diff --cached --quiet 2>/dev/null || dirty="${dirty}+"

  if [[ -n "$ahead" && "$ahead" -gt 0 ]]; then
    marker="%F{$FLAMINGO}${branch}${dirty} ↑${ahead}%f"
  elif [[ -n "$dirty" ]]; then
    marker="%F{$ROSEWATER}${branch}${dirty}%f"
  else
    marker="%F{$SUBTEXT0}${branch}%f"
  fi
  echo " $marker"
}

function _env_info() {
  [[ -z "$VIRTUAL_ENV_PROMPT" ]] && return
  echo "%F{$SUBTEXT1}[${VIRTUAL_ENV_PROMPT% }]%f "
}

PROMPT=""
PROMPT+='$(_env_info)'
[[ -n $SSH_CONNECTION ]] && PROMPT+="%F{$OVERLAY0}%m%f "
PROMPT+="%F{$LAVENDER}%3~%f"
PROMPT+='$(_git_info)'
PROMPT+=" %(?.%B%F{$MAUVE}❯%f%b.%F{$PEACH}❯%f) "

RPROMPT="%F{$OVERLAY0}%T %D{%m/%d}%f"
