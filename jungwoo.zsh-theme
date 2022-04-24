local hostname="%F{245}%m%f"

local RED="#e06c75"
local BLUE="#61afef"
local MAGENTA="#c678dd"
local CYAN="#56b6c2"
local YELLOW="#e5c07b"

PROMPT=""

if [[ -n $SSH_CONNECTION ]]; then
    PROMPT+="$hostname "
else
    PROMPT+=""
fi

PROMPT+='%F{$BLUE}%3~%f $(git_prompt_info)'
PROMPT+="%(?.%B%F{$MAGENTA}» .%F{$YELLOW}» )%f%b"
RPROMPT='%F{245}%t %w%f'

ZSH_THEME_GIT_PROMPT_PREFIX="%F{$CYAN}|%f%F{$RED}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%F{$CYAN}|%f "
ZSH_THEME_GIT_PROMPT_DIRTY="%f%F{$YELLOW}✗%f"
ZSH_THEME_GIT_PROMPT_CLEAN="%f"
