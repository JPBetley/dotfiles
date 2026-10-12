# Dotfiles

Personal shell and tool configuration for Phil's Macs, plus the command that wires it into a machine.

## Language

**Install**:
The single command that brings a machine in line with this repo; safe to run any number of times.
_Avoid_: Bootstrap, installscript, reset

**Link**:
The Install step that wires repo files into `$HOME`.
_Avoid_: Symlinking, setup

**Provision**:
The Install step that puts packages and tools on the machine.
_Avoid_: Brew step, setup

**Profile**:
An optional named layer (work, personal) a machine adds on top of the base config; chosen once with `--profile` and remembered in `~/.dotfiles-profile`.
_Avoid_: Role, machine type, environment

**Stub**:
A machine-owned file in `$HOME` that other tools also write to, which Link only ensures contains the one line pulling in the repo's version.
_Avoid_: Wrapper, loader, symlink

**Managed line**:
The single line in a Stub that Link owns, recognised by its `# dotfiles:link` marker.
_Avoid_: Source line, include line

**Custom folder**:
The untracked folder at `~/.dotfiles-custom` holding config and scripts you write yourself but keep out of git; Install never creates or copies it.
_Avoid_: Custom repo, private dotfiles, local overrides

**Machine-local**:
Config that tools write for one machine, living in its Stubs rather than the repo or the Custom folder.
_Avoid_: Local, custom

**Backup**:
A conflicting file in `$HOME` that Link moved aside before replacing it.
_Avoid_: Overwrite
