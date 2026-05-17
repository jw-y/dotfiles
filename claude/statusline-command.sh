#!/usr/bin/env bash
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

if ! command -v jq >/dev/null 2>&1; then
  echo "statusline: jq not found"
  exit 1
fi

input=$(cat)

cwd=$(echo "$input"      | jq -r '.workspace.current_dir // .cwd')
model=$(echo "$input"    | jq -r '.model.display_name')
used=$(echo "$input"     | jq -r '.context_window.used_percentage // empty')
cost=$(echo "$input"     | jq -r '.cost.total_cost_usd // empty')
effort=$(echo "$input"   | jq -r '.effort.level // empty')
thinking=$(echo "$input" | jq -r '.thinking.enabled // false')

# Catppuccin Mocha
SAPPHIRE="\033[38;2;116;199;236m"
MAUVE="\033[38;2;203;166;247m"
PEACH="\033[38;2;250;179;135m"
TEAL="\033[38;2;148;226;213m"
SUBTEXT0="\033[38;2;166;173;200m"
OVERLAY0="\033[38;2;108;112;134m"
RESET="\033[0m"

# Git branch — match zsh theme style (no parens, color by dirty state)
git_part=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  if ! git -C "$cwd" diff --quiet 2>/dev/null || ! git -C "$cwd" diff --cached --quiet 2>/dev/null; then
    git_part=$(printf "\033[38;2;242;205;205m${branch}${RESET} ")
  else
    git_part=$(printf "${SUBTEXT0}${branch}${RESET} ")
  fi
fi

# Model in Sapphire, thinking/effort in Mauve
mode_suffix=""
if [ "$thinking" = "true" ] && [ -n "$effort" ]; then
  mode_suffix=$(printf " ${MAUVE}✦ ${effort}${RESET}")
elif [ "$thinking" = "true" ]; then
  mode_suffix=$(printf " ${MAUVE}✦${RESET}")
elif [ -n "$effort" ]; then
  mode_suffix=$(printf " ${MAUVE}${effort}${RESET}")
fi

model_part=$(printf "${SAPPHIRE}${model}${RESET}${mode_suffix}")

# Context progress bar
ctx_part=""
if [ -n "$used" ]; then
  pct=$(printf '%.0f' "$used")
  filled=$(( pct * 10 / 100 ))
  empty=$(( 10 - filled ))
  bar=""
  [ "$filled" -gt 0 ] && printf -v f "%${filled}s" && bar="${f// /■}"
  [ "$empty" -gt 0 ] && printf -v e "%${empty}s" && bar="${bar}${e// /□}"
  if [ "$pct" -ge 90 ]; then
    bar_color="\033[38;2;243;139;168m"  # Red
  elif [ "$pct" -ge 70 ]; then
    bar_color="\033[38;2;250;179;135m"  # Peach
  else
    bar_color="\033[38;2;148;226;213m"  # Teal
  fi
  ctx_part=$(printf " ${OVERLAY0}[${bar_color}${bar} ${pct}%%${OVERLAY0}]${RESET}")
fi

# Cost green
cost_part=""
if [ -n "$cost" ]; then
  cost_part=$(printf " \033[38;2;166;227;161m\$$(printf '%.2f' "$cost")${RESET}")
fi

printf "%s%s%s%s\n" \
  "$git_part" \
  "$model_part" \
  "$ctx_part" \
  "$cost_part"
