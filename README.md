# Jesper's Dotfiles

Personal macOS / Ubuntu shell configuration and tools, forked from Ben Alman's
dotfiles project. The `dotfiles` command installs the configuration and updates
an existing checkout.

## Installation

### Read this critically important warning before you install

This repository contains my personal setup. Review the files and init scripts
before installing; the installer changes your home directory and can run commands
with `sudo`. Fork and adapt it for your own machine.

### OS X Notes

On macOS, install the Xcode Command Line Tools with `xcode-select --install`.

### Actual installation (for you)

Clone your adapted fork into `~/src/dotfiles`, then run its local installer:

```sh
git clone https://github.com/YOUR_USER/YOUR_FORK.git ~/src/dotfiles
cd ~/src/dotfiles
bin/dotfiles
source ~/.bashrc
```

Select your branch when cloning if it differs from the fork's default branch.
The installer updates this checkout using `git pull`.

### Actual installation (for me)

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jesperronn/cowboy-dotfiles/main/bin/dotfiles)" && source ~/.bashrc
```

## Use and update

Run `dotfiles` to update the checkout and apply its configuration again. Run
`bin/dotfiles --help` for individual installation phases; the options are defined
in the [installer](bin/dotfiles).

## How the "dotfiles" command works

A full run installs Git via APT if needed on Ubuntu, clones this repository into
`~/src/dotfiles` if absent (or updates the existing checkout), then performs the
steps below. Init-script selections are saved in `caches/init/selected` for reuse.
Files replaced by the copy and link steps are backed up under `backups/`.

### The "copy" step

Files in `copy/` are copied into `~/`. Use this for files you want to edit locally,
such as configuration containing personal information.

### The "link-dir" step

Managed directories in `link-dir/` are symlinked into `~/`. The installer skips
state-heavy directories such as `.config` and `.claude`; the complete exclusion
list is in `link_dir_is_managed` in the [installer](bin/dotfiles).

### The "link-file" step

Files in `link-file/` are symlinked individually into `~/`, preserving their
parent directories. For example, `link-file/.continue/config.yaml` manages only
`~/.continue/config.yaml`, leaving logs and sessions alone.

### The "init" step

The installer offers an OS-filtered selection of [init scripts](init) and runs
the chosen scripts in filename order. Review them before selecting them:

- [Xcode Command Line Tools](init/10_osx_xcode.sh)
- [Homebrew and Brewfile packages](init/20_osx_homebrew.sh)
- [fzf shell integration](init/40_fzf.sh)
- [Ruby via RVM](init/50_ruby.sh)
- [Shared Claude skills](init/60_claude_agents.sh)

### Other subdirectories

- `bin/`: commands added to `PATH` by the installer.
- `caches/`: generated caches and saved installer selections.
- `source/`: shell configuration loaded in filename order.

## Aliases and Functions

Add aliases, functions and settings to [source/](source). Run `src` to reload
these files; its implementation lives in [.bashrc](link-file/.bashrc).

## Scripts

- [rehome](bin/rehome): bring an existing file or folder under repository
  management, or move it back out. Run `rehome --help` for destinations and options.
- [rehome_doctor](bin/rehome_doctor): find unmanaged home-directory items.
- [lint](bin/lint): check shell syntax and ShellCheck findings; run `bin/lint --help`
  for output formats and automatic fixes.
- [runtests](bin/runtests): run shell tests; run `bin/runtests --help` for options.

Browse [bin/](bin) for the remaining commands.

## AI tooling

See [docs/ai-tooling.md](docs/ai-tooling.md) for Ollama persistence, shared Modelfile
aliases and editor integration.

## Prompt

The interactive Bash prompt uses [Starship](source/40_prompt.sh), configured in
[starship.toml](link-file/.config/starship.toml).

## Hacking my dotfiles

The installer handles `copy/`, `link-dir/`, `link-file/` and `init/`; missing or
empty directories are ignored. Run `bin/lint` followed by `bin/runtests` before
submitting changes. See [AGENTS.md](AGENTS.md) for contributor conventions.

Report bugs through [issues](https://github.com/jesperronn/cowboy-dotfiles/issues)
or submit a [pull request](https://github.com/jesperronn/cowboy-dotfiles/pulls).

## Inspiration

- [Ben Alman's dotfiles](https://github.com/cowboy/dotfiles)
- [gf3/dotfiles](https://github.com/gf3/dotfiles)
- [mathiasbynens/dotfiles](https://github.com/mathiasbynens/dotfiles)

## License

Copyright (c) 2014 "Cowboy" Ben Alman. Licensed under the
[MIT license](http://benalman.com/about/license/).
