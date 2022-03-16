#!/bin/bash
set -e

TARGET=$HOME
VIM_PATH=$HOME/.vim/
THEME_PATH=$HOME/.oh-my-zsh/themes/

FileArray=( 
    ".vimrc"
    ".vimrc.coc"
    ".zshrc"
    ".tmux.conf"
    "jwcolors.vim"
    ".pdbrc"
    ".ipdb"
) 

for f in "${FileArray[@]}"
do
    if ! cmp $f $TARGET/$f ; then
        echo "updating $f"
        cp -u $f $TARGET
    fi
done

f=jungwoo.zsh-theme
if ! cmp $f $THEME_PATH/$f; then
    echo "updating $f"
    cp -u $f $TARGET
fi

f=coc-settings.json
if ! cmp $f $VIM_PATH/$f; then
    echo "updating $f"
    cp -u $f $TARGET
fi
