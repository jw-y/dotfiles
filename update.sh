#!/bin/bash
set -e

TARGET=$HOME

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
    if [ $(diff $f "$TARGET/$f") != "" ]; then
        echo "updating $f"
        cp -u $f $TARGET
    fi
done
