# vim-wend
> v0.5.3

edit-driven file navigation plugin for vim.

## features
### edit-driven
the navigation window is a live `ls -lai` listing:

```text
# e.g.

total 128
986 drwxr-xr-x 1 mush mush   12 Jun  8 11:45 .
957 drwxr-xr-x 1 mush mush  124 Jun 20 11:11 ..
958 drwxr-xr-x 2 mush mush 4096 Jun 22 12:00 sub
959 -rw-r--r-- 1 mush mush   12 Jun 22 12:00 foo.c
960 -rwxr--r-- 1 mush mush    8 Jun 22 12:00 foo

# ...
```

and this window can be edited like a regular file, just like what you do in vim.
the cursor auto-snaps to the name column on each row. which channel you commit with decides what an edit means:

- `gf` : navigate: jump to the dir or file under the cursor -- a listed row, or a path you typed on a line, as long as it already exists. works in normal and visual mode; a missing path is an error and is never created here. 
- `:w` : commit every change in the listing to disk at once. rows are matched by inode, so a change tracks the real on-disk entry, not fragile line text:
	- create: type a NEW bare name in the current dir (a trailing `/` makes a directory) -> mkdir / touch on `:w`;
	- delete: remove a row (e.g. `dd`) → deletes that file/folder;
	- rename: edit a name in place -> renames it (content preserved);
	- chmod: edit the mode column -> runs chmod;
	- go there or create: type a full path (e.g. `a/b/c.c`) on a line, then `:w` jumps there, creating it if missing ->  land inside the target.
- `<C-o>` : go back to your previous wend position (buffer-local; ordinary buffers' `<C-o>` is untouched). every time you land on a new line or a new directory the spot is pushed, so `<C-o>` walks back line by line and across directory hops. opening a real file resets this history; use `:Wend` to reopen a listing.

### other features
coming soon...

## quick start
wend is written in Vim9script, so it needs **Vim 9.0+** (Neovim does not support Vim9script). copy `plugin/wend.vim` to your runtimepath or use command `:source /path/to/wend.vim` in vim, then run `:Wend [dir]` (defaults to the current directory).

## ref
the following projects inspired wend.

[vim](https://www.vim.org) - text editor.

[dired](https://www.gnu.org/software/emacs/manual/html_node/emacs/Dired.html) - an emacs plugin.

[vim-dirvish](https://github.com/justinmk/vim-dirvish) - what i used in person before wend.



## TODO List:

- add config flags (e.g. to toggle optional behaviours on/off).
- add test scripts to check whether the user's system/env suits the plugin; safety tests and a quick-start script are also needed.
- support macOS or even windows.
- add & support themes.
