vim9script
# wend.vim — Text-driven file navigator (Vim9script)
# Version: 0.4.2 (unreleased; the major version stays 0 until the first tagged release)
# Requires: Vim 9.0+
#
# Philosophy: "write is all you need". The buffer IS a live `ls -lai` listing
# whose rows you edit. WHICH channel you use to commit decides the meaning of
# an edit, so a single buffer never has to juggle two conflicting intents:
#
#   <CR>  = NAVIGATION (immediate; never mutates anything). This is the core
#           feature: before you ever :w, pressing <CR> on a row — in Normal
#           OR Insert mode, whether or not you edited its name — navigates:
#             existing dir   -> enter it (re-renders this buffer)
#             existing file  -> :edit it
#             missing path   -> create it (a file, or a dir if it ends with '/')
#                               and open it
#           So editing a name and hitting <CR> is just "go there / create it".
#
#   :w    = COMMIT structural / attribute changes against the listing. Rows are
#           matched by inode (the first `ls -lai` column), so a change is tied
#           to the real on-disk entry rather than to fragile line text:
#             - delete : remove a row (e.g. dd) -> delete that file/dir
#             - rename : edit a name in place, go back to Normal WITHOUT <CR>,
#                        then :w -> rename() inside the SAME directory (file
#                        content is preserved). Because arriving on a row re-
#                        expands it (discarding edits on the row you left),
#                        only the row under the cursor can be renamed per :w.
#             - chmod  : edit the 10-char mode column -> setfperm().
#
# Atomic writes: if ANY edit in the buffer is unsupported, :w commits NOTHING
# and leaves the buffer untouched so you can fix it (no "which parts saved?"
# confusion). Unsupported edits: a '/' inside a new name (moving across
# directories), changing an entry's type (e.g. adding a trailing '/' to a
# file), renaming '.'/'..', or a rename whose target already exists. True
# moves are out of scope — use :!mv.
#
# Confirmation: any delete or rename is confirmed once before being applied;
# deleting '.' (current dir) or '..' (parent dir) is called out explicitly.
# Answering No re-renders the listing (the buffer is refreshed back to disk
# reality, so a cancelled delete no longer looks deleted).
#
# Display: each row shows the bare name, exactly like `ls -lai` (no conceal, no
# highlighting). When the cursor lands on a row (in ANY mode) its name expands
# in place to the full absolute path so edits act on the real path; leaving the
# row collapses it back to the bare name.
#
# State is keyed by inode (see b:wend_byinode), never by line number, so it
# survives line edits such as dd / o without going stale.

# 10-char ls mode token, plus an optional trailing ACL/SELinux indicator
# ('.' or '+') as emitted by e.g. Fedora.
const MODE_RE = '^[-dlpbcs][-rwxsStT]\{9}[.+]\?$'
# Strict positional 9-char permission string (after the type char is removed).
# setfperm() treats '-' as off and ANY other char as on, so a loose compare
# would mis-report e.g. 'rxx' == 'rwx'. This only accepts meaningful chars per
# slot (special bits s/S in the exec slots, t/T in the last).
const PERM_RE = '^[r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]$'

def NinePerm(token: string): string
  # The 9 permission chars from an ls mode token: drop the leading type char
  # AND any trailing ACL/SELinux indicator ('.' or '+').
  return strpart(matchstr(token, '^[-dlpbcs][-rwxsStT]\{9}'), 1)
enddef

def InodeOf(ln: string): string
  # Column 1 of `ls -lai` is the inode number (right-aligned, space-padded).
  # It is the stable identity of a row across edits.
  return matchstr(ln, '^\s*\zs\d\+')
enddef

def ModeOf(ln: string): string
  # Column 2 of `ls -lai` is the mode token.
  return matchstr(ln, '^\s*\S\+\s\+\zs\S\+')
enddef

def Abspath(p: string): string
  var a = fnamemodify(p, ':p')
  if a !=# '/' && a =~ '/$'
    a = substitute(a, '/\+$', '', '')
  endif
  return a
enddef

def EntryAt(lnum: number): dict<any>
  # The entry for a buffer line, resolved by the line's OWN inode (column 1),
  # so it stays correct even after lines were deleted/inserted above it.
  if lnum < 1 || lnum > line('$')
    return {}
  endif
  var ln = getline(lnum)
  if ModeOf(ln) !~ MODE_RE
    return {}
  endif
  return get(b:wend_byinode, InodeOf(ln), {})
enddef

def Render(dir: string)
  b:wend_dir = dir
  b:wend_byinode = {}        # inode -> {full, tail, name, type, perm}
  b:wend_name_col = 0        # byte column where the name field starts (fixed per render)
  b:wend_cur = 0             # line currently expanded (0 = none)
  b:wend_cur_inode = ''      # inode of the expanded line (guards against stale line numbers)
  var raw: list<string>
  try
    # LC_ALL=C + long-iso => ASCII, deterministic, fixed-width columns:
    #   <inode> <mode> <links> <owner> <group> <size> <YYYY-MM-DD> <HH:MM> <name>
    raw = systemlist('LC_ALL=C ls -lai --time-style=long-iso -- ' .. shellescape(dir))
  catch
    raw = []
  endtry
  # Name column = byte offset after the 8 whitespace-separated fields (inode +
  # 7) that precede the name. ls aligns columns, so this offset is identical
  # for every row of the listing; take it from the first real entry.
  for ln in raw
    if ModeOf(ln) =~ MODE_RE
      var pfx = matchstr(ln, '^\s*\%(\S\+\s\+\)\{8}')
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
      var modetok = ModeOf(ln)
      if modetok =~ MODE_RE && strlen(ln) >= b:wend_name_col
        var tail = strpart(ln, b:wend_name_col)
        var name = substitute(tail, ' -> .*$', '', '')   # strip symlink target for the path
        var inode = InodeOf(ln)
        if !empty(name) && !empty(inode)
          b:wend_byinode[inode] = {
            full: simplify(dir .. '/' .. name),             # also normalises '.' and '..'
            tail: tail,
            name: name,
            type: strpart(modetok, 0, 1),
            perm: NinePerm(modetok),
          }
        endif
      endif
      i += 1
    endwhile
  endif
  setlocal nomodified
enddef

def ExpandLine(lnum: number)
  var e = EntryAt(lnum)
  if empty(e)
    return
  endif
  setline(lnum, strpart(getline(lnum), 0, b:wend_name_col) .. e.full)
enddef

def CollapseLine(lnum: number)
  var e = EntryAt(lnum)
  if empty(e)
    return
  endif
  setline(lnum, strpart(getline(lnum), 0, b:wend_name_col) .. e.tail)
enddef

def UpdateCursor()
  if b:wend_name_col <= 0
    return
  endif
  var l = line('.')
  var ino = InodeOf(getline(l))
  # Re-sync when the line OR the entry under it changed (the latter happens
  # after dd, where the line number stays put but a new entry slides in).
  if l == b:wend_cur && ino ==# b:wend_cur_inode
    return
  endif
  var m = mode()
  if m ==# 'v' || m ==# 'V' || m ==# "\<C-v>"
    return
  endif
  var wasmod = &l:modified
  if b:wend_cur > 0
    CollapseLine(b:wend_cur)
  endif
  ExpandLine(l)
  b:wend_cur = l
  b:wend_cur_inode = ino
  if !wasmod
    setlocal nomodified
  endif
enddef

def NavigateTo(dir: string): bool
  var d = Abspath(dir)
  if !isdirectory(d)
    return false
  endif
  silent! execute 'file' fnameescape('wend://' .. d)
  Render(d)
  # Land on line 1 (the `total N` header) at column 1: it is not an entry, so
  # nothing auto-expands on arrival. A row expands only once the cursor moves
  # onto it.
  cursor(1, 1)
  UpdateCursor()
  return true
enddef

def ResolvePath(raw: string)
  var p = substitute(raw, '^\s*\|\s*$', '', 'g')
  if empty(p)
    return
  endif
  if p[0] !=# '/'
    p = b:wend_dir .. '/' .. p
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
      execute 'edit' fnameescape(ap)
    endif
  endif
enddef

def CommitPath()
  # <CR> handler: navigate to / create whatever the current row resolves to.
  # Never mutates the listing. stopinsert + nomodified keep this purely a
  # navigation action even if the name was edited in Insert mode.
  var ln = getline(line('.'))
  var p: string
  if !empty(EntryAt(line('.')))
    # A real listing row: take its name field (the full path once expanded).
    p = substitute(strpart(ln, b:wend_name_col), ' -> .*$', '', '')
  elseif ln =~ '^\s*total\s' || ln =~ '^\[empty\]'
    # The `ls` header and the empty-dir placeholder are not creatable paths.
    return
  else
    # A freshly typed line (e.g. opened with `o`): the whole line is the path,
    # so `o`, a bare name, <CR> creates a file (or a dir if it ends with '/').
    p = substitute(ln, '^\s*\|\s*$', '', 'g')
  endif
  if empty(p)
    return
  endif
  stopinsert
  setlocal nomodified
  ResolvePath(p)
enddef

def WriteCmd()
  if b:wend_name_col <= 0
    setlocal nomodified
    return
  endif
  var chmods: list<dict<any>> = []
  var renames: list<dict<any>> = []
  var seen: dict<bool> = {}
  var errs: list<string> = []
  for lnum in range(1, line('$'))
    var ln = getline(lnum)
    var modetok = ModeOf(ln)
    if modetok !~ MODE_RE
      continue                 # 'total N', '[empty]', blanks, freely-typed lines: ignored
    endif
    var inode = InodeOf(ln)
    if empty(inode) || !has_key(b:wend_byinode, inode)
      add(errs, 'line ' .. lnum .. ': unrecognized row')
      continue
    endif
    var e = b:wend_byinode[inode]
    seen[inode] = true
    # permission change?
    var newperm = NinePerm(modetok)
    if newperm !=# e.perm
      if newperm !~ PERM_RE
        add(errs, e.name .. ': bad mode')
      else
        add(chmods, {full: e.full, perm: newperm, old: e.perm})
      endif
    endif
    # name change (rename)? The displayed name is unchanged whether the row is
    # collapsed (bare name) or expanded (full path), so a real rename is only
    # when it matches NEITHER. (This is what fixes the bogus "target exists"
    # after dd: the slid-up row still reads as its own unchanged name.)
    var field = substitute(strpart(ln, b:wend_name_col), ' -> .*$', '', '')
    if field !=# e.name && field !=# e.full
      if e.name ==# '.' || e.name ==# '..'
        add(errs, e.name .. ': cannot be renamed')
      else
        var rawname = substitute(field, '^\s*\|\s*$', '', 'g')
        if empty(rawname)
          add(errs, e.name .. ': empty name')
        else
          var wantsDir = rawname =~ '/$'
          var ap = (rawname[0] ==# '/') ? Abspath(rawname) : Abspath(b:wend_dir .. '/' .. rawname)
          if fnamemodify(ap, ':h') !=# Abspath(b:wend_dir)
            add(errs, e.name .. ' -> moving across directories is unsupported')
          elseif wantsDir && e.type !=# 'd'
            add(errs, e.name .. ' -> changing type is unsupported')
          elseif isdirectory(ap) || filereadable(ap)
            add(errs, e.name .. ' -> target exists')
          else
            add(renames, {from: e.full, to: ap, name: e.name, newname: fnamemodify(ap, ':t')})
          endif
        endif
      endif
    endif
  endfor
  # deletions: entries that were in the listing but are gone from the buffer
  var deletes: list<dict<any>> = []
  for [inode, e] in items(b:wend_byinode)
    if !has_key(seen, inode)
      add(deletes, {full: e.full, name: e.name, type: e.type, special: (e.name ==# '.' || e.name ==# '..')})
    endif
  endfor
  # ---- atomic gate: any problem => commit nothing, leave buffer as-is ----
  if !empty(errs)
    echohl ErrorMsg
    echom 'wend: not saved (' .. len(errs) .. ' issue(s)): ' .. join(errs[0 : 2], '; ') .. (len(errs) > 3 ? ' ...' : '')
    echohl NONE
    return
  endif
  if empty(chmods) && empty(renames) && empty(deletes)
    # Nothing to commit. Refresh from disk so any freshly typed but unmatched
    # lines (e.g. an `o` line that was never navigated with <CR>) are cleared
    # instead of lingering on screen.
    var ln0 = line('.')
    Render(b:wend_dir)
    cursor(min([ln0, line('$')]), 1)
    UpdateCursor()
    echom 'wend: no changes'
    return
  endif
  # ---- confirm destructive ops once ----
  if !empty(deletes) || !empty(renames)
    var lines: list<string> = []
    for d in deletes
      if d.special
        add(lines, '!! DELETE ' .. (d.name ==# '.' ? 'CURRENT DIRECTORY' : 'PARENT DIRECTORY') .. ': ' .. d.full)
      else
        add(lines, 'delete ' .. d.name .. (d.type ==# 'd' ? '/' : ''))
      endif
    endfor
    for r in renames
      add(lines, 'rename ' .. r.name .. ' -> ' .. r.newname)
    endfor
    for c in chmods
      add(lines, 'chmod  ' .. c.perm .. ' ' .. fnamemodify(c.full, ':t'))
    endfor
    if confirm("wend will apply:\n" .. join(lines, "\n"), "&Yes\n&No", 2) != 1
      # Cancelled: discard the attempted edits by refreshing from disk so the
      # buffer no longer looks dd'd / edited.
      var lc = line('.')
      Render(b:wend_dir)
      cursor(min([lc, line('$')]), 1)
      UpdateCursor()
      echom 'wend: cancelled (listing refreshed)'
      return
    endif
  endif
  # ---- apply: chmod, then rename, then delete (regular before '.'/'..') ----
  var applied = 0
  var fails: list<string> = []
  for c in chmods
    if !setfperm(c.full, c.perm)
      add(fails, 'chmod ' .. fnamemodify(c.full, ':t'))
    elseif getfperm(c.full) !=# c.old
      applied += 1
    endif
  endfor
  for r in renames
    if rename(r.from, r.to) == 0
      applied += 1
    else
      add(fails, 'rename ' .. r.name)
    endif
  endfor
  for d in deletes
    if d.special
      continue
    endif
    var rc = (d.type ==# 'd') ? delete(d.full, 'rf') : delete(d.full)
    if rc == 0
      applied += 1
    else
      add(fails, 'delete ' .. d.name)
    endif
  endfor
  for d in deletes
    if !d.special
      continue
    endif
    var rc = (d.type ==# 'd') ? delete(d.full, 'rf') : delete(d.full)
    if rc == 0
      applied += 1
    else
      add(fails, 'delete ' .. d.name)
    endif
  endfor
  # If the directory we were viewing was removed, climb to the nearest ancestor.
  if !isdirectory(b:wend_dir)
    var up = b:wend_dir
    while !isdirectory(up) && up !=# '/'
      up = fnamemodify(up, ':h')
    endwhile
    NavigateTo(up)
  else
    var ln0 = line('.')
    Render(b:wend_dir)
    cursor(min([ln0, line('$')]), 1)
    UpdateCursor()
  endif
  if !empty(fails)
    echohl ErrorMsg | echom 'wend: applied ' .. applied .. ', failed: ' .. join(fails, ', ') | echohl NONE
  else
    echom 'wend: applied ' .. applied .. ' change(s)'
  endif
enddef

def DefaultDir(): string
  # Directory a no-argument :Wend opens. Prefer the current buffer's own
  # location over Vim's working directory, since getcwd() does not follow the
  # buffer you are editing.
  if exists('b:wend_dir') && !empty(b:wend_dir)
    return b:wend_dir                 # re-invoked from inside a wend listing
  endif
  if &buftype ==# '' && !empty(expand('%'))
    return expand('%:p:h')            # a real (named) file buffer -> its dir
  endif
  return getcwd()                     # unnamed/special buffer -> fall back to cwd
enddef

def Open(arg: string)
  var dir = Abspath(empty(arg) ? DefaultDir() : arg)
  if !isdirectory(dir)
    echohl ErrorMsg | echom 'wend: not a directory: ' .. dir | echohl NONE
    return
  endif
  enew
  setlocal buftype=acwrite bufhidden=wipe noswapfile nolist wrap breakindent
  setlocal filetype=wend
  b:wend_cur = 0
  b:wend_cur_inode = ''
  b:wend_name_col = 0
  b:wend_byinode = {}
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
