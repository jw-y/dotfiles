#!/bin/bash
set -e
#set -x

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
    echo "copying $f to $TARGET"
    cp $f $TARGET
done

echo "installing ohmyzsh..."
sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

echo "copying jungwoo zsh theme"
cp jungwoo.zsh-theme ~/.oh-my-zsh/themes/

echo "installing zsh-autosuggestions..."
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

echo "installing zsh-syntax-highlighting..."
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

echo "installing vim plugins..."
vim +'PlugInstall --sync' +qa

echo "installing coc-vim plugins..."
vim +'CocUpdateSync' +qa

echo "copying coc-settings..."
cp ./coc-settings.json ~/.vim/

echo "installing tmux plugins..."
~/.tmux/plugins/tpm/bin/install_plugins
