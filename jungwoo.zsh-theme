PROMPT='%{$fg[cyan]%}%3~%{$reset_color%} $(git_prompt_info)'
PROMPT+="%(?.%B%F{magenta}» .%F{yellow}» )%f%b"
RPROMPT='%F{7}%w%t%f'

ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg_bold[blue]%}(%{$fg[red]%}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%} "
ZSH_THEME_GIT_PROMPT_DIRTY="%{$fg[blue]%}) %{$fg[yellow]%}✗"
ZSH_THEME_GIT_PROMPT_CLEAN="%{$fg[blue]%})"
