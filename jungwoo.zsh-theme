RED="#f38ba8"
BLUE="#74c7ec"
MAGENTA="#cba6f7"
CYAN="#94e2d5"
YELLOW="#fab387"
GRAY="#6c7086"

hostname_seg="%F{$GRAY}%m%f"

PROMPT=""
[[ -n $SSH_CONNECTION ]] && PROMPT+="$hostname_seg "
PROMPT+="%F{$BLUE}%3~%f "
PROMPT+='$(git_prompt_info)'
PROMPT+="%(?.%B%F{$MAGENTA}» .%F{$YELLOW}» )%f%b"

RPROMPT="%F{$GRAY}%T %D{%m/%d}%f"

ZSH_THEME_GIT_PROMPT_PREFIX="%F{$CYAN}(%F{$RED}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%F{$CYAN})%f "
ZSH_THEME_GIT_PROMPT_DIRTY="%F{$YELLOW}✗%f"
ZSH_THEME_GIT_PROMPT_CLEAN=""
