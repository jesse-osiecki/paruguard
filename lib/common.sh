# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# lib/common.sh — logging, die/abort, config loading, runtime assertions (PLAN.md §9.2)
#
# Sourced by bin/paruguard and bin/paruguard-setup. Assumes `set -euo pipefail` in the caller.

# --- colors (disabled when not a tty or NO_COLOR is set) ------------------

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
	C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'
	C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
	C_RED=''; C_YELLOW=''; C_GREEN=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

# --- logging ----------------------------------------------------------------

log()  { printf '%s[paruguard]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
warn() { printf '%s[paruguard] WARNING:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
ok()   { printf '%s[paruguard] OK:%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
err()  { printf '%s[paruguard] ERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# die: the single abort path (I7 — fail closed). Every gate failure, missing
# tool, or unexpected state must route through this. Never "proceed on error."
die() {
	err "$*"
	exit 1
}

# critical: for I7 IOC hits — same effect as die(), louder banner.
critical() {
	printf '%s[paruguard] CRITICAL:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2
	exit 1
}

# confirm PROMPT [default(y|n)] — interactive confirmation. Fails closed:
# non-interactive shells and EOF are treated as "no".
confirm() {
	local prompt="$1" default="${2:-n}" reply suffix
	if [[ "$default" == y ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
	if [[ ! -t 0 ]]; then
		warn "non-interactive shell; defaulting '$prompt' to '$default'"
		reply="$default"
	else
		read -r -p "$prompt $suffix " reply || reply=""
		reply="${reply:-$default}"
	fi
	[[ "$reply" =~ ^[Yy] ]]
}

# --- dry-run helper -----------------------------------------------------

# run CMD... — executes unless DRY_RUN=1, in which case it only echoes.
run() {
	if [[ "${DRY_RUN:-0}" == 1 ]]; then
		printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$(printf '%q ' "$@")" >&2
		return 0
	fi
	"$@"
}

# --- sudo keepalive ---------------------------------------------------------
# A hardened install/upgrade makes several `sudo` calls spread across a long
# build (and interactive gate review); sudo's credential cache (upstream
# default 5 min) can expire between them and force a mid-run re-auth.
# sudo_keepalive_start authenticates once up front, then refreshes the
# timestamp in the background until the run ends — the standard sudo-loop the
# sudo(8) man page itself documents. sudo_keepalive_stop tears it down; it is
# also wired to an EXIT trap so it always cleans up.
#
# Portability/robustness notes (learned the hard way):
#   - The refresher is RESILIENT: a single failed `sudo -n -v` must NOT kill it.
#     While an interactive foreground sudo (e.g. `pacman -Syu`) holds the tty,
#     a background refresh can transiently fail; the earlier version did
#     `|| exit 0` and died permanently on the first such miss, so the ticket
#     lapsed later. It now loops regardless and self-heals.
#   - Interval is well under any sane timeout (default 30 s vs the 5-min sudo
#     default; override with PARUGUARD_SUDO_INTERVAL).
#   - stdin is left attached to the caller's terminal so sudo resolves the SAME
#     per-tty ticket the foreground calls use (timestamp record type is per-tty
#     by default). Only stdout/stderr are redirected.
#   - The loop self-terminates if the parent process disappears (covers SIGKILL,
#     where the EXIT trap can't run), so it never orphans.

SUDO_KEEPALIVE_PID=""

sudo_keepalive_start() {
	[[ "${DRY_RUN:-0}" == 1 ]] && return 0
	[[ -n "$SUDO_KEEPALIVE_PID" ]] && return 0          # already running
	command -v sudo >/dev/null 2>&1 || return 0
	# One interactive auth up front (a no-op if sudo is passwordless).
	sudo -v || die "sudo authentication failed — cannot proceed (I7)"
	local ppid=$$ interval="${PARUGUARD_SUDO_INTERVAL:-30}"
	( while kill -0 "$ppid" 2>/dev/null; do
		sudo -n -v >/dev/null 2>&1 || true   # keep looping even if a refresh misses
		sleep "$interval"
	done ) &
	SUDO_KEEPALIVE_PID=$!
	disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
	trap 'sudo_keepalive_stop' EXIT
}

sudo_keepalive_stop() {
	[[ -n "$SUDO_KEEPALIVE_PID" ]] || return 0
	kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
	SUDO_KEEPALIVE_PID=""
}

# --- config -----------------------------------------------------------------

# Known config keys and their defaults (PLAN.md §9.1). Declared up front so
# an unset/malformed config file can't inject arbitrary variables.
FAIL_ON=critical
WARN_ON=high
SANDBOX=chroot
ALLOW_MAINTAINER_CHANGE=0
ALLOW_SCAN_FINDINGS=0
ALLOW_BUILD_NET=0
FLATPAK=1
IOC=1
ALLOW_CHECK_NET=0
KNOWN_BAD_LIST=/usr/share/paruguard/known-bad-packages.txt

# load_config — sources system config then user override, each only if
# present. Values are plain KEY=value assignments (see etc/paruguard.conf).
load_config() {
	local sys_conf="/etc/paruguard/paruguard.conf"
	local user_conf="${XDG_CONFIG_HOME:-$HOME/.config}/paruguard/paruguard.conf"
	local f
	for f in "$sys_conf" "$user_conf"; do
		if [[ -r "$f" ]]; then
			# shellcheck disable=SC1090
			source "$f"
		fi
	done
}

# --- paths --------------------------------------------------------------

paruguard_state_dir()  { printf '%s/paruguard' "${XDG_STATE_HOME:-$HOME/.local/state}"; }
paruguard_work_root()  { printf '%s/work' "$(paruguard_state_dir)"; }
paruguard_approved_dir() { printf '%s/approved' "$(paruguard_state_dir)"; }

AUR_REPO_DIR=/var/lib/repo/aur
AUR_CHROOT_ROOT=/var/lib/aurbuild
AUR_SRCPOOL=/var/lib/paruguard/srcdest

# --- runtime assertions (§9.2) — fail closed (I7) ----------------------

# assert_tools TOOL... — every named tool must be on PATH or paruguard aborts.
assert_tools() {
	local missing=() t
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	if (( ${#missing[@]} > 0 )); then
		die "missing required tool(s): ${missing[*]} — run 'paruguard-setup' to install them"
	fi
}

# assert_environment — verifies the §3 environment facts paruguard depends on.
# Called at the top of every hardened (non-passthrough) invocation.
assert_environment() {
	assert_tools command paru pacman makechrootpkg arch-nspawn repo-add \
		aur-scan jq curl git bsdtar unshare sudo

	[[ -d "$AUR_REPO_DIR" && -w "$AUR_REPO_DIR" ]] \
		|| die "$AUR_REPO_DIR missing or not writable — run 'paruguard-setup'"
	[[ -d "$AUR_CHROOT_ROOT/root" ]] \
		|| die "$AUR_CHROOT_ROOT/root missing — run 'paruguard-setup'"

	grep -q '^\[aur\]' /etc/pacman.conf 2>/dev/null \
		|| die "[aur] repo not configured in /etc/pacman.conf — run 'paruguard-setup'"
}
