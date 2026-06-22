vim9script
# wend.vim — v2  Text-driven file navigator (Vim9script)
# Requires: Vim 9.0+ with +conceal (run :echo has('vim9script') && has('conceal'))
#
# Each line:  <10-char mode>  <absolute-path>[/]
#   e.g.  drwxr-xr-x /home/me/src/         (directory, trailing slash)
#         -rw-r--r-- /home/me/src/main.c  (file)
#
# The leading directory prefix of every path is visually concealed with an
# ellipsis, EXCEPT on the cursor line, which always shows the full path so you
# can read/edit it in any mode (this is Vim's native conceal; the buffer text
# itself is never rewritten, so x/r/dd/i/a all operate on the real path).
#
# Keys:
#   hjkl     normal cursor movement (built in)
#   <CR>     open the entry on the current line:
#              dir  -> navigate into it (re-renders this buffer)
#              file -> :edit it; missing path -> create file, or dir if it
#                      ends with '/'
#            works in normal mode, or after editing the path with i/a
#   :w       apply permission changes: any line whose 10-char mode column was
#            edited is chmod'd via setfperm()

const CCHAR    = '…'                                      # conceal replacement glyph
const MODE_RE  = '^[-dlpbcs][-rwxsStT]\{9}$'              # 10-char ls-style mode token
# Strict positional 9-char permission string (after stripping the type char).
# setfperm() treats '-' as off and ANY other char as on, so a loose compare
# would mis-report e.g. 'rxx' == 'rwx'. This regex only accepts meaningful
# characters in each slot (special bits s/S in exec slots, t/T in the last).
const PERM_RE  = '^[r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]$'

def Abspath(p: string): string
  var a = fnamemodify(p, ':p')
  if a !=# '/' && a =~ '/$'
    a = substitute(a, '/\+$', '', '')
  endif
  return a
enddef

def ModeOf(e: dict<any>): string
  var t = '-'
  if e.type ==# 'dir' || e.type ==# 'linkd'
    t = 'd'
  elseif e.type ==# 'link'
    t = 'l'
  elseif e.type ==# 'fifo'
    t = 'p'
  elseif e.type ==# 'socket'
    t = 's'
  elseif e.type ==# 'bdev'
    t = 'b'
  elseif e.type ==# 'cdev'
    t = 'c'
  endif
  return t .. e.perm                 # e.perm is a 9-char getfperm()-style string
enddef

def PathPart(text: string): string
  # Strip the leading mode column + whitespace; return the (absolute) path part.
  return matchstr(text, '^\S\+\s\+\zs.*$')
enddef

def ClearMatch()
  # matchadd() IDs are window-bound; drop ours so the conceal does not leak
  # into whatever buffer next occupies this window.
  if exists('b:wend_match_id') && b:wend_match_id > 0
    silent! matchdelete(b:wend_match_id)
    b:wend_match_id = 0
  endif
enddef

def ApplyConceal()
  ClearMatch()
  if !has('conceal')
    return                           # graceful fallback: full paths just show
  endif
  # conceallevel=2 + empty concealcursor: concealed text is hidden everywhere
  # but the cursor line, which is revealed in every mode for editing.
  setlocal conceallevel=2
  setlocal concealcursor=
  var prefix = b:wend_dir .. '/'
  # Very-nomagic literal match of the absolute dir prefix. It only occurs at
  # the start of each path (the mode column never contains '/'). matchadd()
  # conceal is independent of ':syntax', so it works even with 'syntax off'.
  var pat = '\V' .. escape(prefix, '\')
  b:wend_match_id = matchadd('Conceal', pat, 10, -1, {conceal: CCHAR})
enddef

def Render(dir: string)
  b:wend_dir = dir
  b:wend_snapshot = {}               # absolute-path -> 9-char perm (render-time snapshot)
  var lines: list<string> = []
  var entries: list<dict<any>>
  try
    entries = readdirex(dir)         # sorted by name, includes dotfiles
  catch
    entries = []
  endtry
  for e in entries
    var full = dir .. '/' .. e.name
    b:wend_snapshot[full] = e.perm
    var slash = (e.type ==# 'dir' || e.type ==# 'linkd') ? '/' : ''
    add(lines, ModeOf(e) .. ' ' .. full .. slash)
  endfor
  setlocal modifiable
  silent! :%delete _
  if empty(lines)
    setline(1, '[empty] ' .. dir)
  else
    setline(1, lines)
  endif
  setlocal nomodified
  ApplyConceal()
  normal! gg
enddef

def NavigateTo(dir: string): bool
  var d = Abspath(dir)
  if !isdirectory(d)
    return false
  endif
  silent! execute 'file' fnameescape('wend://' .. d)
  Render(d)
  return true
enddef

def ResolvePath(raw: string)
  var p = substitute(raw, '^\s*\|\s*$', '', 'g')
  if empty(p)
    return
  endif
  var wantDir = p =~ '/$'
  var ap = Abspath(p)
  if isdirectory(ap)
    NavigateTo(ap)
  elseif filereadable(ap)
    ClearMatch()
    execute 'edit' fnameescape(ap)
  else
    if wantDir
      mkdir(ap, 'p')
      NavigateTo(ap)
    else
      ClearMatch()
      execute 'edit' fnameescape(ap)   # non-existent file: open empty buffer to :w later
    endif
  endif
enddef

def CommitPath()
  var p = PathPart(getline('.'))
  stopinsert
  # Navigation deliberately abandons this listing buffer. Clearing 'modified'
  # avoids E37 ("no write since last change") when :edit switches to a file.
  setlocal nomodified
  ResolvePath(p)
enddef

def WriteCmd()
  var changed = 0
  var errs: list<string> = []
  for lnum in range(1, line('$'))
    var text = getline(lnum)
    var mode = matchstr(text, '^\S\+')
    if mode !~ MODE_RE
      continue
    endif
    var full = substitute(PathPart(text), '/$', '', '')
    if !has_key(b:wend_snapshot, full)
      continue                       # only known entries' mode column is a chmod channel
    endif
    var newperm = strpart(mode, 1)   # drop the type char -> 9 chars
    if newperm ==# b:wend_snapshot[full]
      continue                       # mode column untouched
    endif
    if newperm !~ PERM_RE
      add(errs, fnamemodify(full, ':t') .. ' (bad mode)')
      continue
    endif
    if !setfperm(full, newperm)
      add(errs, fnamemodify(full, ':t') .. ' (chmod failed)')
      continue
    endif
    # Re-read and compare: only count a change if the bits actually moved.
    # This kills the false positive where e.g. 'rxx' is identical to 'rwx'.
    if getfperm(full) !=# b:wend_snapshot[full]
      changed += 1
    endif
  endfor
  Render(b:wend_dir)                 # refresh from disk; also resets 'modified'
  if !empty(errs)
    echohl ErrorMsg | echom 'wend: chmod failed: ' .. join(errs, ', ') | echohl NONE
  else
    echom 'wend: applied ' .. changed .. ' permission change(s)'
  endif
enddef

def Open(arg: string)
  var dir = Abspath(empty(arg) ? getcwd() : arg)
  if !isdirectory(dir)
    echohl ErrorMsg | echom 'wend: not a directory: ' .. dir | echohl NONE
    return
  endif
  enew
  setlocal buftype=acwrite bufhidden=wipe noswapfile nolist wrap breakindent
  setlocal filetype=wend
  augroup wend_buf
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> WriteCmd()
    autocmd BufWinLeave <buffer> ClearMatch()
  augroup END
  nnoremap <buffer> <silent> <CR> <ScriptCmd>CommitPath()<CR>
  inoremap <buffer> <silent> <CR> <ScriptCmd>CommitPath()<CR>
  NavigateTo(dir)
enddef

command! -nargs=? -complete=dir Wend Open(<q-args>)
