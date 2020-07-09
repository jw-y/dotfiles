local hostname="%F{245}%m%f"
PROMPT=""

if [[ -n $SSH_CONNECTION ]]; then
    PROMPT+="${hostname} "
else
    PROMPT+=""
fi

PROMPT+='%{$fg[blue]%}%3~%{$reset_color%} $(git_prompt_info)'
PROMPT+="%(?.%B%F{magenta}» .%F{yellow}» )%f%b"
RPROMPT='%F{245}%t %w%f'

ZSH_THEME_GIT_PROMPT_PREFIX="%F{cyan}|%f%F{1}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%F{cyan}|%f "
ZSH_THEME_GIT_PROMPT_DIRTY="%f%F{yellow}✗%f"
ZSH_THEME_GIT_PROMPT_CLEAN="%f"
