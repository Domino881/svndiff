"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" svndiff (C) 2007 Ico Doornekamp
"
" This program is free software; you can redistribute it and/or modify it
" under the terms of the GNU General Public License as published by the Free
" Software Foundation; either version 2 of the License, or (at your option)
" any later version.
"
" This program is distributed in the hope that it will be useful, but WITHOUT
" ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
" FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
" more details.

if v:version < 700
   finish
endif

" Globals for this plugin

let s:sign_base = 200000  " Base for our sign id's, hoping to avoid colisions
let s:is_active = {}      " dictionary with buffer names that have svndiff active
let s:rcs_type = {}       " RCS type, will be autodetected to one of svn/git/hg/cvs/p4
let s:rcs_cmd = {}        " Shell command to execute to get contents of clean file from RCS
let s:diff_signs = {}     " dict with list of ids of all signs, per file
let s:diff_blocks = {}    " dict with list of ids of first line of each diff block, per file
let s:changedtick = {}    " dict with changedticks of each buffer since last invocation
let s:newline = {}        " dict with newline character of each buffer

" Commands to execute to get current file contents in various rcs systems

let s:rcs_cmd_svn = "svn cat '%s'"
let s:rcs_cmd_git = "git cat-file -p HEAD:$(git ls-files --full-name '%s')"
let s:rcs_cmd_hg  = "hg cat '%s'"
let s:rcs_cmd_cvs = "cvs -q update -p '%s'"
let s:rcs_cmd_p4  = "a ws print '%s'"
let s:rcs_cmd_fossil = "fossil finfo -p '%s'"

"
" Do the diff and update signs.
"
function s:Svndiff_init()
  let fname = bufname("%")
  " Guess RCS type for this file

  if ! has_key(s:rcs_type, fname)

    " skip new files created in vim buffer

    if ! filereadable(fname)
      return 0
    end

    let info = system("LANG=C svn info " . fname)
    if match(info, "Path") != -1
      let s:rcs_type[fname] = "svn"
      let s:rcs_cmd[fname] = s:rcs_cmd_svn
    end

    let info = system("git status " . fname)
    if v:shell_error == 0
      let s:rcs_type[fname] = "git"
      let s:rcs_cmd[fname] = s:rcs_cmd_git
    end

    let info = system("fossil status " . fname)
    if v:shell_error == 0
      let s:rcs_type[fname] = "fossil"
      let s:rcs_cmd[fname] = s:rcs_cmd_fossil
    end


    let info = system("cvs st " . fname)
    if v:shell_error == 0
      let s:rcs_type[fname] = "cvs"
      let s:rcs_cmd[fname] = s:rcs_cmd_cvs
    end

    let info = system("hg status " . fname)
    if v:shell_error == 0
      let s:rcs_type[fname] = "hg"
      let s:rcs_cmd[fname] = s:rcs_cmd_hg
    end

    let info = system("a p4~ fstat " . fname)
    if match(info, "depotFile") != -1
      let s:rcs_type[fname] = "p4"
      let s:rcs_cmd[fname] = s:rcs_cmd_p4
    end
  end

  " Could not detect RCS type, print message and exit

  if has_key(s:rcs_type, fname)
    let s:is_active[fname] = 1
  else
    echom "svndiff: No version control system found."
  end
endfunction

silent! call s:Svndiff_init()

function g:Svndiff_update(...)

  let fname = bufname("%")

  call s:Svndiff_init()

  if ! exists("s:is_active[fname]")
    return 0
  end

  " Find newline characters for the current file
   
   if ! has_key(s:newline, fname) 
      let l:ff_to_newline = { "dos": "\r\n", "unix": "\n", "mac": "\r" }
      let s:newline[fname] = l:ff_to_newline[&l:fileformat]
      echom s:newline[fname]
   end

   " Check if the changedticks changed since the last invocation of this
   " function. If nothing changed, there's no need to update the signs.

   if exists("s:changedtick[fname]") && s:changedtick[fname] == b:changedtick
      return 1
   end
   let s:changedtick[fname] = b:changedtick

   " The diff has changed since the last time, so we need to update the signs.
   " This is where the magic happens: pipe the current buffer contents to a
   " shell command calculating the diff in a friendly parsable format.

   let contents = join(getbufline("%", 1, "$"), s:newline[fname])
   let diff = system("diff -U0 <(" . substitute(s:rcs_cmd[fname], "%s", fname, "") . ") <(cat;echo)", contents)

   " clear the old signs

   call s:Svndiff_clear()

   " Parse the output of the diff command and put signs at changed, added and
   " removed lines

   for line in split(diff, '\n')
      
    let part = matchlist(line, '@@ -\([0-9]*\),*\([0-9]*\) +\([0-9]*\),*\([0-9]*\) @@')

      if ! empty(part)
         let old_from  = part[1]
         let old_count = part[2] == '' ? 1 : part[2]
         let new_from  = part[3]
         let new_count = part[4] == '' ? 1 : part[4]

         " Figure out if text was added, removed or changed.
         
         if old_count == 0
            let from  = new_from
            let to    = new_from + new_count - 1
            let name  = 'svndiff_add'
            let info  = new_count . " lines added"
         elseif new_count == 0
            let from  = new_from
            let to    = new_from 
            let name  = 'svndiff_delete'
            let info  = old_count . " lines deleted"
            if ! exists("g:svndiff_one_sign_delete")
               let to += 1
            endif
         else
            let from  = new_from
            let to    = new_from + new_count - 1
            let name  = 'svndiff_change'
            let info  = new_count . " lines changed"
         endif

         let id = from + s:sign_base   
         let s:diff_blocks[fname] += [{ 'id': id, 'info': info }]

         " Add signs to mark the changed lines 
         
         let line = from
         while line <= to
            let id = line + s:sign_base
            exec 'sign place ' . id . ' line=' . line . ' name=' . name . ' file=' . fname
            let s:diff_signs[fname] += [id]
            let line = line + 1
         endwhile

      endif
   endfor

endfunction



"
" Remove all signs we placed earlier 
"

function s:Svndiff_clear(...)
   let fname = bufname("%")
   if exists("s:diff_signs[fname]") 
      for id in s:diff_signs[fname]
         exec 'sign unplace ' . id . ' file=' . fname
      endfor
   end
   let s:diff_blocks[fname] = []
   let s:diff_signs[fname] = []
endfunction


"
" Jump to previous diff block sign above the current line
"

function s:Svndiff_prev(...)
   let fname = bufname("%")
   let diff_blocks_reversed = reverse(copy(s:diff_blocks[fname]))
   for block in diff_blocks_reversed
      let line = block.id - s:sign_base
      if line < line(".") 
         call setpos(".", [ 0, line, 1, 0 ])
         echom 'svndiff: ' . block.info
         return
      endif
   endfor
   echom 'svndiff: no more diff blocks above cursor'
endfunction


"
" Jump to next diff block sign below the current line
"

function s:Svndiff_next(...)
   let fname = bufname("%")
   for block in s:diff_blocks[fname]
      let line = block.id - s:sign_base
      if line > line(".") 
         call setpos(".", [ 0, line, 1, 0 ])
         echom 'svndiff: ' . block.info
         return
      endif
   endfor
   echom 'svndiff: no more diff blocks below cursor'
endfunction


"
" Wrapper function: Takes one argument, which is the action to perform:
" {next|prev|clear}
"

function Svndiff(...)

   let cmd = exists("a:1") ? a:1 : ''
   let fname = bufname("%")
   if fname == ""
      echom "Buffer has no file name, can not do a diff"
      return
   endif

   if cmd == 'clear'
      let s:changedtick[fname] = 0
      if exists("s:is_active[fname]") 
         unlet s:is_active[fname]
      endif
      call s:Svndiff_clear()
   end
   
   if cmd == 'prev'
      let s:is_active[fname] = 1
      let ok = g:Svndiff_update()
      if ok
         call s:Svndiff_prev()
      endif
   endif

   if cmd == 'next'
      let s:is_active[fname] = 1
      let ok = g:Svndiff_update()
      if ok
         call s:Svndiff_next()
      endif
   endif

endfunction


" Define sign characters and colors

sign define svndiff_add    text=> texthl=diffAdd
sign define svndiff_delete text=< texthl=diffDelete
sign define svndiff_change text=! texthl=diffChange


" Define autocmds if autoupdate is enabled

if exists("g:svndiff_autoupdate")
   autocmd BufWrite * silent! call g:Svndiff_update()
endif

" vi: ts=2 sw=2

