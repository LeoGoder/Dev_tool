# Development environment

Installation script for my development environment on Linux and macOS.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/LeoGoder/Dev_tool/main/install.sh -o install.sh
bash install.sh
```

The script is downloaded first and then run (rather than piped directly into
bash) so that the sudo prompt can read from the keyboard.

## What gets installed

| Component | Details |
|---|---|
| Zsh + Oh My Zsh | `zsh-autosuggestions` and `zsh-syntax-highlighting` plugins |
| Rust | Latest stable release via `rustup` |
| Starship | Built with cargo + **Catppuccin Powerline** preset (Mocha) |
| Neovim | Latest GitHub release (tarball) in `~/.local/opt/nvim`, config cloned into `~/.config/nvim`, `nvim` alias |
| LazyGit | Latest GitHub release (binary) in `~/.local/opt/lazygit`, `lazygit` alias |
| Vim | System package + `~/.vimrc` (sudo mode only) |
| Zellij | Latest GitHub release (binary) in `~/.local/opt/zellij`, config + `zellij` alias |
| Nerd Font | JetBrains Mono Nerd Font, userland install |
| Kitty | Official binary from `sw.kovidgoyal.net/kitty/binary/` |

System packages include `git`, `curl`, `zsh`, `vim` and the build tools needed
to compile Rust/Starship.

## Sudo

At startup, the script asks whether it may use sudo:

- **Yes**: installs system packages, changes the default shell with `chsh`,
  and installs Vim.
- **No**: no system packages and no Vim. Zsh is launched automatically from
  `~/.bashrc` in interactive bash shells. Everything else (Rust, Starship,
  Neovim, LazyGit, Zellij, font, Kitty) is installed in the home directory.
  No-sudo mode requires `git`, `curl`, `tar`, `unzip`, `zsh`, `awk`, `sed`,
  `grep`, `find` and `cmp` to already be available.

## Options

```text
./install.sh            # asks about sudo, then installs / updates
./install.sh --force    # reinstalls everything, even if already present
./install.sh --sudo     # force sudo mode
./install.sh --no-sudo  # force no-sudo mode
./install.sh --help
```

## Supported systems

- **Linux**: dnf, apt, pacman, zypper, apk or xbps.
- **macOS**: Intel and Apple Silicon, via Homebrew (installed automatically if
  missing). Xcode Command Line Tools are required.

## After installation

- Open a new terminal, or run `exec zsh`.
- The default shell change takes effect after logging back in.
- Remember to select **JetBrainsMono Nerd Font** in Kitty's settings.
- Existing configuration files are backed up as `.bak.<date>` before being
  modified.
- The script is idempotent: it can be run again without reinstalling everything.
