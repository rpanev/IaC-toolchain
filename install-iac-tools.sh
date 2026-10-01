#!/usr/bin/env bash
# =============================================================================
# install-iac-tools.sh - install the IaC toolchain used by the Makefile
#
# Also installs prerequisites: GNU make (>= 3.82), curl, unzip, tar, git
#
# Platforms: macOS (Homebrew), Debian/Ubuntu, RHEL/Rocky/Alma/CentOS/Fedora/Amazon Linux
# Arch:      amd64, arm64
#
# Linux: official release binaries from GitHub / releases.hashicorp.com,
#        every download is verified with SHA256 before install.
#        checkov goes into an isolated venv (/opt/checkov) + symlink.
# macOS: Homebrew (terraform via hashicorp/tap).
#
# Usage:
#   ./install-iac-tools.sh                      # install everything missing
#   ./install-iac-tools.sh --only trivy,checkov
#   ./install-iac-tools.sh --skip tofu,infracost
#   ./install-iac-tools.sh --check              # show outdated tools, change nothing
#   ./install-iac-tools.sh --update             # upgrade outdated + install missing
#   ./install-iac-tools.sh --update --only trivy
#   ./install-iac-tools.sh --force              # reinstall everything selected
#   ./install-iac-tools.sh --dry-run
#
# --check exit codes: 0 = all up to date, 2 = updates available
#
# Pin versions via env:  TRIVY_VERSION=0.58.1 TERRAFORM_VERSION=1.9.8 ./install-iac-tools.sh
# Other env:             INSTALL_DIR=/usr/local/bin  CHECKOV_VENV=/opt/checkov
#
# Terraform and OpenTofu are alternatives. When both are selected the script
# asks which one to install. Non-interactive: --engine terraform|tofu
# or IAC_ENGINE=terraform|tofu.
# =============================================================================
set -euo pipefail

ALL_TOOLS=(terraform tofu tflint terraform-docs trivy checkov conftest gitleaks infracost)
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CHECKOV_VENV="${CHECKOV_VENV:-/opt/checkov}"
FORCE=false
DRY_RUN=false
MODE=install   # install | update | check
ONLY=""
SKIP=""
ENGINE="${IAC_ENGINE:-}"

# ------------------------------------------------------------------ output ---
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi
log()  { printf '%s+ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%s! %s%s\n' "$YELLOW" "$*" "$RESET" >&2; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

usage() {
  sed -n '3,/^# =====/p' "$0" | sed '$d; s/^# \{0,1\}//'
  printf '\nTools: %s\n' "${ALL_TOOLS[*]}"
}

# -------------------------------------------------------------------- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--only)    ONLY="${2:?--only needs a list}"; shift 2 ;;
    -s|--skip)    SKIP="${2:?--skip needs a list}"; shift 2 ;;
    -e|--engine)  ENGINE="${2:?--engine needs terraform or tofu}"; shift 2 ;;
    -f|--force)   FORCE=true; shift ;;
    -u|--update)  MODE=update; shift ;;
    -c|--check)   MODE=check; shift ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -l|--list)    printf '%s\n' "${ALL_TOOLS[@]}"; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "Unknown option: $1 (see --help)" ;;
  esac
done

in_list() { [[ ",$2," == *",$1,"* ]]; }

TOOLS=()
for t in "${ALL_TOOLS[@]}"; do
  if [[ -n "$ONLY" ]] && ! in_list "$t" "$ONLY"; then continue; fi
  if [[ -n "$SKIP" ]] && in_list "$t" "$SKIP"; then continue; fi
  TOOLS+=("$t")
done
for t in ${ONLY//,/ } ${SKIP//,/ }; do
  in_list "$t" "$(IFS=,; echo "${ALL_TOOLS[*]}")" || die "Unknown tool: $t"
done
[[ ${#TOOLS[@]} -gt 0 ]] || die "Nothing to install"

# ---------------------------------------------------------------- helpers ---
run() {
  if $DRY_RUN; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}

as_root() {
  if [[ $EUID -eq 0 ]]; then run "$@"
  elif command -v sudo >/dev/null 2>&1; then run sudo "$@"
  else die "Need root or sudo for: $*"
  fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fetch() {  # url dest
  curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" || die "Download failed: $1"
}

# Latest tag via redirect (no GitHub API rate limit)
latest_tag() {
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")" \
    || die "Cannot resolve latest release of $1"
  printf '%s\n' "${url##*/}"
}

# Env override: trivy -> TRIVY_VERSION, terraform-docs -> TERRAFORM_DOCS_VERSION
pinned_version() {
  local var
  var="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')_VERSION"
  printf '%s' "${!var:-}"
}

# Resolve tag for a GitHub repo, honouring pins (with or without leading v)
gh_tag() {  # tool repo
  local pin; pin="$(pinned_version "$1")"
  if [[ -n "$pin" ]]; then printf 'v%s\n' "${pin#v}"
  elif $DRY_RUN; then printf 'vLATEST\n'
  else latest_tag "$2"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_sha256() {  # file sums_file
  local name expected actual
  name="$(basename "$1")"
  expected="$(awk -v n="$name" '{f=$2; sub(/^\*/, "", f)} f==n {print $1; exit}' "$2")"
  if [[ -z "$expected" && "$(wc -l < "$2")" -le 1 ]]; then
    expected="$(awk '{print $1; exit}' "$2")"
  fi
  [[ -n "$expected" ]] || die "No checksum entry for $name"
  actual="$(sha256_of "$1")"
  [[ "$expected" == "$actual" ]] || die "Checksum mismatch for $name"
  log "  sha256 OK ($name)"
}

# Download archive + checksums, verify, extract, install binary
install_binary() {  # bin url sums_url
  local bin=$1 url=$2 sums=$3 asset dir file
  asset="${url##*/}"
  log "  $url"
  if $DRY_RUN; then
    printf '    [dry-run] verify sha256 + install %s/%s\n' "$INSTALL_DIR" "$bin"
    return 0
  fi
  dir="$TMP_ROOT/$bin"; mkdir -p "$dir/x"
  fetch "$url" "$dir/$asset"
  fetch "$sums" "$dir/SUMS"
  verify_sha256 "$dir/$asset" "$dir/SUMS"
  case "$asset" in
    *.zip)           unzip -q -o "$dir/$asset" -d "$dir/x" ;;
    *.tar.gz|*.tgz)  tar -xzf "$dir/$asset" -C "$dir/x" ;;
    *)               die "Unknown archive type: $asset" ;;
  esac
  file="$(find "$dir/x" -type f \( -name "$bin" -o -name "$bin-*" \) -print -quit)"
  [[ -n "$file" ]] || die "Binary $bin not found in $asset"
  as_root install -d "$INSTALL_DIR"
  as_root install -m 0755 "$file" "$INSTALL_DIR/$bin"
}

# --------------------------------------------------------------- platform ---
OS="$(uname -s)"
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

PM=""
case "$OS" in
  Darwin)
    PLATFORM=macos; PM=brew
    [[ $EUID -ne 0 ]] || die "Do not run as root on macOS (Homebrew refuses root)"
    command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it first: https://brew.sh"
    ;;
  Linux)
    [[ -r /etc/os-release ]] || die "Cannot detect distro (/etc/os-release missing)"
    # shellcheck disable=SC1091
    . /etc/os-release
    PLATFORM=""
    for id in ${ID:-} ${ID_LIKE:-}; do
      case "$id" in
        debian|ubuntu) PLATFORM=debian; PM=apt; break ;;
        rhel|centos|fedora|rocky|almalinux|amzn|ol) PLATFORM=rhel; break ;;
      esac
    done
    [[ -n "$PLATFORM" ]] || die "Unsupported distro: ${PRETTY_NAME:-$ID}"
    if [[ "$PLATFORM" == rhel ]]; then
      if command -v dnf >/dev/null 2>&1; then PM=dnf; else PM=yum; fi
    fi
    ;;
  *) die "Unsupported OS: $OS" ;;
esac

APT_UPDATED=false
# apt-get update warnings usually come from third-party repos already on the
# system (expired/rotated keys etc.) - report them clearly but keep going
apt_update() {
  local out
  if $DRY_RUN; then run apt-get update -qq; return 0; fi
  if ! out="$(as_root apt-get update -qq 2>&1)"; then
    printf '%s\n' "$out" >&2
    die "apt-get update failed"
  fi
  if [[ -n "$out" ]]; then
    warn "apt-get update reported problems with existing repos (not caused by this script):"
    printf '%s\n' "$out" | grep -E '^(W|E):' | grep -oE 'https?://[^ ]+' \
      | awk -F/ '{print "    - " $3}' | sort -u >&2 || true
    warn "Continuing - fix those repos separately (see: apt-get update)"
  fi
}

pkg_install() {
  [[ $# -gt 0 ]] || return 0
  case "$PM" in
    apt)
      if ! $APT_UPDATED; then apt_update; APT_UPDATED=true; fi
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
      ;;
    dnf|yum) as_root "$PM" install -y -q "$@" ;;
    brew)    run brew install "$@" ;;
  esac
}

# ------------------------------------------------------------ prerequisites ---
# GNU make >= 3.82 is required (.SHELLFLAGS). macOS ships 3.81 -> brew 'make' (gmake)
make_ok() {
  local bin=${1:-make} v
  command -v "$bin" >/dev/null 2>&1 || return 1
  v="$("$bin" --version 2>/dev/null | sed -n '1s/^GNU Make \([0-9][0-9.]*\).*/\1/p')"
  [[ -n "$v" ]] || return 1
  [[ "$(printf '%s\n3.82\n' "$v" | sort -t. -k1,1n -k2,2n | head -n1)" == "3.82" ]]
}

install_make_macos() {
  if make_ok make; then return 0; fi
  if ! make_ok gmake; then
    log "Installing GNU make (system make is too old)"
    run brew install make
  fi
  GNUBIN="$(brew --prefix 2>/dev/null)/opt/make/libexec/gnubin"
  case ":$PATH:" in
    *":$GNUBIN:"*) ;;
    *) MAKE_PATH_HINT=true ;;
  esac
}

install_prereqs() {
  local pkgs=() c
  if [[ "$PLATFORM" == macos ]]; then
    install_make_macos
    return 0
  fi
  if command -v make >/dev/null 2>&1 && ! make_ok make; then
    warn "Installed make is older than 3.82 - upgrade it via your package manager"
  fi
  for c in curl unzip tar git make; do
    command -v "$c" >/dev/null 2>&1 || pkgs+=("$c")
  done
  if [[ "$PM" == apt && ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    pkgs+=(ca-certificates)
  fi
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    log "Installing prerequisites: ${pkgs[*]}"
    pkg_install "${pkgs[@]}"
  fi
}

# Python >= 3.9 with working venv
find_python() {
  local p
  for p in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
    command -v "$p" >/dev/null 2>&1 || continue
    if "$p" -c 'import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
      command -v "$p"; return 0
    fi
  done
  return 1
}

ensure_python() {
  find_python >/dev/null && return 0
  log "Installing Python (>= 3.9 + venv) for checkov"
  case "$PM" in
    apt)     pkg_install python3 python3-venv ;;
    dnf|yum) pkg_install python3.11 2>/dev/null || pkg_install python3 ;;
  esac
  $DRY_RUN && return 0
  find_python >/dev/null || die "No Python >= 3.9 with venv available - install it manually"
}

# ------------------------------------------------------------------ tools ---
install_macos() {
  local formula=$1
  case "$1" in
    terraform) formula=hashicorp/tap/terraform ;;
    tofu)      formula=opentofu ;;
  esac
  if $FORCE && brew list --formula "${formula##*/}" >/dev/null 2>&1; then
    run brew upgrade "$formula" || true
  else
    run brew install "$formula"
  fi
}

install_terraform() {
  local v base
  v="$(pinned_version terraform)"
  if [[ -z "$v" ]]; then
    if $DRY_RUN; then v=LATEST
    else
      v="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform \
        | sed -n 's/.*"current_version":"\([^"]*\)".*/\1/p')"
      [[ -n "$v" ]] || die "Cannot resolve latest terraform version"
    fi
  fi
  v="${v#v}"
  base="https://releases.hashicorp.com/terraform/$v"
  install_binary terraform "$base/terraform_${v}_linux_${ARCH}.zip" "$base/terraform_${v}_SHA256SUMS"
}

install_tofu() {
  local tag v r=opentofu/opentofu
  tag="$(gh_tag tofu $r)"; v="${tag#v}"
  install_binary tofu \
    "https://github.com/$r/releases/download/$tag/tofu_${v}_linux_${ARCH}.tar.gz" \
    "https://github.com/$r/releases/download/$tag/tofu_${v}_SHA256SUMS"
}

install_tflint() {
  local tag r=terraform-linters/tflint
  tag="$(gh_tag tflint $r)"
  install_binary tflint \
    "https://github.com/$r/releases/download/$tag/tflint_linux_${ARCH}.zip" \
    "https://github.com/$r/releases/download/$tag/checksums.txt"
}

install_terraform_docs() {
  # Keep the assignment of r on its own line. A single `local` expands every
  # word before it runs, so `local r=... tag="$(cmd $r)"` sees r as unset
  # (set -u) and the release tag comes out empty.
  local tag r=terraform-docs/terraform-docs
  tag="$(gh_tag terraform-docs "$r")"
  [[ -n "$tag" && "$tag" != v ]] || die "Cannot resolve terraform-docs version"
  install_binary terraform-docs \
    "https://github.com/$r/releases/download/$tag/terraform-docs-${tag}-linux-${ARCH}.tar.gz" \
    "https://github.com/$r/releases/download/$tag/terraform-docs-${tag}.sha256sum"
}

install_trivy() {
  local tag v a r=aquasecurity/trivy
  tag="$(gh_tag trivy $r)"; v="${tag#v}"
  [[ "$ARCH" == amd64 ]] && a=64bit || a=ARM64
  install_binary trivy \
    "https://github.com/$r/releases/download/$tag/trivy_${v}_Linux-${a}.tar.gz" \
    "https://github.com/$r/releases/download/$tag/trivy_${v}_checksums.txt"
}

install_conftest() {
  local tag v a r=open-policy-agent/conftest
  tag="$(gh_tag conftest $r)"; v="${tag#v}"
  [[ "$ARCH" == amd64 ]] && a=x86_64 || a=arm64
  install_binary conftest \
    "https://github.com/$r/releases/download/$tag/conftest_${v}_Linux_${a}.tar.gz" \
    "https://github.com/$r/releases/download/$tag/checksums.txt"
}

install_gitleaks() {
  local tag v a r=gitleaks/gitleaks
  tag="$(gh_tag gitleaks $r)"; v="${tag#v}"
  [[ "$ARCH" == amd64 ]] && a=x64 || a=arm64
  install_binary gitleaks \
    "https://github.com/$r/releases/download/$tag/gitleaks_${v}_linux_${a}.tar.gz" \
    "https://github.com/$r/releases/download/$tag/gitleaks_${v}_checksums.txt"
}

install_infracost() {
  # v2 line lives in infracost/cli (infracost/infracost = legacy 0.x, security fixes only)
  local tag asset r=infracost/cli
  tag="$(gh_tag infracost $r)"
  asset="infracost-linux-${ARCH}.tar.gz"
  install_binary infracost \
    "https://github.com/$r/releases/download/$tag/$asset" \
    "https://github.com/$r/releases/download/$tag/$asset.sha256"
}

install_checkov() {
  local py pin spec=checkov
  ensure_python
  py="$(find_python || echo python3)"
  pin="$(pinned_version checkov)"
  [[ -n "$pin" ]] && spec="checkov==${pin#v}"
  log "  venv $CHECKOV_VENV ($py) -> $spec"
  as_root "$py" -m venv "$CHECKOV_VENV"
  as_root "$CHECKOV_VENV/bin/pip" install -q --upgrade pip
  as_root "$CHECKOV_VENV/bin/pip" install -q --upgrade "$spec"
  as_root install -d "$INSTALL_DIR"
  as_root ln -sf "$CHECKOV_VENV/bin/checkov" "$INSTALL_DIR/checkov"
  $DRY_RUN && return 0
  fix_numpy_cpu
  "$CHECKOV_VENV/bin/checkov" --version >/dev/null 2>&1 \
    || die "checkov is installed but fails to start - run: $CHECKOV_VENV/bin/checkov --version"
}

# x86-64-v2 = SSE4.2/POPCNT/SSSE3/CX16. Missing on VMs with generic CPU models
# (Proxmox kvm64/qemu64, some old hypervisors).
cpu_has_x86_v2() {
  [[ "$ARCH" == amd64 && -r /proc/cpuinfo ]] || return 0
  local flags f
  flags=" $(grep -m1 '^flags' /proc/cpuinfo) "
  for f in cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; do
    [[ "$flags" == *" $f "* ]] || return 1
  done
}

# Newest NumPy wheels require x86-64-v2. If NumPy can't load, step back to
# older binary wheels until one works on this CPU.
fix_numpy_cpu() {
  local py="$CHECKOV_VENV/bin/python" np
  local test='import importlib.util as u
if u.find_spec("numpy"): import numpy'
  "$py" -c "$test" >/dev/null 2>&1 && return 0
  cpu_has_x86_v2 || warn "CPU lacks x86-64-v2 (generic VM CPU model?) - pinning an older NumPy"
  for np in "numpy<2.4" "numpy<2.3" "numpy<2.2" "numpy<2.1"; do
    log "  trying $np"
    as_root "$CHECKOV_VENV/bin/pip" install -q --only-binary=:all: "$np" >/dev/null 2>&1 || continue
    if "$py" -c "$test" >/dev/null 2>&1; then
      log "  NumPy works with $np"
      return 0
    fi
  done
  die "No NumPy build works on this CPU - set the VM CPU type to 'host' (or x86-64-v2+)"
}

install_tool() {
  if [[ "$PLATFORM" == macos ]]; then install_macos "$1"; return; fi
  case "$1" in
    terraform)      install_terraform ;;
    tofu)           install_tofu ;;
    tflint)         install_tflint ;;
    terraform-docs) install_terraform_docs ;;
    trivy)          install_trivy ;;
    checkov)        install_checkov ;;
    conftest)       install_conftest ;;
    gitleaks)       install_gitleaks ;;
    infracost)      install_infracost ;;
  esac
}

tool_version() {
  "$1" --version 2>&1 | sed -n 1p || true
}

# Installed AND actually starts (catches broken venvs, wrong-arch binaries...)
tool_works() {
  command -v "$1" >/dev/null 2>&1 && "$1" --version >/dev/null 2>&1
}

# --------------------------------------------------------- version check ---
# Installed version as plain x.y.z
current_version() {
  "$1" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p || true
}

tool_repo() {
  case "$1" in
    tofu)           echo opentofu/opentofu ;;
    tflint)         echo terraform-linters/tflint ;;
    terraform-docs) echo terraform-docs/terraform-docs ;;
    trivy)          echo aquasecurity/trivy ;;
    conftest)       echo open-policy-agent/conftest ;;
    gitleaks)       echo gitleaks/gitleaks ;;
    infracost)      echo infracost/cli ;;
  esac
}

# Target version (pin if set, else latest) as plain x.y.z
latest_version() {
  local pin v py
  pin="$(pinned_version "$1")"
  if [[ -n "$pin" ]]; then printf '%s\n' "${pin#v}"; return 0; fi
  case "$1" in
    terraform)
      v="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform \
        | sed -n 's/.*"current_version":"\([^"]*\)".*/\1/p')" ;;
    checkov)
      py="$(find_python || command -v python3 || true)"
      [[ -n "$py" ]] || return 1
      v="$(curl -fsSL https://pypi.org/pypi/checkov/json \
        | "$py" -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])')" ;;
    *)
      v="$(latest_tag "$(tool_repo "$1")")"; v="${v#v}" ;;
  esac
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# true if $1 >= $2
version_ge() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

pin_env() {  # tool version -> export TOOL_VERSION so installers use it
  local var
  var="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')_VERSION"
  export "$var=$2"
}

# Warn if another copy of the tool shadows (or is shadowed by) INSTALL_DIR
check_shadow() {
  local found
  hash -r
  found="$(command -v "$1" 2>/dev/null || true)"
  [[ "$PLATFORM" == macos || -z "$found" ]] && return 0
  if [[ -e "$INSTALL_DIR/$1" && "$found" != "$INSTALL_DIR/$1" ]]; then
    warn "$1: $found is used before $INSTALL_DIR/$1 - remove the other copy (e.g. apt/dnf package)"
  fi
}

# ------------------------------------------------------------ macOS brew ---
brew_formula() {
  case "$1" in
    terraform) echo hashicorp/tap/terraform ;;
    tofu)      echo opentofu ;;
    *)         echo "$1" ;;
  esac
}

brew_process() {  # tool
  local f name
  f="$(brew_formula "$1")"; name="${f##*/}"
  if ! command -v "$1" >/dev/null 2>&1; then
    if [[ "$MODE" == check ]]; then
      printf '%s+ %-15s missing%s\n' "$YELLOW" "$1" "$RESET"; OUTDATED+=("$1"); return 0
    fi
    log "Installing $1"; run brew install "$f"; return
  fi
  if ! brew list --formula "$name" >/dev/null 2>&1; then
    warn "$1 is installed outside Homebrew ($(command -v "$1")) - skipping"; return 0
  fi
  if [[ -n "$(brew outdated --formula --quiet "$name" 2>/dev/null)" ]]; then
    printf '%s↑ %-15s %s -> newer available%s\n' "$YELLOW" "$1" "$(current_version "$1")" "$RESET"
    OUTDATED+=("$1")
    [[ "$MODE" == update ]] && run brew upgrade "$f"
  else
    printf '= %-15s %s (up to date)\n' "$1" "$(current_version "$1")"
  fi
  return 0
}

# ------------------------------------------------------------ Linux flow ---
update_process() {  # tool
  local t=$1 cur latest
  if ! latest="$(latest_version "$t")"; then
    warn "Cannot resolve latest version of $t"; return 1
  fi
  if command -v "$t" >/dev/null 2>&1 && ! tool_works "$t"; then
    printf '%s! %-15s broken -> reinstall %s%s\n' "$YELLOW" "$t" "$latest" "$RESET"
  elif command -v "$t" >/dev/null 2>&1; then
    cur="$(current_version "$t")"
    if [[ -n "$cur" ]] && version_ge "$cur" "$latest"; then
      printf '= %-15s %s (up to date)\n' "$t" "$cur"
      return 0
    fi
    printf '%s↑ %-15s %s -> %s%s\n' "$YELLOW" "$t" "${cur:-unknown}" "$latest" "$RESET"
  else
    printf '%s+ %-15s missing -> %s%s\n' "$YELLOW" "$t" "$latest" "$RESET"
  fi
  OUTDATED+=("$t")
  [[ "$MODE" == check ]] && return 0
  pin_env "$t" "$latest"
  ( install_tool "$t" ) || return 1
  check_shadow "$t"
}

# Terraform and OpenTofu install the same providers. Ask when both are selected.
drop_tool() {
  local keep=() t
  for t in "${TOOLS[@]}"; do
    [[ "$t" == "$1" ]] || keep+=("$t")
  done
  TOOLS=("${keep[@]}")
}

choose_engine() {
  local listed choice other
  listed="$(IFS=,; echo "${TOOLS[*]}")"
  in_list terraform "$listed" && in_list tofu "$listed" || return 0

  if [[ -n "$ENGINE" ]]; then
    choice="$ENGINE"
  elif [[ -t 0 ]]; then
    printf 'Terraform and OpenTofu are alternatives. Install one:\n'
    printf '  1) terraform\n'
    printf '  2) tofu (OpenTofu)\n'
    printf 'Choice [1]: '
    IFS= read -r choice || choice=""
  else
    die "Both terraform and tofu are selected. Pass --engine terraform|tofu (or set IAC_ENGINE)."
  fi

  choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$choice" in
    ""|1|terraform|tf) choice=terraform; other=tofu ;;
    2|tofu|opentofu)    choice=tofu; other=terraform ;;
    *) die "Unknown engine: ${ENGINE:-$choice} (expected terraform or tofu)" ;;
  esac
  drop_tool "$other"
  log "Engine: $choice (skipping $other)"
  if command -v "$other" >/dev/null 2>&1; then
    warn "$other is already installed ($(command -v "$other")). The Makefile uses terraform when both are on PATH."
  fi
}

# ------------------------------------------------------------------- main ---
choose_engine

printf '%sIaC tools installer%s  platform=%s pm=%s arch=%s%s\n' \
  "$BOLD" "$RESET" "$PLATFORM" "$PM" "$ARCH" "$($DRY_RUN && echo ' (dry-run)')"
printf 'Mode: %s   Tools: %s\n\n' "$MODE" "${TOOLS[*]}"

MAKE_PATH_HINT=false
GNUBIN=""
FAILED=()
OUTDATED=()

[[ "$MODE" == check ]] || install_prereqs

if [[ "$PLATFORM" == macos && "$MODE" != install ]]; then
  log "Updating Homebrew index"
  if [[ "$MODE" == check ]]; then brew update --quiet >/dev/null; else run brew update --quiet; fi
fi

for t in "${TOOLS[@]}"; do
  if [[ "$MODE" == install ]]; then
    if tool_works "$t" && ! $FORCE; then
      printf '%s= %-15s already installed: %s%s\n' "$BOLD" "$t" "$(tool_version "$t")" "$RESET"
      continue
    fi
    if command -v "$t" >/dev/null 2>&1 && ! tool_works "$t"; then
      warn "$t is installed but broken ($t --version fails) - reinstalling"
    fi
    log "Installing $t"
    if ( install_tool "$t" ); then check_shadow "$t"; else warn "Failed to install $t"; FAILED+=("$t"); fi
  elif [[ "$PLATFORM" == macos ]]; then
    brew_process "$t" || { warn "Failed: $t"; FAILED+=("$t"); }
  else
    update_process "$t" || { warn "Failed: $t"; FAILED+=("$t"); }
  fi
done

# ----------------------------------------------------------- check mode ---
if [[ "$MODE" == check ]]; then
  echo
  if [[ ${#FAILED[@]} -gt 0 ]]; then warn "Could not check: ${FAILED[*]}"; fi
  if [[ ${#OUTDATED[@]} -gt 0 ]]; then
    printf '%s%d update(s) available:%s %s\n' "$YELLOW" "${#OUTDATED[@]}" "$RESET" "${OUTDATED[*]}"
    printf 'Run: %s --update\n' "$0"
    exit 2
  fi
  log "All tools are up to date"
  exit 0
fi

# --------------------------------------------------------------- summary ---
printf '\n%sSummary%s\n' "$BOLD" "$RESET"
if make_ok make; then
  printf '  %s✓%s %-15s %s\n' "$GREEN" "$RESET" "make" "$(make --version | head -n1)"
elif make_ok gmake; then
  printf '  %s✓%s %-15s %s\n' "$GREEN" "$RESET" "make (gmake)" "$(gmake --version | head -n1)"
elif $DRY_RUN; then
  printf '  %s-%s %-15s %s\n' "$YELLOW" "$RESET" "make" "would be installed"
else
  printf '  %s✗%s %-15s %s\n' "$RED" "$RESET" "make" "GNU make >= 3.82 not found"
fi
for t in "${TOOLS[@]}"; do
  if tool_works "$t"; then
    printf '  %s✓%s %-15s %s\n' "$GREEN" "$RESET" "$t" "$(tool_version "$t")"
  elif command -v "$t" >/dev/null 2>&1; then
    printf '  %s✗%s %-15s %s\n' "$RED" "$RESET" "$t" "broken - run: $t --version"
    $DRY_RUN || FAILED+=("$t")
  else
    printf '  %s✗%s %-15s %s\n' "$RED" "$RESET" "$t" "not installed"
  fi
done

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) warn "$INSTALL_DIR is not in PATH - add it to your shell profile" ;;
esac

if in_list infracost "$(IFS=,; echo "${TOOLS[*]}")" && command -v infracost >/dev/null 2>&1; then
  printf '\nNote: infracost v2 needs a login: run "infracost auth login" (no browser: add --oauth-use-device-flow)\n'
  printf '      CI/CD: export INFRACOST_CLI_AUTHENTICATION_TOKEN=<service account or personal token>\n'
fi

if $MAKE_PATH_HINT; then
  printf '\nNote: to use GNU make as "make" (instead of "gmake") add to ~/.zshrc or ~/.bashrc:\n'
  printf '  export PATH="%s:$PATH"\n' "$GNUBIN"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  die "Failed: ${FAILED[*]}"
fi
log "Done"
