local RED="#f38ba8"
local BLUE="#74c7ec"
local MAGENTA="#cba6f7"
local CYAN="#94e2d5"
local YELLOW="#fab387"
local GRAY="#6c7086"

local hostname="%F{$GRAY}%m%f"

PROMPT=""

if [[ -n $SSH_CONNECTION ]]; then
    PROMPT+="$hostname "
fi

PROMPT+='%F{$BLUE}%3~%f '
PROMPT+='$(git_prompt_info)'
PROMPT+="%(?.%B%F{$MAGENTA}» .%F{$YELLOW}» )%f%b"
RPROMPT='%F{$GRAY}%t %D{%m/%d}%f'

ZSH_THEME_GIT_PROMPT_PREFIX="%F{$CYAN}(%f%F{$RED}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%F{$CYAN})%f "
ZSH_THEME_GIT_PROMPT_DIRTY="%f%F{$YELLOW}✗%f"
ZSH_THEME_GIT_PROMPT_CLEAN="%f"
