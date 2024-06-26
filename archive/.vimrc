" Set compatibility to Vim only
set nocompatible

call plug#begin('~/.vim/plugged')

Plug 'flazz/vim-colorschemes'
"Plug 'valloric/youcompleteme'
Plug 'dracula/vim', {'name':'dracula'}
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'tpope/vim-fugitive'
Plug 'preservim/nerdtree'
"Plug 'ryanoasis/vim-devicons'
Plug 'sonph/onehalf', {'rtp': 'vim/'}
Plug 'rakr/vim-one'
Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'airblade/vim-gitgutter'
Plug 'junegunn/goyo.vim'
Plug 'iamcco/markdown-preview.nvim', {'do': 'cd app && yarn install'}
Plug 'vim-python/python-syntax'
Plug 'ojroques/vim-oscyank', {'branch': 'main'}
" Plug 'psf/black', {'branch': 'stable'}
" Plug 'prabirshrestha/vim-lsp'
" Plug 'mattn/vim-lsp-settings'

call plug#end()

filetype plugin indent on    " required

" -----------------------------
"  Coc Configs
" -----------------------------
let g:coc_global_extensions = [
    \ 'coc-clangd',
    \ 'coc-pairs',
    \ 'coc-highlight',
    \ 'coc-cmake',
    \ 'coc-pyright',
    \ 'coc-tsserver',
    \ 'coc-json',
    \ 'coc-html',
    \ 'coc-prettier',
    \ ]
"   \ 'coc-markdownlint',
"   \ 'coc-pyright',
"   \ 'coc-python',

source ~/.vimrc.coc

autocmd FileType c,cpp,python,javascript let b:coc_pairs_disabled = ['<']

" -----------------------------
"  Make Pretty
" -----------------------------
colorscheme onehalfdark
"let g:dracula_italic = 0
"colorscheme dracula

let g:airline_theme = 'fruit_punch'
let g:airline_powerline_fonts=1

"let NERDTreeWinSize=50
"autocmd FileType nerdtree set norelativenumber
" autocmd BufEnter NERD_* setlocal norelativenumber
let g:NERDTreeShowLineNumbers=0
map <C-n> :NERDTreeToggle<CR>
" Exit Vim if NERDTree is the only window remaining in the only tab.
autocmd BufEnter * if tabpagenr('$') == 1 && winnr('$') == 1 && exists('b:NERDTree') && b:NERDTree.isTabTree() | quit | endif

" python-syntax
let g:python_highlight_all = 1

"let g:gitgutter_sign_added = 'xx'
"let g:gitgutter_sign_modified = 'yy'
"let g:gitgutter_sign_removed = 'zz'
"let g:gitgutter_sign_removed_first_line = '^'
"let g:gitgutter_sign_removed_above_and_below = '='
"let g:gitgutter_sign_modified_removed = 'M'
command! -nargs=0 Prettier :CocCommand prettier.forceFormatDocument

" -----------------------------
"  Basic stuff
" -----------------------------

"let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
"let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
"if(has("termguicolors"))
"    set termguicolors
"endif
if !has('gui_running') && &term =~ '^\%(screen\|tmux\)'
    let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
    let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
endif

syntax on
set termguicolors

" change highlighting
source ~/.jwcolors.vim

" Cursor Shape
let &t_SI .= "\<Esc>[5 q"
let &t_EI .= "\<Esc>[1 q"

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
set pastetoggle=<F2>
set modelines=0 " Turn off modelines
set number " Show line numbers
set title " Change title name
set ruler " Show file stats
set visualbell " Blink cursor on error instead of beeping (grr)
set cursorline
set scrolloff=2
set autoread
set foldmethod=syntax
set foldnestmax=1
set backspace=indent,eol,start
set signcolumn=auto
set updatetime=250
set encoding=UTF-8

set number relativenumber

augroup numbertoggle
  autocmd!
  autocmd BufEnter,FocusGained,InsertLeave,WinEnter * set relativenumber
  autocmd BufLeave,FocusLost,InsertEnter,WinLeave   * set norelativenumber
augroup END

":augroup numbertoggle
":  autocmd!
":  autocmd BufEnter,FocusGained,InsertLeave,WinEnter * if &nu && mode() != "i" | set rnu   | endif
":  autocmd BufLeave,FocusLost,InsertEnter,WinLeave   * if &nu                  | set nornu | endif
":augroup END

" no relativenumber for nerdtree
autocmd FileType nerdtree set norelativenumber
autocmd BufEnter NERD_* setlocal norelativenumber

" inoremap " ""<left>
" inoremap ' ''<left>
" inoremap ( ()<left>
" inoremap [ []<left>
" inoremap { {}<left>
" inoremap {<CR> {<CR>}<ESC>O
" inoremap {;<CR> {<CR>};<ESC>O
nnoremap <CR> :noh<CR><CR>
nnoremap <space> za

set tabstop=4
set shiftwidth=4
set softtabstop=4
set smarttab
set expandtab
autocmd Filetype cpp setlocal expandtab tabstop=2 shiftwidth=2 softtabstop=2

" set clipboard=unnamed,unnamedplus
set timeoutlen=1000 ttimeoutlen=5

" osc yank
nmap <leader>c <Plug>OSCYankOperator
nmap <leader>cc <leader>c_
vmap <leader>c <Plug>OSCYankVisual
autocmd TextYankPost *
    \ if v:event.operator is 'y' && v:event.regname is '+' |
    \ execute 'OSCYankRegister +' |
    \ endif
set clipboard& clipboard^=unnamed,unnamedplus

" Status bar
set laststatus=2

set wildmenu

" Return to last edit position when opening files (You want this!)
autocmd BufReadPost *
     \ if line("'\"") > 0 && line("'\"") <= line("$") |
     \   exe "normal! g`\"" |
     \ endif

" WSL yank support
" let s:clip = "/mnt/c/Windows/System32/clip.exe"
" if executable(s:clip)
"    augroup WSLYank
"         autocmd!
"         autocmd TextYankPost * if v:event.operator ==# 'y' | call system(s:clip, @0) | endif
"     augroup END
" endif
