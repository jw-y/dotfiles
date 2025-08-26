#!/bin/bash
set -e

TARGET=$HOME
#VIM_PATH=$HOME/.vim
NVIM_PATH=$HOME/.config
THEME_PATH=$HOME/.oh-my-zsh/themes

FileArray=( 
    #".vimrc"
    #".vimrc.coc"
    ".zshrc"
    ".tmux.conf"
    #".jwcolors.vim"
    ".pdbrc"
    ".ipdb"
) 

# link nvim config
if [ ! -L ~/.config/nvim ]; then
    ln -s ~/dotfiles/nvim ~/.config/nvim
    echo "Created nvim symlink"
else
    echo "nvim symlink already exists"
fi

for f in "${FileArray[@]}"
do
    echo "checking $f"
    rsync -aui $f $TARGET/
done

echo "checking jungwoo.zsh-theme"
rsync -aui jungwoo.zsh-theme $THEME_PATH/

#f=coc-settings.json
#if ! cmp $f $VIM_PATH/$f; then
#    echo "updating $f"
#    rsync -vu $f $VIM_PATH
#fi
