" Set compatibility to Vim only
set nocompatible

call plug#begin('~/.vim/plugged')

Plug 'flazz/vim-colorschemes'
""Plug 'valloric/youcompleteme'
Plug 'dracula/vim', {'name':'dracula'}
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'tpope/vim-fugitive'
Plug 'preservim/nerdtree'
Plug 'sonph/onehalf', {'rtp': 'vim/'}
Plug 'rakr/vim-one'
Plug 'neoclide/coc.nvim', {'branch': 'release'}

call plug#end()

filetype plugin indent on    " required

" -----------------------------
"  Coc Configs
" -----------------------------
source ~/.vimrc.coc

" -----------------------------
"  Make Pretty
" -----------------------------
colorscheme onehalfdark
"let g:dracula_italic = 0
"colorscheme dracula

let g:airline_theme = 'fruit_punch'
let g:airline_powerline_fonts=1

map <C-n> :NERDTreeToggle<CR>

if (has("termguicolors"))
    set termguicolors
endif

" -----------------------------
"  Basic stuff
" -----------------------------
syntax on

set hidden
set autoindent
set smartindent
set showcmd " Show (partial) command in status line
set showmatch " Show matching brackest
set ignorecase " Do case insensitive matching
set hlsearch
set incsearch
set smartcase " Do smart case matching
set mouse=a " Enable mouse usage (all modes)
set spelllang=en_us
" set paste
set modelines=0 " Turn off modelines
set number " Show liine numbers
set title " Change title name
set ruler " Show file stats
set visualbell " Blink cursor on error instead of beeping (grr)
set cursorline

" inoremap " ""<left>
" inoremap ' ''<left>
" inoremap ( ()<left>
" inoremap [ []<left>
" inoremap { {}<left>
" inoremap {<CR> {<CR>}<ESC>O
" inoremap {;<CR> {<CR>};<ESC>O

nnoremap <CR> :noh<CR><CR>

set tabstop=4
set shiftwidth=4
set softtabstop=4
set smarttab
set expandtab

" Status bar
set laststatus=2
