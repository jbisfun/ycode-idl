# ycode-idl

[idl](https://github.com/jbisfun/idl) inside ycode, as a Lua extension on ycode's
`lua_hooks` (`gpui.register_panel`).

A right-dock panel ("idl: panel") for the idlproj.yml at or above an open folder, or one
or two levels below it (a pull workspace keeps repos one level down):

- targets from `idl list`; pick one or all
- debug / release profile and `--strict`
- Build, Install, Check, Test, Gen, Lint, Fmt, Clean
- devices from the Jimpactor tray app (`idl devices list`); Install hands the IPA to
  the selected one
- streamed output with a Stop button; `file:line:col: error:` lines are highlighted
  and open their file on click

"idl: build" and "idl: install" run from the command palette with the panel's selection.

## Install

    ln -s "$PWD" ~/.config/zed/hooks/ycode-idl

then "ycode: reload hooks". `idl` must be on ycode's PATH.
