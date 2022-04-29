#!/bin/bash
set -e
#set -x

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
    echo "copying $f to $TARGET"
    cp $f $TARGET
done

echo "installing vim-plug..."
curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

echo "installing vim plugins..."
vim +'PlugInstall --sync' +qa

echo "installing coc-vim plugins..."
vim +'CocUpdateSync' +qa

echo "copying coc-settings..."
cp ./coc-settings.json $VIM_PATH

echo "installing tmux-plugin-manager..."
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

echo "installing tmux plugins..."
~/.tmux/plugins/tpm/bin/install_plugins

echo "installing ohmyzsh..."
sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" &
wait $!

echo "copying jungwoo zsh theme"
cp jungwoo.zsh-theme $THEME_PATH

echo "installing zsh-autosuggestions..."
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

echo "installing zsh-syntax-highlighting..."
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

