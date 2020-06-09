PROMPT='%{$fg[cyan]%}%3~%{$reset_color%} $(git_prompt_info)'
PROMPT+="%(?.%B%F{magenta}» .%F{yellow}» )%f%b"
RPROMPT='%F{5}%w %t%f'

ZSH_THEME_GIT_PROMPT_PREFIX="%F{blue}(%f%F{1}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%F{blue})%f "
ZSH_THEME_GIT_PROMPT_DIRTY="%f%F{yello}✗%f"
ZSH_THEME_GIT_PROMPT_CLEAN="%f"
