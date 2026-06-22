vim9script
# wend.vim — Text-driven file navigator (Vim9script)
# Version: 0.3.1 (unreleased; major version stays 0 until the first tagged release)
# Requires: Vim 9.0+
#
# Each line is a real `ls -la` row (run with LC_ALL=C and --time-style=long-iso
# so parsing is deterministic), e.g.:
#   drwxr-xr-x 2 me grp 4096 2026-06-22 09:11 src
#   -rw-r--r-- 1 me grp  812 2026-06-22 09:11 main.c
#
# Display: the name column shows the bare name, exactly like `ls -la`. When the
# cursor lands on a row (in ANY mode, including Normal), that row's name is
# expanded in-place to the full absolute path, so Normal-mode edits (x, r, dd,
# etc.) and Insert-mode edits all operate on the real path. Leaving the row
# collapses it back to the bare name. No conceal, no highlighting is used.
#
# Editing channels (everything else is silently discarded on :w):
#   - Permissions: edit the 10-char mode column, then :w -> setfperm() chmod.
#   - Path: edit the name on the current (expanded) row, then <CR> -> open it.
#
# Keys:
#   <CR>  open the entry on the current row:
#           dir  -> navigate into it (re-renders this buffer)
#           file -> :edit it; missing path -> create file, or dir if it ends '/'
#         works in Normal mode, or after editing the path with i/a.
#   :w    apply permission changes (mode column) via setfperm().

const MODE_RE = '^[-dlpbcs][-rwxsStT]\{9}[.+]\?$'           # 10-char ls mode token + optional ACL/SELinux indicator ('.' or '+')
# Strict positional 9-char permission string (after stripping the type char).
# setfperm() treats '-' as off and ANY other char as on, so a loose compare
# would mis-report e.g. 'rxx' == 'rwx'. This regex only accepts meaningful
# characters in each slot (special bits s/S in exec slots, t/T in the last).
const PERM_RE = '^[r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]$'

def NinePerm(token: string): string
  # Extract the 9 permission chars from an ls mode token, dropping the leading
  # type char AND any trailing ACL/SELinux indicator ('.' or '+'). On Fedora and
  # other SELinux systems `ls -la` prints e.g. 'drwxr-xr-x.', so a naive
  # strpart(token, 1) would keep the dot and break every chmod compare.
  return strpart(matchstr(token, '^[-dlpbcs][-rwxsStT]\{9}'), 1)
enddef

def Abspath(p: string): string
  var a = fnamemodify(p, ':p')
  if a !=# '/' && a =~ '/$'
    a = substitute(a, '/\+$', '', '')
  endif
  return a
enddef

def Render(dir: string)
  b:wend_dir = dir
  b:wend_entries = {}          # lnum -> {full: <abs path>, tail: <displayed name field>}
  b:wend_perm = {}             # abs path -> 9-char perm snapshot (for chmod diffing)
  b:wend_name_col = 0          # byte column where the name field begins (fixed per render)
  b:wend_cur = 0               # currently expanded line (0 = none)
  var raw: list<string>
  try
    # LC_ALL=C + long-iso => ASCII, fixed-width, deterministic columns:
    #   <mode> <links> <owner> <group> <size> <YYYY-MM-DD> <HH:MM> <name>
    raw = systemlist('LC_ALL=C ls -la --time-style=long-iso -- ' .. shellescape(dir))
  catch
    raw = []
  endtry
  # Find the name column from the first real entry: 7 whitespace-separated
  # fields precede the name. ls aligns columns, so this offset is identical for
  # every row in this listing.
  for ln in raw
    if matchstr(ln, '^\S\+') =~ MODE_RE
      var pfx = matchstr(ln, '^\%(\S\+\s\+\)\{7}')
      if !empty(pfx)
        b:wend_name_col = strlen(pfx)
        break
      endif
    endif
  endfor
  setlocal modifiable
  silent! :%delete _
  if empty(raw)
    setline(1, '[empty] ' .. dir)
  else
    setline(1, raw)
  endif
  if b:wend_name_col > 0
    var n = line('$')
    var i = 1
    while i <= n
      var ln = getline(i)
      var perms = matchstr(ln, '^\S\+')
      if perms =~ MODE_RE && strlen(ln) >= b:wend_name_col
        var tail = strpart(ln, b:wend_name_col)
        var name = substitute(tail, ' -> .*$', '', '')   # drop symlink target for the path
        if !empty(name)
          var full = simplify(dir .. '/' .. name)          # handles '.' and '..'
          b:wend_entries[i] = {full: full, tail: tail}
          b:wend_perm[full] = NinePerm(perms)
        endif
      endif
      i += 1
    endwhile
  endif
  setlocal nomodified
enddef

def ExpandLine(lnum: number)
  var e = b:wend_entries[lnum]
  setline(lnum, strpart(getline(lnum), 0, b:wend_name_col) .. e.full)
enddef

def CollapseLine(lnum: number)
  var e = b:wend_entries[lnum]
  setline(lnum, strpart(getline(lnum), 0, b:wend_name_col) .. e.tail)
enddef

def UpdateCursor()
  # Expand the name on the row the cursor just entered; collapse the one it left.
  # Acts only on line-number changes, so editing in place (x/r) is never disturbed
  # and we avoid re-entrancy (autocmds are non-nested by default).
  if b:wend_name_col <= 0
    return
  endif
  var l = line('.')
  if l == b:wend_cur
    return
  endif
  var m = mode()
  if m ==# 'v' || m ==# 'V' || m ==# "\<C-v>"
    return                     # don't rewrite text under an active Visual selection
  endif
  var wasmod = &l:modified
  if b:wend_cur > 0 && b:wend_cur <= line('$') && has_key(b:wend_entries, b:wend_cur)
    CollapseLine(b:wend_cur)
  endif
  if has_key(b:wend_entries, l)
    ExpandLine(l)
  endif
  b:wend_cur = l
  if !wasmod
    setlocal nomodified         # keep mere browsing from marking the buffer modified
  endif
enddef

def FirstEntryLine(): number
  for i in range(1, line('$'))
    if has_key(b:wend_entries, i)
      return i
    endif
  endfor
  return 1
enddef

def NavigateTo(dir: string): bool
  var d = Abspath(dir)
  if !isdirectory(d)
    return false
  endif
  silent! execute 'file' fnameescape('wend://' .. d)
  Render(d)
  cursor(FirstEntryLine(), 1)
  UpdateCursor()
  return true
enddef

def ResolvePath(raw: string)
  var p = substitute(raw, '^\s*\|\s*$', '', 'g')
  if empty(p)
    return
  endif
  if p[0] !=# '/'
    p = b:wend_dir .. '/' .. p        # resolve relative to the listed directory
  endif
  var wantDir = p =~ '/$'
  var ap = Abspath(p)
  if isdirectory(ap)
    NavigateTo(ap)
  elseif filereadable(ap)
    execute 'edit' fnameescape(ap)
  else
    if wantDir
      mkdir(ap, 'p')
      NavigateTo(ap)
    else
      execute 'edit' fnameescape(ap)   # non-existent file: open empty buffer to :w later
    endif
  endif
enddef

def CommitPath()
  var lnum = line('.')
  if !has_key(b:wend_entries, lnum)
    return                              # header / non-entry row: nothing to open
  endif
  # The current row is expanded, so its name field is the full (possibly edited) path.
  var p = substitute(strpart(getline(lnum), b:wend_name_col), ' -> .*$', '', '')
  stopinsert
  # Navigation deliberately abandons this listing buffer; clearing 'modified'
  # avoids E37 ("no write since last change") when :edit switches to a file.
  setlocal nomodified
  ResolvePath(p)
enddef

def WriteCmd()
  var changed = 0
  var errs: list<string> = []
  for lnum in range(1, line('$'))
    if !has_key(b:wend_entries, lnum)
      continue
    endif
    var perms = matchstr(getline(lnum), '^\S\+')
    if perms !~ MODE_RE
      continue
    endif
    var full = b:wend_entries[lnum].full
    if !has_key(b:wend_perm, full)
      continue
    endif
    var newperm = NinePerm(perms)       # 9 perm chars (type char + ACL suffix stripped)
    if newperm ==# b:wend_perm[full]
      continue                          # mode column untouched
    endif
    if newperm !~ PERM_RE
      add(errs, fnamemodify(full, ':t') .. ' (bad mode)')
      continue
    endif
    if !setfperm(full, newperm)
      add(errs, fnamemodify(full, ':t') .. ' (chmod failed)')
      continue
    endif
    # Re-read and compare: only count a change if the bits actually moved. This
    # kills the false positive where e.g. 'rxx' is identical to 'rwx'.
    if getfperm(full) !=# b:wend_perm[full]
      changed += 1
    endif
  endfor
  var ln = line('.')
  Render(b:wend_dir)                    # refresh from disk; also resets 'modified'
  cursor(min([ln, line('$')]), 1)
  UpdateCursor()
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
  b:wend_cur = 0
  b:wend_name_col = 0
  b:wend_entries = {}
  b:wend_perm = {}
  augroup wend_buf
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> WriteCmd()
    autocmd CursorMoved <buffer> UpdateCursor()
    autocmd CursorMovedI <buffer> UpdateCursor()
  augroup END
  nnoremap <buffer> <silent> <CR> <ScriptCmd>CommitPath()<CR>
  inoremap <buffer> <silent> <CR> <ScriptCmd>CommitPath()<CR>
  NavigateTo(dir)
enddef

command! -nargs=? -complete=dir Wend Open(<q-args>)
