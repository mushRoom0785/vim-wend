vim9script
# wend.vim — Text-driven file navigator (Vim9script)
# Version: 0.5.3 (unreleased; the major version stays 0 until the first tagged release)
# Requires: Vim 9.0+
#
# Philosophy: "write is all you need". The buffer IS a live `ls -lai` listing
# whose rows you edit. WHICH channel you use to commit decides the meaning of
# an edit, so a single buffer never has to juggle two conflicting intents:
#
#   gf    = NAVIGATION (read-only; never mutates anything). Put the cursor on a
#           row and press gf to go where its name points:
#             existing dir   -> enter it (re-renders this buffer in place)
#             existing file  -> :edit it
#             missing path   -> error (gf never creates)
#           gf takes the file name under the cursor (native <cfile>); a bare
#           name resolves against the directory being viewed, and a leading '~'
#           or '$VAR' is expanded. For a name with spaces, visually select it
#           and press gf (visual-mode gf, like Vim's own v_gf, uses the
#           selection verbatim). Directory rows are taken over by wend itself,
#           so no netrw/dirvish buffer is ever opened. <CR> has no binding here.
#
#           Typing a PATH (one with a '/' inside it, or a leading '/', '~' or
#           '$') stays exactly as you typed it (no ls row). Press gf to jump to
#           it when it already exists, or :w to GO there, creating it if missing
#           (a trailing '/' makes a directory, otherwise a file, making parent
#           dirs as needed) -- you land inside the target, not back in this
#           list. A bare single field (e.g. `foo` or `foo/`) is instead a NEW
#           entry in the CURRENT directory, created on :w (see below).
#
#   <C-o> = GO BACK to the previous wend position. wend keeps its OWN back-stack
#           (it reuses one buffer across directories, so the native jumplist
#           cannot track it), and the map is buffer-local, so <C-o> in ordinary
#           buffers is untouched. Every time you land on a NEW line or a new
#           directory the spot is pushed; <C-o> walks back through them, across
#           directory hops too. A horizontal h/l within a line is NOT a new
#           spot. The history lives in this buffer, so opening a real file with
#           gf clears it -- use :Wend to reopen a listing.
#
#   :w    = COMMIT every change in the listing at once. Rows are matched by
#           inode (the first `ls -lai` column), so a change is tied to the real
#           on-disk entry rather than to fragile line text:
#             - create : type a NEW bare name in the current dir (a trailing
#                        '/' means a directory) -> mkdir / touch on :w. (A typed
#                        PATH instead navigates there, creating it if missing;
#                        see gf above.)
#             - delete : remove a row (e.g. dd) -> delete that file/dir.
#             - rename : edit a name in place, then :w -> rename() inside the
#                        SAME directory (content preserved). Names no longer
#                        auto-expand, so any number of rows can be renamed in a
#                        single :w.
#             - chmod  : edit the 10-char mode column -> setfperm().
#
# Atomic writes: if ANY edit in the buffer is unsupported, :w commits NOTHING
# and leaves the buffer untouched so you can fix it (no "which parts saved?"
# confusion). Unsupported edits: a '/' inside a renamed name (moving across
# directories), changing an entry's type, renaming '.'/'..', or a rename/create
# whose target already exists. True moves are out of scope — use :!mv.
#
# Confirmation: any delete or rename is confirmed once before being applied;
# deleting '.' (current dir) or '..' (parent dir) is called out explicitly.
# Answering No re-renders the listing (the buffer is refreshed back to disk
# reality, so a cancelled delete no longer looks deleted).
#
# Display: each row shows the bare name, exactly like `ls -lai` (no conceal, no
# highlighting, no auto-expansion).
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

def Render(dir: string)
  b:wend_dir = dir
  b:wend_byinode = {}        # inode -> {full, name, type, perm}
  b:wend_name_col = 0        # byte column where the name field starts (fixed per render)
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

def NavigateTo(dir: string): bool
  var d = Abspath(dir)
  if !isdirectory(d)
    return false
  endif
  silent! execute 'file' fnameescape('wend://' .. d)
  Render(d)
  # Land on line 1 (the `total N` header) at column 1: it is not an entry.
  cursor(1, 1)
  return true
enddef

def Navigate(raw: string)
  # gf handler: navigate to whatever the row's name resolves to. Never creates.
  var p = trim(raw)
  if empty(p)
    echohl ErrorMsg | echom 'wend: no file name under cursor' | echohl NONE
    return
  endif
  # Expand a leading '~' or environment variable so absolute user paths resolve.
  if p[0] ==# '~' || p[0] ==# '$'
    p = expand(p)
  endif
  if p[0] !=# '/'
    p = b:wend_dir .. '/' .. p
  endif
  var ap = Abspath(p)
  if isdirectory(ap)
    NavigateTo(ap)
  elseif filereadable(ap)
    execute 'edit' fnameescape(ap)
  else
    echohl ErrorMsg | echom 'wend: cannot find "' .. trim(raw) .. '"' | echohl NONE
  endif
enddef

def NormalGf()
  # Normal-mode gf: resolve the file name under the cursor (native <cfile>), so
  # a bare name resolves against b:wend_dir. Header/placeholder rows do nothing.
  var ln = getline('.')
  if ln =~ '^\s*total\s' || ln =~ '^\[empty\]'
    return
  endif
  Navigate(expand('<cfile>'))
enddef

def VisualGf()
  # Visual-mode gf (wend's analogue of native v_gf): use the highlighted text
  # verbatim, bypassing 'isfname', so names with spaces work. Invoked via
  # :<C-u>, so '< and '> already mark the (single-line) selection.
  var lnum = line("'<")
  var c1 = charcol("'<")
  var c2 = charcol("'>")
  if &selection ==# 'exclusive'
    c2 -= 1
  endif
  if c2 < c1
    return
  endif
  Navigate(strcharpart(getline(lnum), c1 - 1, c2 - c1 + 1))
enddef

def ApplyCreate(c: dict<any>): string
  # Create one new entry (a bare name) in the current directory. Returns '' on
  # success or an error message. A trailing '/' means a directory.
  try
    if c.isdir
      if !mkdir(c.ap, 'p')
        return c.raw .. ': mkdir failed'
      endif
    else
      writefile([], c.ap)
      if !filereadable(c.ap)
        return c.raw .. ': create failed'
      endif
    endif
  catch
    return c.raw .. ': ' .. v:exception
  endtry
  return ''
enddef

def EnsureTyped(raw: string): string
  # Resolve a typed path against the current dir ('~'/'$' expanded) and create
  # it if missing (a trailing '/' -> directory, otherwise a file, making parent
  # dirs as needed). Returns the absolute path, or '' if it could not be made.
  var p = trim(raw)
  if empty(p)
    return ''
  endif
  var wantDir = p =~ '/$'
  var core = substitute(p, '/$', '', '')
  if core[0] ==# '~' || core[0] ==# '$'
    core = expand(core)
  endif
  var ap = (core[0] ==# '/') ? Abspath(core) : Abspath(b:wend_dir .. '/' .. core)
  if !isdirectory(ap) && !filereadable(ap)
    try
      if wantDir
        mkdir(ap, 'p')
      else
        var parent = fnamemodify(ap, ':h')
        if !isdirectory(parent)
          mkdir(parent, 'p')
        endif
        writefile([], ap)
      endif
    catch
      echohl ErrorMsg | echom 'wend: cannot create "' .. p .. '": ' .. v:exception | echohl NONE
      return ''
    endtry
  endif
  return ap
enddef

def ApplyNavs(navs: list<string>)
  # Create any missing typed paths, then navigate into the last reachable one
  # (a directory re-renders the listing there; a file is opened with :edit).
  var dest = ''
  for raw in navs
    var ap = EnsureTyped(raw)
    if !empty(ap)
      dest = ap
    endif
  endfor
  if empty(dest)
    return
  endif
  setlocal nomodified            # the typed line is not an unsaved edit to keep
  if isdirectory(dest)
    NavigateTo(dest)
  elseif filereadable(dest)
    execute 'edit' fnameescape(dest)
  endif
enddef

def WriteCmd()
  if b:wend_name_col <= 0
    setlocal nomodified
    return
  endif
  var chmods: list<dict<any>> = []
  var renames: list<dict<any>> = []
  var creates: list<dict<any>> = []
  var navs: list<string> = []
  var seen: dict<bool> = {}
  var errs: list<string> = []
  for lnum in range(1, line('$'))
    var ln = getline(lnum)
    var modetok = ModeOf(ln)
    if modetok !~ MODE_RE
      # Header, [empty] and blank lines are ignored.
      var t = trim(ln)
      if empty(t) || t =~ '^total\s' || t =~ '^\[empty\]'
        continue
      endif
      # A bare single field (no '/' inside, no leading '~'/'$'; an optional
      # trailing '/' just means "make a dir") is a NEW entry in THIS directory,
      # created on :w. Anything carrying a path (an inner '/', or a leading
      # '/', '~' or '$') is a navigate-or-create target: on :w we go there,
      # creating it if it does not exist yet (handled after the listing edits).
      var core = substitute(t, '/$', '', '')
      var isField = core !~# '/' && core[0] !=# '~' && core[0] !=# '$'
      if !isField
        add(navs, t)
        continue
      endif
      var wantDir = t =~ '/$'
      var ap = Abspath(b:wend_dir .. '/' .. core)
      if isdirectory(ap) || filereadable(ap)
        add(errs, t .. ': already exists')
      else
        add(creates, {raw: t, ap: ap, isdir: wantDir})
      endif
      continue
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
  if empty(chmods) && empty(renames) && empty(deletes) && empty(creates)
    if !empty(navs)
      # Only typed navigation paths: go to (and create) them, no listing edits.
      ApplyNavs(navs)
      return
    endif
    # Nothing to commit. Refresh from disk so any leftover typed-but-unmatched
    # lines are cleared instead of lingering on screen.
    var ln0 = line('.')
    Render(b:wend_dir)
    cursor(min([ln0, line('$')]), 1)
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
    for c in creates
      add(lines, 'create ' .. c.raw)
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
  for c in creates
    var cerr = ApplyCreate(c)
    if empty(cerr)
      applied += 1
    else
      add(fails, cerr)
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
  elseif empty(navs)
    var ln0 = line('.')
    Render(b:wend_dir)
    cursor(min([ln0, line('$')]), 1)
  endif
  if !empty(fails)
    echohl ErrorMsg | echom 'wend: applied ' .. applied .. ', failed: ' .. join(fails, ', ') | echohl NONE
  else
    echom 'wend: applied ' .. applied .. ' change(s)'
  endif
  if !empty(navs)
    # After committing listing edits, go to the typed path(s), creating any
    # that do not exist yet. This supersedes the re-render above.
    ApplyNavs(navs)
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

def SnapToName()
  # Keep the cursor on the human-readable NAME column instead of the leading
  # inode/metadata columns. It re-snaps whenever a vertical move (j/k/G/...)
  # lands on a NEW line; a horizontal h/l on the same line is left alone, so
  # you can still reach the inode/mode columns to edit them. No native Vim
  # option pins the cursor to a column like this, so a CursorMoved autocmd
  # drives it.
  if get(b:, 'wend_name_col', 0) <= 0
    return
  endif
  # Never fight a visual selection (visual-mode gf relies on '< and '>).
  var m = mode()
  if m ==# 'v' || m ==# 'V' || m ==# "\<C-v>"
    return
  endif
  var l = line('.')
  if l == get(b:, 'wend_lastline', -1)
    return                     # same line: a horizontal move -> leave it be
  endif
  b:wend_lastline = l
  if ModeOf(getline(l)) !~ MODE_RE
    return                     # header / [empty] / typed path line: no name col
  endif
  cursor(l, b:wend_name_col + 1)
enddef

def OnCursorMoved()
  # CursorMoved hook: keep the cursor on the name column, then push the spot
  # onto wend's own back-stack (see GoBack). Only a NEW (dir, line) spot is
  # recorded -- a horizontal h/l on the same line is not a separate position.
  SnapToName()
  if mode() !=# 'n'
    return                     # ignore visual / operator-pending moves
  endif
  var dir = get(b:, 'wend_dir', '')
  if empty(dir)
    return
  endif
  var l = line('.')
  if !empty(b:wend_jl) && b:wend_jl[b:wend_ji].dir ==# dir && b:wend_jl[b:wend_ji].line == l
    return                     # same spot (incl. the landing of a <C-o> jump)
  endif
  if b:wend_ji < len(b:wend_jl) - 1
    b:wend_jl = b:wend_jl[0 : b:wend_ji]   # drop the now-stale forward history
  endif
  add(b:wend_jl, {dir: dir, line: l})
  b:wend_ji = len(b:wend_jl) - 1
enddef

def GoBack()
  # <C-o>: return to the previous wend position recorded by OnCursorMoved.
  if get(b:, 'wend_ji', 0) <= 0
    echo 'wend: already at the oldest position'
    return
  endif
  var ni = b:wend_ji - 1
  var target = b:wend_jl[ni]
  if target.dir !=# get(b:, 'wend_dir', '')
    if !isdirectory(target.dir) || !NavigateTo(target.dir)
      echohl ErrorMsg | echom 'wend: previous directory is gone: ' .. target.dir | echohl NONE
      return
    endif
  endif
  b:wend_ji = ni
  var lnum = target.line
  if lnum > line('$')
    lnum = line('$')
  endif
  if lnum < 1
    lnum = 1
  endif
  cursor(lnum, 1)
  # The CursorMoved this fires snaps to the name column and is de-duplicated
  # against b:wend_jl[b:wend_ji], so the back-stack is left intact.
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
  b:wend_name_col = 0
  b:wend_byinode = {}
  b:wend_lastline = -1
  b:wend_jl = []             # back-stack of {dir, line} spots for <C-o>
  b:wend_ji = -1             # index of the current spot within b:wend_jl
  augroup wend_buf
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> WriteCmd()
    autocmd CursorMoved <buffer> OnCursorMoved()
  augroup END
  nnoremap <buffer> <silent> gf <ScriptCmd>NormalGf()<CR>
  xnoremap <buffer> <silent> gf :<C-u>call <SID>VisualGf()<CR>
  nnoremap <buffer> <silent> <C-o> <ScriptCmd>GoBack()<CR>
  NavigateTo(dir)
  b:wend_jl = [{dir: b:wend_dir, line: line('.')}]   # seed the starting spot
  b:wend_ji = 0
enddef

command! -nargs=? -complete=dir Wend Open(<q-args>)
