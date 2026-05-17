ROSEWATER="#f5e0dc"
FLAMINGO="#f2cdcd"
PINK="#f5c2e7"
MAUVE="#cba6f7"
RED="#f38ba8"
MAROON="#eba0ac"
PEACH="#fab387"
YELLOW="#f9e2af"
GREEN="#a6e3a1"
TEAL="#94e2d5"
SKY="#89dceb"
SAPPHIRE="#74c7ec"
BLUE="#89b4fa"
LAVENDER="#b4befe"
TEXT="#cdd6f4"
SUBTEXT1="#bac2de"
SUBTEXT0="#a6adc8"
OVERLAY2="#9399b2"
OVERLAY1="#7f849c"
OVERLAY0="#6c7086"

hostname_seg="%F{$OVERLAY0}%m%f"

function _git_info() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
  [[ -z "$branch" ]] && return

  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo " %F{$ROSEWATER}${branch}%f "
  else
    echo " %F{$TEXT}${branch}%f "
  fi
}

PROMPT=""
[[ -n $SSH_CONNECTION ]] && PROMPT+="$hostname_seg "
PROMPT+="%F{$SAPPHIRE}%3~%f"
PROMPT+='$(_git_info)'
PROMPT+="%(?.%B%F{$MAUVE}❯ .%F{$PEACH}❯ )%f%b"

RPROMPT="%F{$OVERLAY0}%T %D{%m/%d}%f"
