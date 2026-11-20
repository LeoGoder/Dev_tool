#!/usr/bin/env bash
#
# install.sh - Installe l'environnement de travail complet (userland).
#
#   - Zsh + Oh My Zsh + plugins d'autocomplétion
#   - Rust (rustup) + Starship (preset Catppuccin Powerline)
#   - Neovim (dernière release, tarball) + ta config
#   - LazyGit (dernière release, binaire) + alias
#   - Vim (gestionnaire de paquets) + ton vimrc
#   - Zellij (dernière release) + ta config
#   - JetBrains Mono Nerd Font (userland)
#   - Kitty (binaire officiel)
#
# Au démarrage, le script demande s'il peut utiliser sudo. En cas de refus,
# aucun paquet système n'est installé : zsh est lancé depuis ~/.bashrc et Vim
# n'est pas installé. Le reste (Rust, Starship, Neovim, Zellij, police, Kitty)
# s'installe dans le home de l'utilisateur.
#
# Usage :
#   ./install.sh            # demande pour sudo, puis installe / met à jour
#   ./install.sh --force    # réinstalle tout, même si déjà présent
#   ./install.sh --sudo     # force l'utilisation de sudo (pas de question)
#   ./install.sh --no-sudo  # mode sans sudo (pas de question)
#   ./install.sh --help
#
# Testé sur Fedora 44 et prévu pour macOS (Intel & Apple Silicon).
# Détecte dnf / apt / pacman / zypper / apk / xbps, et Homebrew sur macOS.
# Ne pas lancer en root : les paquets système passent par sudo (sauf Homebrew).

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------

NVIM_CONFIG_URL_SSH="git@github.com:LeoGoder/Neovim_custom_config.git"
NVIM_CONFIG_URL_HTTPS="https://github.com/LeoGoder/Neovim_custom_config.git"
VIM_CONFIG_URL="https://github.com/LeoGoder/vim_config.git"
ZELLIJ_CONFIG_URL="https://github.com/LeoGoder/zellij-config.git"
NERD_FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LOCAL_BIN="$HOME/.local/bin"
OPT_DIR="$HOME/.local/opt"
CARGO_BIN="$HOME/.cargo/bin"
ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

IS_MACOS=0
if [[ "$(uname -s)" == "Darwin" ]]; then
  IS_MACOS=1
fi

if [[ $IS_MACOS -eq 1 ]]; then
  KITTY_APP="$HOME/Applications/kitty.app"
  KITTY_BIN="$KITTY_APP/Contents/MacOS/kitty"
else
  KITTY_APP="$HOME/.local/kitty.app"
  KITTY_BIN="$KITTY_APP/bin/kitty"
fi

BREW=""

FORCE=0
USE_SUDO=""
BASHRC_ZSH=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED=""
fi

step() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s    [!] %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die()  { printf '\n%s[x] %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

on_error() {
  local rc=$?
  printf '\n%s[x] Échec (code %s) ligne %s : %s%s\n' \
    "$C_RED" "$rc" "${1:-?}" "${2:-?}" "$C_RESET" >&2
  exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/config_install.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: ${0##*/} [--force] [--sudo|--no-sudo] [--help]

  -f, --force     Réinstalle les composants déjà présents
      --sudo      Utilise sudo sans poser la question
      --no-sudo   Refuse sudo sans poser la question
  -h, --help      Affiche cette aide

Sans sudo : pas de paquets système ni de Vim, et zsh est lancé depuis ~/.bashrc.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force)   FORCE=1 ;;
    --sudo)       USE_SUDO=1 ;;
    --no-sudo)    USE_SUDO=0 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "Option inconnue : $1 (voir --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] && die "Ne lance pas ce script en root : il utilise sudo là où c'est nécessaire."

have() { command -v "$1" >/dev/null 2>&1; }

ask_sudo() {
  [[ -n "$USE_SUDO" ]] && return 0

  if [[ -t 0 ]]; then
    printf '%s\n' "${C_BOLD}Autoriser l'utilisation de sudo ?${C_RESET}"
    printf '  Oui : paquets système (zsh, vim, git…) + changement de shell par défaut.\n'
    printf '  Non : zsh sera lancé depuis ~/.bashrc, Vim ne sera pas installé.\n'
    printf 'Utiliser sudo ? [Y/n] '
    local reply=""
    read -r reply || true
    case "$reply" in
      ""|y|Y|yes|YES|o|O|oui|OUI|Oui) USE_SUDO=1 ;;
      *) USE_SUDO=0 ;;
    esac
  else
    warn "Aucun terminal interactif : mode sans sudo par défaut."
    USE_SUDO=0
  fi

  if [[ $USE_SUDO -eq 1 ]]; then
    info "Mode avec sudo."
  else
    info "Mode sans sudo : aucun paquet système ne sera installé."
  fi
}

as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    die "sudo est requis pour exécuter : $*"
  fi
}

backup_path() {
  local path="$1" bak
  [[ -e "$path" || -L "$path" ]] || return 0
  bak="${path}.bak.$(date +%Y%m%d-%H%M%S)"
  mv "$path" "$bak"
  warn "Sauvegarde : $path -> $bak"
}

link_file() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -L "$dest" ]]; then
    if [[ "$dest" -ef "$src" ]]; then
      info "Déjà lié : $dest"
      return 0
    fi
    rm -f "$dest"
  elif [[ -e "$dest" ]]; then
    backup_path "$dest"
  fi
  ln -s "$src" "$dest"
  ok "Lien créé : $dest -> $src"
}

make_wrapper() {
  local target="$1" wrapper="$2"
  mkdir -p "$(dirname "$wrapper")"
  cat > "$wrapper" <<EOF
#!/bin/sh
exec "$target" "\$@"
EOF
  chmod +x "$wrapper"
  info "Lanceur créé : $wrapper -> $target"
}

download() {
  local url="$1" dest="$2"
  info "Téléchargement : $url"
  curl -fL --retry 3 --connect-timeout 20 --progress-bar -o "$dest" "$url"
}

latest_tag() {
  local repo="$1" tag
  tag="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
    awk '
      !found && match($0, /"tag_name": *"[^"]*"/) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*"tag_name": *"/, "", s); sub(/"$/, "", s)
        found = s
      }
      END { if (found) print found }')"
  [[ -n "$tag" ]] || die "Impossible de récupérer la dernière version de $repo"
  printf '%s' "$tag"
}

latest_asset() {
  local repo="$1" pattern="$2" url
  url="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
    awk -v pat="$pattern" '
      match($0, /"browser_download_url": *"[^"]*"/) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*"browser_download_url": *"/, "", s); sub(/"$/, "", s)
        if (s ~ pat && !found) { found = s; }
      }
      END { if (found) print found }')"
  [[ -n "$url" ]] || die "Aucun asset ne correspond à '$pattern' pour $repo"
  printf '%s' "$url"
}

clone_or_update() {
  local url="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    info "Mise à jour du dépôt : $dest"
    git -C "$dest" pull --ff-only
  elif [[ -e "$dest" ]]; then
    backup_path "$dest"
    git clone "$url" "$dest"
  else
    mkdir -p "$(dirname "$dest")"
    info "Clonage : $url -> $dest"
    git clone "$url" "$dest"
  fi
}

# ---------------------------------------------------------------------------
# Détection du système
# ---------------------------------------------------------------------------

detect_pm() {
  if [[ $IS_MACOS -eq 1 ]]; then
    ensure_homebrew
    PM=brew
    return 0
  fi

  if   have dnf;         then PM=dnf
  elif have apt-get;     then PM=apt
  elif have pacman;      then PM=pacman
  elif have zypper;      then PM=zypper
  elif have apk;         then PM=apk
  elif have xbps-install; then PM=xbps
  else die "Aucun gestionnaire de paquets supporté (dnf, apt, pacman, zypper, apk, xbps)."
  fi
}

ensure_homebrew() {
  if have brew; then
    BREW="$(command -v brew)"
    return 0
  fi

  # Homebrew peut être installé mais absent du PATH de cette session
  local candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      BREW="$candidate"
      eval "$("$BREW" shellenv)"
      return 0
    fi
  done

  [[ $IS_MACOS -eq 1 ]] || die "Homebrew est introuvable."

  if ! xcode-select -p >/dev/null 2>&1; then
    die "Xcode Command Line Tools requis. Lance 'xcode-select --install', puis relance ce script."
  fi

  step "Installation de Homebrew"
  local installer
  installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  [[ -n "$installer" ]] || die "Impossible de télécharger l'installeur Homebrew."
  NONINTERACTIVE=1 /bin/bash -c "$installer"

  if [[ -x /opt/homebrew/bin/brew ]]; then
    BREW=/opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then
    BREW=/usr/local/bin/brew
  else
    die "Homebrew a été installé mais le binaire 'brew' est introuvable."
  fi
  eval "$("$BREW" shellenv)"
  ok "Homebrew installé : $BREW"
}

current_user_shell() {
  local shell_path=""
  if [[ $IS_MACOS -eq 1 ]] && have dscl; then
    shell_path="$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null |
      awk 'NR==1 { print $2 }' || true)"
  elif [[ $IS_MACOS -eq 1 ]]; then
    shell_path="${SHELL:-}"
  else
    shell_path="$(awk -F: -v u="$(id -un)" '$1 == u { print $7; exit }' /etc/passwd)"
  fi
  [[ -n "$shell_path" ]] || shell_path="${SHELL:-}"
  printf '%s' "$shell_path"
}

case "$(uname -m)" in
  x86_64|amd64)   NVIM_ARCH="x86_64"; ZELLIJ_ARCH="x86_64" ;;
  aarch64|arm64)  NVIM_ARCH="arm64";  ZELLIJ_ARCH="aarch64" ;;
  *) die "Architecture non supportée : $(uname -m)" ;;
esac

if [[ $IS_MACOS -eq 1 ]]; then
  ZELLIJ_TARGET="${ZELLIJ_ARCH}-apple-darwin"
  LAZYGIT_OS="darwin"
else
  ZELLIJ_TARGET="${ZELLIJ_ARCH}-unknown-linux-musl"
  LAZYGIT_OS="linux"
fi
LAZYGIT_ARCH="$NVIM_ARCH"

# ---------------------------------------------------------------------------
# 1. Paquets système (git, curl, zsh, vim, outils de compilation…)
# ---------------------------------------------------------------------------

install_system_packages() {
  detect_pm
  step "Paquets système ($PM)"

  local base pkg_zsh pkg_vim
  case "$PM" in
    dnf)
      base="git curl wget tar unzip xz fontconfig gcc make pkgconf-pkg-config openssl-devel"
      pkg_zsh="zsh"; pkg_vim="vim-enhanced"
      ;;
    apt)
      base="git curl wget tar unzip xz-utils fontconfig build-essential pkg-config libssl-dev"
      pkg_zsh="zsh"; pkg_vim="vim"
      ;;
    pacman)
      base="git curl wget tar unzip xz fontconfig base-devel openssl pkgconf"
      pkg_zsh="zsh"; pkg_vim="vim"
      ;;
    zypper)
      base="git curl wget tar unzip xz fontconfig gcc make pkg-config libopenssl-devel"
      pkg_zsh="zsh"; pkg_vim="vim"
      ;;
    apk)
      base="git curl wget tar unzip xz fontconfig build-base openssl-dev pkgconfig"
      pkg_zsh="zsh"; pkg_vim="vim"
      ;;
    xbps)
      base="git curl wget tar unzip xz fontconfig base-devel pkg-config openssl-devel"
      pkg_zsh="zsh"; pkg_vim="vim"
      ;;
    brew)
      # macOS : zsh et les outils de base sont fournis par le système
      base="git vim"
      pkg_zsh=""; pkg_vim=""
      ;;
  esac

  local -a pkgs
  read -r -a pkgs <<< "$base $pkg_zsh $pkg_vim"

  if [[ $PM != "brew" && $EUID -ne 0 ]] && have sudo; then
    sudo -v || warn "Impossible de mettre en cache les droits sudo."
  fi

  case "$PM" in
    dnf)    as_root dnf install -y "${pkgs[@]}" ;;
    apt)
      as_root apt-get update -y
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    pacman) as_root pacman -Sy --needed --noconfirm "${pkgs[@]}" ;;
    zypper) as_root zypper --non-interactive install "${pkgs[@]}" ;;
    apk)    as_root apk add --no-cache "${pkgs[@]}" ;;
    xbps)   as_root xbps-install -Sy "${pkgs[@]}" ;;
    brew)   "$BREW" install "${pkgs[@]}" ;;
  esac

  mkdir -p "$LOCAL_BIN" "$OPT_DIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
  ok "Paquets système installés (git, curl, zsh, vim…)"
}

prepare_dirs() {
  mkdir -p "$LOCAL_BIN" "$OPT_DIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
}

check_userland_deps() {
  step "Dépendances (mode sans sudo)"
  local cmd missing=()
  for cmd in git curl tar unzip awk sed grep find cmp zsh; do
    have "$cmd" || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    die "Commandes manquantes : ${missing[*]}. Installe-les manuellement ou relance avec sudo."
  fi
  ok "Dépendances disponibles : git, curl, tar, unzip, zsh…"
}

configure_bashrc_zsh() {
  step "Zsh depuis ~/.bashrc (sans sudo)"
  local zsh_bin rc="$HOME/.bashrc" stamp
  zsh_bin="$(command -v zsh || true)"
  [[ -n "$zsh_bin" ]] || die "zsh est introuvable. Installe-le manuellement ou relance avec sudo."

  touch "$rc"
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -a "$rc" "${rc}.bak.${stamp}"
  info "Sauvegarde : ${rc}.bak.${stamp}"

  # Retire un éventuel ancien bloc géré
  awk '
    /^# >>> config_install zsh >>>$/ { skip = 1; next }
    /^# <<< config_install zsh <<<$/ { skip = 0; next }
    !skip { print }
  ' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"

  if [[ "$(current_user_shell)" == "$zsh_bin" ]]; then
    ok "zsh est déjà le shell par défaut, ~/.bashrc inchangé."
    return 0
  fi

  cat >> "$rc" <<'BASH_BLOCK'

# >>> config_install zsh >>>
# Pas de sudo : impossible de changer le shell par défaut avec chsh.
# On lance zsh automatiquement dans les shells bash interactifs.
if [ -n "$BASH_VERSION" ] && [ -z "$ZSH_VERSION" ] && command -v zsh >/dev/null 2>&1; then
  case $- in
    *i*) exec zsh ;;
  esac
fi
# <<< config_install zsh <<<
BASH_BLOCK

  BASHRC_ZSH=1
  ok "zsh sera lancé automatiquement depuis ~/.bashrc."
}

# ---------------------------------------------------------------------------
# 2. Zsh par défaut
# ---------------------------------------------------------------------------

set_default_shell() {
  step "Shell par défaut"
  local zsh_bin current_shell
  zsh_bin="$(command -v zsh || true)"
  [[ -n "$zsh_bin" ]] || die "zsh est introuvable après l'installation des paquets."
  current_shell="$(current_user_shell)"

  if [[ "$current_shell" == "$zsh_bin" ]]; then
    ok "zsh est déjà le shell par défaut."
    return 0
  fi

  info "Passage de $current_shell à $zsh_bin"
  if ! grep -qx "$zsh_bin" /etc/shells 2>/dev/null; then
    info "Ajout de $zsh_bin à /etc/shells"
    echo "$zsh_bin" | as_root tee -a /etc/shells >/dev/null || \
      warn "Impossible d'ajouter $zsh_bin à /etc/shells."
  fi
  if [[ $IS_MACOS -eq 1 ]]; then
    if ! chsh -s "$zsh_bin"; then
      warn "chsh a échoué. Change le shell manuellement (Réglages Système > Utilisateurs)."
    fi
  elif [[ $EUID -eq 0 ]]; then
    chsh -s "$zsh_bin" "$(id -un)"
  elif have sudo; then
    if ! sudo chsh -s "$zsh_bin" "$(id -un)"; then
      warn "chsh a échoué. Lance manuellement : sudo chsh -s $zsh_bin $(id -un)"
    fi
  elif ! chsh -s "$zsh_bin"; then
    warn "chsh a échoué. Change le shell manuellement."
  fi

  current_shell="$(current_user_shell)"
  if [[ "$current_shell" == "$zsh_bin" ]]; then
    ok "zsh est maintenant le shell par défaut."
  fi
}

# ---------------------------------------------------------------------------
# 3. Oh My Zsh + plugins d'autocomplétion
# ---------------------------------------------------------------------------

install_oh_my_zsh() {
  step "Oh My Zsh"
  if [[ -d "$HOME/.oh-my-zsh" ]]; then
    ok "Oh My Zsh est déjà installé."
  else
    info "Installation de Oh My Zsh (sans lancer zsh, sans changer le shell)…"
    local omz_installer
    omz_installer="$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    [[ -n "$omz_installer" ]] || die "Impossible de télécharger l'installeur Oh My Zsh."
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$omz_installer"
    ok "Oh My Zsh installé."
  fi

  step "Plugins Zsh (autosuggestions + syntax-highlighting)"
  mkdir -p "$ZSH_CUSTOM_DIR/plugins"
  clone_or_update "https://github.com/zsh-users/zsh-autosuggestions.git" \
    "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions"
  clone_or_update "https://github.com/zsh-users/zsh-syntax-highlighting.git" \
    "$ZSH_CUSTOM_DIR/plugins/zsh-syntax-highlighting"
  ok "Plugins installés."
}

# ---------------------------------------------------------------------------
# 4. Rust + Starship (preset Catppuccin Powerline)
# ---------------------------------------------------------------------------

install_rust() {
  step "Rust (rustup)"
  [[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"
  export PATH="$CARGO_BIN:$PATH"

  if have rustup; then
    ok "rustup est déjà installé ($(rustup --version 2>/dev/null | awk 'NR==1'))."
  else
    info "Installation de rustup (profil stable)…"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
      sh -s -- -y --no-modify-path --profile default
    ok "Rust installé."
  fi

  [[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"
  have cargo || die "cargo est introuvable après l'installation de Rust."
}

install_starship() {
  step "Starship + preset Catppuccin Powerline"
  export PATH="$CARGO_BIN:$PATH"

  if [[ -x "$CARGO_BIN/starship" && $FORCE -eq 0 ]]; then
    ok "Starship est déjà installé ($("$CARGO_BIN/starship" --version | awk 'NR==1'))."
  else
    info "Compilation de Starship via cargo (peut prendre quelques minutes)…"
    if [[ $FORCE -eq 1 ]]; then
      cargo install starship --locked --force
    else
      cargo install starship --locked
    fi
    ok "Starship installé."
  fi

  # Preset officiel Catppuccin Powerline (Mocha par défaut)
  local theme="$XDG_CONFIG_HOME/starship.toml"
  mkdir -p "$XDG_CONFIG_HOME"
  info "Génération du preset catppuccin-powerline…"
  "$CARGO_BIN/starship" preset catppuccin-powerline --force -o "$TMP_DIR/starship.toml"

  # Le preset désactive le saut de ligne : on le réactive pour que
  # $line_break (juste avant $character) passe bien à la ligne.
  awk '
    /^\[/ { in_lb = ($0 == "[line_break]") }
    in_lb && /^disabled = true$/ { sub(/true/, "false") }
    { print }
  ' "$TMP_DIR/starship.toml" > "$TMP_DIR/starship-fixed.toml"

  if [[ -f "$theme" ]] && cmp -s "$TMP_DIR/starship-fixed.toml" "$theme"; then
    info "Thème déjà à jour : $theme"
  else
    [[ -f "$theme" ]] && backup_path "$theme"
    mv "$TMP_DIR/starship-fixed.toml" "$theme"
    ok "Preset Catppuccin Powerline écrit dans $theme (line_break activé)"
  fi
}

# ---------------------------------------------------------------------------
# 5. Neovim (dernière release, tarball) + config
# ---------------------------------------------------------------------------

install_neovim() {
  step "Neovim (dernière release)"
  local tag version url installed
  tag="$(latest_tag neovim/neovim)"
  version="${tag#v}"

  installed=""
  if [[ -x "$OPT_DIR/nvim/bin/nvim" ]]; then
    installed="$("$OPT_DIR/nvim/bin/nvim" --version 2>/dev/null | awk 'NR==1 { v = $NF; sub(/^v/, "", v); print v }')"
  fi

  if [[ "$installed" == "$version" && $FORCE -eq 0 ]]; then
    ok "Neovim $version est déjà installé."
  else
    local asset_pattern
    if [[ $IS_MACOS -eq 1 ]]; then
      asset_pattern="nvim-macos-${NVIM_ARCH}[.]tar[.]gz$"
    else
      asset_pattern="nvim-linux-${NVIM_ARCH}[.]tar[.]gz$"
    fi
    url="$(latest_asset neovim/neovim "$asset_pattern")"
    download "$url" "$TMP_DIR/nvim.tar.gz"

    info "Extraction dans $OPT_DIR/nvim"
    rm -rf "$OPT_DIR/nvim"
    mkdir -p "$OPT_DIR/nvim"
    tar -xzf "$TMP_DIR/nvim.tar.gz" -C "$OPT_DIR/nvim" --strip-components=1

    [[ -x "$OPT_DIR/nvim/bin/nvim" ]] || die "Le binaire nvim est introuvable après extraction."
    ok "Neovim $version installé dans $OPT_DIR/nvim"
  fi

  step "Configuration Neovim"
  local dest="$XDG_CONFIG_HOME/nvim"
  if [[ -d "$dest/.git" ]]; then
    info "Mise à jour de la config existante…"
    if ! GIT_SSH_COMMAND="ssh -o BatchMode=yes" git -C "$dest" pull --ff-only; then
      warn "git pull a échoué (modifications locales ?), config conservée."
    fi
  else
    [[ -e "$dest" || -L "$dest" ]] && backup_path "$dest"
    mkdir -p "$(dirname "$dest")"
    info "Clonage de $NVIM_CONFIG_URL_SSH"
    if ! GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
         git clone "$NVIM_CONFIG_URL_SSH" "$dest"; then
      warn "Clonage SSH impossible (clé absente ?), tentative en HTTPS…"
      rm -rf "$dest"
      git clone "$NVIM_CONFIG_URL_HTTPS" "$dest"
    fi
  fi
  ok "Config Neovim en place : $dest"
}

# ---------------------------------------------------------------------------
# 6. Vim (gestionnaire de paquets) + vimrc
# ---------------------------------------------------------------------------

install_vim_config() {
  step "Configuration Vim"
  local repo="$XDG_CONFIG_HOME/vim-config"
  clone_or_update "$VIM_CONFIG_URL" "$repo"
  [[ -f "$repo/vimrc" ]] || die "vimrc introuvable dans $repo"
  link_file "$repo/vimrc" "$HOME/.vimrc"
  ok "vimrc actif ($(vim --version 2>/dev/null | awk 'NR==1'))"
}

# ---------------------------------------------------------------------------
# 7. Zellij (dernière release) + config
# ---------------------------------------------------------------------------

install_zellij() {
  step "Zellij (dernière release)"
  local tag version url installed
  tag="$(latest_tag zellij-org/zellij)"
  version="${tag#v}"

  installed=""
  if [[ -x "$OPT_DIR/zellij/zellij" ]]; then
    installed="$("$OPT_DIR/zellij/zellij" --version 2>/dev/null | awk '{print $2}')"
  fi

  if [[ "$installed" == "$version" && $FORCE -eq 0 ]]; then
    ok "Zellij $version est déjà installé."
  else
    url="$(latest_asset zellij-org/zellij "zellij-${ZELLIJ_TARGET}[.]tar[.]gz$")"
    download "$url" "$TMP_DIR/zellij.tar.gz"

    info "Extraction dans $OPT_DIR/zellij"
    mkdir -p "$OPT_DIR/zellij"
    tar -xzf "$TMP_DIR/zellij.tar.gz" -C "$OPT_DIR/zellij"
    chmod +x "$OPT_DIR/zellij/zellij"

    [[ -x "$OPT_DIR/zellij/zellij" ]] || die "Le binaire zellij est introuvable après extraction."
    ok "Zellij $version installé dans $OPT_DIR/zellij"
  fi

  step "Configuration Zellij"
  local repo="$XDG_CONFIG_HOME/zellij-config"
  clone_or_update "$ZELLIJ_CONFIG_URL" "$repo"
  [[ -f "$repo/config.kdl" ]] || die "config.kdl introuvable dans $repo"
  mkdir -p "$XDG_CONFIG_HOME/zellij"
  link_file "$repo/config.kdl" "$XDG_CONFIG_HOME/zellij/config.kdl"
  ok "Config Zellij en place."
}

# ---------------------------------------------------------------------------
# 8. LazyGit (dernière release, binaire) + alias
# ---------------------------------------------------------------------------

install_lazygit() {
  step "LazyGit (dernière release)"
  local tag version url installed
  tag="$(latest_tag jesseduffield/lazygit)"
  version="${tag#v}"

  installed=""
  if [[ -x "$OPT_DIR/lazygit/lazygit" ]]; then
    installed="$("$OPT_DIR/lazygit/lazygit" --version 2>/dev/null |
      awk -F', ' '
        { for (i = 1; i <= NF; i++) if (found == "" && $i ~ /^version=/) { sub(/^version=/, "", $i); found = $i } }
        END { if (found != "") print found }')"
  fi

  if [[ "$installed" == "$version" && $FORCE -eq 0 ]]; then
    ok "LazyGit $version est déjà installé."
  else
    url="$(latest_asset jesseduffield/lazygit "lazygit_[0-9.]+_${LAZYGIT_OS}_${LAZYGIT_ARCH}[.]tar[.]gz$")"
    download "$url" "$TMP_DIR/lazygit.tar.gz"

    info "Extraction dans $OPT_DIR/lazygit"
    rm -rf "$OPT_DIR/lazygit"
    mkdir -p "$OPT_DIR/lazygit"
    tar -xzf "$TMP_DIR/lazygit.tar.gz" -C "$OPT_DIR/lazygit"
    chmod +x "$OPT_DIR/lazygit/lazygit"

    [[ -x "$OPT_DIR/lazygit/lazygit" ]] || die "Le binaire lazygit est introuvable après extraction."
    ok "LazyGit $version installé dans $OPT_DIR/lazygit"
  fi
}

# ---------------------------------------------------------------------------
# 9. JetBrains Mono Nerd Font (userland)
# ---------------------------------------------------------------------------

install_nerd_font() {
  step "JetBrains Mono Nerd Font (userland)"
  local font_dir existing

  if [[ $IS_MACOS -eq 1 ]]; then
    font_dir="$HOME/Library/Fonts"
  else
    font_dir="$XDG_DATA_HOME/fonts/JetBrainsMonoNerdFont"
  fi
  mkdir -p "$font_dir"

  if [[ $IS_MACOS -eq 1 ]]; then
    existing="$(find "$font_dir" -name 'JetBrainsMonoNerdFont*.ttf' -print 2>/dev/null | awk 'NR==1')"
  else
    existing="$(find "$font_dir" -name '*.ttf' -print 2>/dev/null | awk 'NR==1')"
  fi

  if [[ -n "$existing" && $FORCE -eq 0 ]]; then
    ok "Police déjà installée dans $font_dir"
  else
    download "$NERD_FONT_URL" "$TMP_DIR/JetBrainsMono.zip"
    rm -rf "$TMP_DIR/fonts"
    mkdir -p "$TMP_DIR/fonts"
    unzip -q -o "$TMP_DIR/JetBrainsMono.zip" -d "$TMP_DIR/fonts"

    if [[ $IS_MACOS -eq 1 ]]; then
      rm -f "$font_dir"/JetBrainsMonoNerdFont*.ttf
    else
      rm -rf "$font_dir"
      mkdir -p "$font_dir"
    fi
    find "$TMP_DIR/fonts" -name '*.ttf' -exec cp -f {} "$font_dir"/ \;
    ok "Police extraite dans $font_dir"
  fi

  if [[ $IS_MACOS -eq 1 ]]; then
    ok "Police disponible pour macOS (aucun cache à reconstruire)."
  elif have fc-cache; then
    fc-cache -f "$XDG_DATA_HOME/fonts" >/dev/null
    ok "Cache de polices mis à jour."
  else
    warn "fc-cache absent : installe fontconfig puis relance 'fc-cache -f'."
  fi
}

# ---------------------------------------------------------------------------
# 10. Kitty (binaire officiel)
# ---------------------------------------------------------------------------

install_kitty() {
  step "Kitty (binaire officiel)"
  if [[ -x "$KITTY_BIN" && $FORCE -eq 0 ]]; then
    ok "Kitty est déjà installé ($("$KITTY_BIN" --version 2>/dev/null | awk 'NR==1'))."
  else
    info "Téléchargement et installation via l'installeur officiel…"
    if [[ $IS_MACOS -eq 1 ]]; then
      mkdir -p "$HOME/Applications"
      curl -fsSL https://sw.kovidgoyal.net/kitty/installer.sh |
        sh /dev/stdin launch=n dest="$HOME/Applications"
    else
      curl -fsSL https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin launch=n
    fi
    ok "Kitty installé dans $KITTY_APP"
  fi

  if [[ $IS_MACOS -eq 1 ]]; then
    make_wrapper "$KITTY_BIN" "$LOCAL_BIN/kitty"
    if [[ -x "$KITTY_APP/Contents/MacOS/kitten" ]]; then
      make_wrapper "$KITTY_APP/Contents/MacOS/kitten" "$LOCAL_BIN/kitten"
    fi
  else
    ln -sfn "$KITTY_APP/bin/kitty" "$LOCAL_BIN/kitty"
    ln -sfn "$KITTY_APP/bin/kitten" "$LOCAL_BIN/kitten"

    # Intégration au menu d'applications (KDE/GNOME…)
    local desktop_src="$KITTY_APP/share/applications/kitty.desktop"
    if [[ -f "$desktop_src" ]]; then
      mkdir -p "$XDG_DATA_HOME/applications"
      sed -e "s|^Exec=kitty|Exec=$KITTY_APP/bin/kitty|" \
          -e "s|^TryExec=kitty|TryExec=$KITTY_APP/bin/kitty|" \
          -e "s|^Icon=kitty|Icon=$KITTY_APP/share/icons/hicolor/256x256/apps/kitty.png|" \
          "$desktop_src" > "$XDG_DATA_HOME/applications/kitty.desktop"
      if have update-desktop-database; then
        update-desktop-database "$XDG_DATA_HOME/applications" >/dev/null 2>&1 || true
      fi
    fi
  fi

  ok "kitty et kitten disponibles dans $LOCAL_BIN"
}

# ---------------------------------------------------------------------------
# 11. ~/.zshrc : plugins, PATH, alias, starship
# ---------------------------------------------------------------------------

configure_zshrc() {
  step "Configuration de ~/.zshrc"
  local rc="$HOME/.zshrc" stamp
  touch "$rc"
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -a "$rc" "${rc}.bak.${stamp}"
  info "Sauvegarde : ${rc}.bak.${stamp}"

  # Liste de plugins (Oh My Zsh la lit avant de se charger)
  if grep -qE '^plugins=\(' "$rc"; then
    local inner
    inner="$(awk '/^plugins=\(/ { print; exit }' "$rc")"
    inner="${inner#plugins=(}"
    inner="${inner%)}"
    inner="${inner# }"; inner="${inner% }"
    local plugin
    for plugin in git zsh-autosuggestions zsh-syntax-highlighting; do
      [[ " $inner " == *" $plugin "* ]] || inner="${inner:+$inner }$plugin"
    done
    awk -v repl="plugins=($inner)" '
      /^plugins=\(/ && !done { print repl; done = 1; next }
      { print }' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
  elif grep -q 'oh-my-zsh\.sh' "$rc"; then
    awk 'BEGIN { done = 0 }
         !done && /oh-my-zsh\.sh/ {
           print "plugins=(git zsh-autosuggestions zsh-syntax-highlighting)"
           done = 1
         }
         { print }' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
  else
    printf '\nplugins=(git zsh-autosuggestions zsh-syntax-highlighting)\n' >> "$rc"
  fi

  # Bloc géré, réécrit à chaque exécution
  awk '
    /^# >>> config_install >>>$/ { skip = 1; next }
    /^# <<< config_install <<<$/ { skip = 0; next }
    !skip { print }
  ' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"

  cat >> "$rc" <<'ZSH_BLOCK'

# >>> config_install >>>
export PATH="$HOME/.local/bin:$PATH"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Homebrew (macOS)
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# Binaires userland
alias nvim='$HOME/.local/opt/nvim/bin/nvim'
alias zellij='$HOME/.local/opt/zellij/zellij'
alias lazygit='$HOME/.local/opt/lazygit/lazygit'
# vim est fourni par le gestionnaire de paquets : aucun alias nécessaire.

# Prompt Starship (preset Catppuccin Powerline dans ~/.config/starship.toml)
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi
# <<< config_install <<<
ZSH_BLOCK

  ok "~/.zshrc configuré (plugins, PATH, alias nvim/zellij/lazygit, Starship)."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf '%s\n' "${C_BOLD}Installation de l'environnement de travail${C_RESET}"
info "Système : $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-inconnu}" || uname -s) ($(uname -m))"
info "Utilisateur : $(id -un) — HOME : $HOME"

ask_sudo
prepare_dirs

if [[ $USE_SUDO -eq 1 ]]; then
  install_system_packages
  set_default_shell
else
  check_userland_deps
  configure_bashrc_zsh
fi

install_oh_my_zsh
install_rust
install_starship
install_neovim

if [[ $USE_SUDO -eq 1 ]]; then
  install_vim_config
else
  step "Vim"
  info "Installation de Vim ignorée (mode sans sudo)."
fi

install_zellij
install_lazygit
install_nerd_font
install_kitty
configure_zshrc

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------

step "Résumé"
printf '    %-10s %s\n' "zsh"      "$(zsh --version 2>/dev/null || echo absent)"
printf '    %-10s %s\n' "vim"      "$(vim --version 2>/dev/null | awk 'NR==1' || echo absent)"
printf '    %-10s %s\n' "nvim"     "$("$OPT_DIR/nvim/bin/nvim" --version 2>/dev/null | awk 'NR==1' || echo absent)"
printf '    %-10s %s\n' "zellij"   "$("$OPT_DIR/zellij/zellij" --version 2>/dev/null || echo absent)"
printf '    %-10s %s\n' "lazygit"  "$("$OPT_DIR/lazygit/lazygit" --version 2>/dev/null | awk -F', ' '{ for (i = 1; i <= NF; i++) if (found == "" && $i ~ /^version=/) { sub(/^version=/, "", $i); found = $i } } END { if (found != "") print found }' || echo absent)"
printf '    %-10s %s\n' "starship" "$("$CARGO_BIN/starship" --version 2>/dev/null || echo absent)"
printf '    %-10s %s\n' "kitty"    "$("$LOCAL_BIN/kitty" --version 2>/dev/null | awk 'NR==1' || echo absent)"
printf '    %-10s %s\n' "rust"     "$("$CARGO_BIN/rustc" --version 2>/dev/null || echo absent)"

printf '\n%sInstallation terminée.%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
if [[ $USE_SUDO -eq 0 ]]; then
  if [[ $BASHRC_ZSH -eq 1 ]]; then
    printf "Mode sans sudo : zsh est lancé via ~/.bashrc et Vim n'a pas été installé.\\n"
  else
    printf "Mode sans sudo : Vim n'a pas été installé.\\n"
  fi
fi
printf 'Ouvre un nouveau terminal (ou lance `exec zsh`) pour charger la configuration.\n'
printf 'Pense à définir JetBrainsMono Nerd Font dans les réglages de ton terminal.\n'
