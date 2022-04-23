local hostname="%F{245}%m%f"
PROMPT=""

if [[ -n $SSH_CONNECTION ]]; then
    PROMPT+="${hostname} "
else
    PROMPT+=""
fi

PROMPT+='%F{63}%3~%f $(git_prompt_info)'
PROMPT+="%(?.%B%F{201}» .%F{yellow}» )%f%b"
RPROMPT='%F{245}%t %w%f'

ZSH_THEME_GIT_PROMPT_PREFIX="%F{39}|%f%F{9}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%F{39}|%f "
ZSH_THEME_GIT_PROMPT_DIRTY="%f%F{yellow}✗%f"
ZSH_THEME_GIT_PROMPT_CLEAN="%f"
