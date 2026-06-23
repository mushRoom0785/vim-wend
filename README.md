# vim-wend: <u>w</u>rit<u>e</u> is all you <u>n</u>ee<u>d</u>
> v0.4.1

edit-driven file navigation plugin for vim.

*warnning*: still in development, might be buggy.

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

and this window can be edited like a regular file, just like waht you do in vim.
the path expands when the cursor lands on it; which channel you commit with decides what an edit means:

- `<enter>` — navigate: enter a dir, `:edit` a file, or create-and-open a missing path. works in both mode.
- `:w` — commit changes you made in INSERT mode to disk:
	- delete a row (e.g. `dd`) deletes that file/folder;
	- edit a name, then go back to normal without `<enter>`, renames it in place (content preserved);
	- edit the mode column runs chmod.

### other features
coming soon...

## quick start
copy `plugin/wend.vim` to your runtimepath or use command `:source /path/to/wend.vim` in vim, then run `:Wend [dir]` (defaults to the current directory).

## ref
[vim](https://www.vim.org) - text editor.

[dired](https://www.gnu.org/software/emacs/manual/html_node/emacs/Dired.html) - an emacs plugin.

[vim-dirvish](https://github.com/justinmk/vim-dirvish) - what i used in person before wend.
