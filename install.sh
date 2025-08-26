#!/usr/bin/env bash
# install.sh - Install memmark (single-file Bash tool) into a bin directory.
# - Installs from local ./memmark.sh by default, or from a provided URL via --url.
# - Detects a suitable bin dir (prefers $HOME/.local/bin) and provides PATH guidance.
# - Avoids sudo; choose a writable directory for the current user unless --bin-dir points elsewhere.

set -euo pipefail
IFS=$' \t\n'
LC_ALL=C

usage() {
  cat <<'USAGE'
install.sh - Install memmark

Usage:
  ./install.sh [--bin-dir DIR] [--name NAME] [--url URL] [--force]

Options:
  --bin-dir DIR   Target directory to install into (default: auto-detect).
  --name NAME     Installed command name (default: memmark).
  --url URL       Download memmark.sh from URL instead of using local ./memmark.sh.
  --force         Overwrite existing target if it exists.
  -h, --help      Show this help.

Examples:
  ./install.sh                                   # install from local memmark.sh into ~/.local/bin
  ./install.sh --bin-dir /usr/local/bin          # install to /usr/local/bin (must be writable)
  ./install.sh --url https://raw.githubusercontent.com/<org>/<repo>/main/memmark.sh
USAGE
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

choose_bin_dir() {
  # Prefer a user-writable bin dir. Create $HOME/.local/bin or $HOME/bin if needed.
  local candidates=()
  candidates+=("$HOME/.local/bin")
  candidates+=("$HOME/bin")
  # If common system dirs are writable, consider them (no sudo here)
  [[ -w "/opt/homebrew/bin" ]] && candidates+=("/opt/homebrew/bin")
  [[ -w "/usr/local/bin" ]] && candidates+=("/usr/local/bin")

  local d
  for d in "${candidates[@]}"; do
    if [[ -d "$d" ]]; then
      if [[ -w "$d" ]]; then echo "$d"; return 0; fi
    else
      # attempt to create only for HOME-based dirs
      case "$d" in
        "$HOME"/*)
          mkdir -p "$d" 2>/dev/null || true
          if [[ -d "$d" && -w "$d" ]]; then echo "$d"; return 0; fi
          ;;
      esac
    fi
  done

  # Nothing suitable
  echo ""; return 1
}

in_path_dir() {
  # Return 0 if directory $1 appears as a full PATH segment
  local dir="$1" IFS=:
  for p in $PATH; do
    [[ "$p" == "$dir" ]] && return 0
  done
  return 1
}

main() {
  local bin_dir="" name="memmark" url="" force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin-dir) bin_dir="${2:-}"; shift 2 ;;
      --name)    name="${2:-}"; shift 2 ;;
      --url)     url="${2:-}"; shift 2 ;;
      --force)   force=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  if [[ -z "$bin_dir" ]]; then
    if ! bin_dir=$(choose_bin_dir); then
      echo "[install] Could not find a writable bin directory automatically." >&2
      echo "[install] Provide one via --bin-dir, e.g. \"$HOME/.local/bin\" or \"/usr/local/bin\"." >&2
      exit 1
    fi
  fi

  local src="" tmp=""
  if [[ -n "$url" ]]; then
    if have_cmd curl; then
      tmp=$(mktemp -t memmark.XXXXXX || true)
      [[ -z "$tmp" ]] && tmp="/tmp/memmark.$RANDOM.$RANDOM"
      echo "[install] Downloading from $url ..."
      curl -fsSL "$url" -o "$tmp"
      src="$tmp"
    elif have_cmd wget; then
      tmp=$(mktemp -t memmark.XXXXXX || true)
      [[ -z "$tmp" ]] && tmp="/tmp/memmark.$RANDOM.$RANDOM"
      echo "[install] Downloading from $url ..."
      wget -qO "$tmp" "$url"
      src="$tmp"
    else
      echo "[install] Need curl or wget to download from URL." >&2
      exit 1
    fi
  else
    if [[ -f "./memmark.sh" ]]; then
      src="./memmark.sh"
    else
      echo "[install] Local ./memmark.sh not found. Provide --url to download." >&2
      exit 1
    fi
  fi

  local dest="$bin_dir/$name"
  if [[ -e "$dest" && $force -ne 1 ]]; then
    echo "[install] Target $dest already exists. Use --force to overwrite." >&2
    exit 1
  fi

  echo "[install] Installing to $dest"
  install -m 0755 "$src" "$dest" 2>/dev/null || {
    # fallback to cp + chmod if install(1) is not available or fails
    cp "$src" "$dest"
    chmod +x "$dest"
  }

  # Clean up temp file if used
  [[ -n "${tmp:-}" && -f "${tmp:-}" ]] && rm -f "$tmp" || true

  # PATH guidance
  if in_path_dir "$bin_dir"; then
    echo "[install] Success. Run: $name --help"
  else
    echo "[install] Success, but $bin_dir is not on your PATH."
    echo "[install] Add it to your shell config, e.g.:"
    if [[ "${SHELL:-}" == *"zsh"* ]]; then
      echo "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    elif [[ "${SHELL:-}" == *"bash"* ]]; then
      echo "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
    else
      echo "  export PATH=\"$bin_dir:\$PATH\"  # add this to your shell profile"
    fi
  fi
}

main "$@"
