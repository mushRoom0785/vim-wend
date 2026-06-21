vim9script
# wend.vim — v1  文本编辑驱动的文件导航器
# 依赖: Vim 9.0+ (:echo has('vim9script') 应为 1)
# 语义:
#   每行 =  <10字符mode>  …/<name>[/]      例: drwxr-xr-x …/src/  /  -rw-r--r-- …/main.c
#   hjkl  = 普通光标移动(buffer 自带)
#   i/a   = 当前行路径展开为绝对路径供编辑;  <CR> 提交(存在则导航/不存在则创建); <Esc> 放弃并收起
#   改 mode 列后 :w = 对发生变化的行执行 chmod(setfperm)

const ELLIPSIS = '…/'
const MODE_RE  = '^[-dlpbcs][-rwxsStT]\{9}'   # ls 风格 10 字符模式串

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
  return t .. e.perm           # e.perm 是 getfperm 风格 9 字符
enddef

def PathPart(text: string): string
  # 去掉开头的 mode 列 + 空白, 返回路径部分(可能含 …/ 或已是绝对路径)
  return matchstr(text, '^\S\+\s\+\zs.*$')
enddef

def Render(dir: string)
  b:wend_dir = dir
  b:wend_snapshot = {}          # fullpath -> 9字符权限(渲染时快照)
  var lines: list<string> = []
  var entries: list<dict<any>>
  try
    entries = readdirex(dir)    # List<dict>, 默认按名排序; 含隐藏文件
  catch
    entries = []
  endtry
  for e in entries
    var full = dir .. '/' .. e.name
    b:wend_snapshot[full] = e.perm
    var slash = (e.type ==# 'dir' || e.type ==# 'linkd') ? '/' : ''
    lines->add(ModeOf(e) .. ' ' .. ELLIPSIS .. e.name .. slash)
  endfor
  setlocal modifiable
  silent! :%delete _
  if empty(lines)
    setline(1, '"" <empty> ' .. dir)
  else
    setline(1, lines)
  endif
  setlocal nomodified
  normal! gg
enddef

def NavigateTo(dir: string): bool
  var d = Abspath(dir)
  if !isdirectory(d)
    return false
  endif
  b:wend_expanded = 0
  silent! exec 'file' fnameescape('wend://' .. d)
  Render(d)
  return true
enddef

def ResolvePath(raw: string)
  var p = substitute(raw, '^\s*\|\s*$', '', 'g')
  if empty(p)
    return
  endif
  var wantDir = p =~ '/$'
  p = substitute(p, '^' .. ELLIPSIS, escape(b:wend_dir .. '/', '\&'), '')
  var ap = Abspath(p)
  if isdirectory(ap)
    NavigateTo(ap)
  elseif filereadable(ap)
    exec 'edit' fnameescape(ap)
  else
    if wantDir
      mkdir(ap, 'p')
      NavigateTo(ap)
    else
      exec 'edit' fnameescape(ap)   # 不存在的文件: 打开空 buffer, 待用户 :w 落盘
    endif
  endif
enddef

def ExpandCurrentLine()
  var lnum = line('.')
  var text = getline(lnum)
  if text !~ MODE_RE || stridx(text, ELLIPSIS) < 0
    b:wend_expanded = 0
    return
  endif
  b:wend_saved_line = text
  b:wend_expanded = lnum
  var repl = escape(b:wend_dir .. '/', '\&')
  setline(lnum, substitute(text, ELLIPSIS, repl, ''))
enddef

def CollapseCurrentLine()
  if b:wend_expanded == 0
    return
  endif
  var lnum = b:wend_expanded
  b:wend_expanded = 0
  if lnum >= 1 && lnum <= line('$')
    setline(lnum, b:wend_saved_line)   # <Esc> 放弃路径编辑, 还原折叠态
  endif
enddef

def CommitPath()
  var p = PathPart(getline('.'))
  b:wend_expanded = 0       # 取消即将触发的 InsertLeave 收起(避免误改新 buffer)
  stopinsert
  ResolvePath(p)
enddef

def WriteCmd()
  var changed = 0
  var errs: list<string> = []
  for lnum in range(1, line('$'))
    var text = getline(lnum)
    var mode = matchstr(text, '^\S\+')
    if mode !~ MODE_RE .. '$'
      continue
    endif
    var pathraw = PathPart(text)
    pathraw = substitute(pathraw, '^' .. ELLIPSIS, '', '')
    pathraw = substitute(pathraw, '/$', '', '')
    var full = b:wend_dir .. '/' .. pathraw
    if !has_key(b:wend_snapshot, full)
      continue                       # 只处理已知条目的权限列; 路径改动不在此通道
    endif
    var newperm = strpart(mode, 1)   # 去掉类型字符 -> 9 字符
    if newperm !=# b:wend_snapshot[full]
      if setfperm(full, newperm)
        changed += 1
      else
        errs->add(fnamemodify(full, ':t'))
      endif
    endif
  endfor
  Render(b:wend_dir)                 # 从文件系统刷新, 顺带重置 modified
  if !empty(errs)
    echohl ErrorMsg | echom 'wend: chmod 失败: ' .. join(errs, ', ') | echohl NONE
  else
    echom 'wend: 已应用 ' .. changed .. ' 处权限修改'
  endif
enddef

def Open(arg: string)
  var dir = Abspath(empty(arg) ? getcwd() : arg)
  if !isdirectory(dir)
    echohl ErrorMsg | echom 'wend: 不是目录: ' .. dir | echohl NONE
    return
  endif
  enew
  setlocal buftype=acwrite bufhidden=wipe noswapfile nolist nowrap cursorline
  setlocal filetype=wend
  b:wend_expanded = 0
  b:wend_saved_line = ''
  augroup wend_buf
    autocmd! * <buffer>
    autocmd InsertEnter  <buffer> ExpandCurrentLine()
    autocmd InsertLeave  <buffer> CollapseCurrentLine()
    autocmd BufWriteCmd  <buffer> WriteCmd()
  augroup END
  inoremap <buffer> <silent> <CR> <ScriptCmd>CommitPath()<CR>
  NavigateTo(dir)
enddef

command! -nargs=? -complete=dir Wend Open(<q-args>)
