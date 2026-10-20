#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/run.sh — acceptance tests for PLAN.md §11.
#
# Two tiers:
#   fast (default) — tests 1, 2, 3, 8, 10-13. Pure functions / read-only checks,
#                     no sudo, no chroot builds, no package installs. Safe to
#                     run anytime, including on the machine paruguard manages.
#   live (--live)   — tests 4, 5, 6, 7, 9. Exercise the REAL chroot build,
#                      REAL `pacman -U`/`pacman -S` install, and (for test 9)
#                      REAL `paruguard-setup`. These need interactive sudo and
#                      mutate real system state (a scratch chroot copy, a
#                      throwaway installed test package, possibly
#                      /etc/pacman.conf and ~/.config/paru/paru.conf). Only
#                      run --live deliberately, on a machine you're OK with
#                      paruguard-setup touching.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")

# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/gate.sh
source "$REPO_ROOT/lib/gate.sh"

LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

# isolate test state from the real ~/.local/state/paruguard
export XDG_STATE_HOME
XDG_STATE_HOME=$(mktemp -d)
trap 'rm -rf "$XDG_STATE_HOME"' EXIT

PASS=0
FAIL=0
SKIP=0

report() {
	local name="$1" rc="$2" detail="${3:-}"
	if (( rc == 0 )); then
		printf '  PASS  %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf '  FAIL  %s%s\n' "$name" "${detail:+ — $detail}"
		FAIL=$((FAIL + 1))
	fi
}
skip() {
	printf '  SKIP  %s — %s\n' "$1" "$2"
	SKIP=$((SKIP + 1))
}

fixtures="$SCRIPT_DIR/fixtures"

# --- test 1: static gate blocks -----------------------------------------
test_1_static_gate_blocks() {
	local dir="$fixtures/dle-001-curl-pipe-bash"
	if ! command -v aur-scan >/dev/null 2>&1; then
		skip "1 static-gate-blocks" "aur-scan not on PATH"
		return
	fi
	if aur-scan scan "$dir" --fail-on critical >/tmp/paruguard-test-1.out 2>&1; then
		report "1 static-gate-blocks" 1 "aur-scan exited 0 on a curl|bash fixture (expected non-zero)"
	else
		report "1 static-gate-blocks" 0
	fi
}

# --- test 2: .install addition escalates --------------------------------
test_2_install_escalates() {
	local repo
	repo=$(mktemp -d)
	trap 'rm -rf "$repo"' RETURN

	cp "$fixtures/install-003-network-scriptlet/v1/PKGBUILD" "$repo/"
	( cd "$repo" && git init -q && git -c user.email=t@t -c user.name=t add -A \
		&& git -c user.email=t@t -c user.name=t commit -q -m v1 )
	local approved_commit
	approved_commit=$(git -C "$repo" rev-parse HEAD)

	cp "$fixtures/install-003-network-scriptlet/v2/PKGBUILD" "$repo/"
	cp "$fixtures/install-003-network-scriptlet/v2/"*.install "$repo/"
	( cd "$repo" && git -c user.email=t@t -c user.name=t add -A \
		&& git -c user.email=t@t -c user.name=t commit -q -m v2 )

	mkdir -p "$(paruguard_approved_dir)/paruguard-test-install-003"
	printf '%s\n' "$approved_commit" > "$(paruguard_approved_dir)/paruguard-test-install-003/commit"

	local out rc=0
	out=$( ( gate_diff "paruguard-test-install-003" "$repo" ) < /dev/null 2>&1 ) || rc=$?
	if (( rc != 0 )) && grep -q 'ESCALATED' <<<"$out" && grep -qi 'install scriptlet' <<<"$out"; then
		report "2 install-addition-escalates" 0
	else
		report "2 install-addition-escalates" 1 "escalation not detected or gate did not fail-closed on default-No; output: $(tail -3 <<<"$out")"
	fi
}

# --- test 3: maintainer change hard-stops --------------------------------
test_3_maintainer_hardstop() {
	local approved_dir; approved_dir="$(paruguard_approved_dir)/paruguard-test-maint"
	mkdir -p "$approved_dir"
	printf 'alice\n' > "$approved_dir/maintainer"

	local rc=0
	ALLOW_MAINTAINER_CHANGE=0
	( gate_maintainer "paruguard-test-maint" "mallory" ) >/tmp/paruguard-test-3.out 2>&1 || rc=$?
	if (( rc == 0 )); then
		report "3 maintainer-hardstop" 1 "gate_maintainer did not abort on alice -> mallory"
		return
	fi

	# orphan -> named (adoption) must also hard-stop
	printf '«orphan»\n' > "$approved_dir/maintainer"
	rc=0
	( gate_maintainer "paruguard-test-maint" "bob" ) >/tmp/paruguard-test-3b.out 2>&1 || rc=$?
	if (( rc == 0 )); then
		report "3 maintainer-hardstop" 1 "gate_maintainer did not abort on orphan-adoption"
		return
	fi

	# --allow-maintainer-change must override (mirrors how bin/paruguard applies
	# it: as a shell variable set after common.sh's defaults are sourced,
	# not via inherited environment — common.sh intentionally does not read
	# config from the environment, only from files/CLI parsing).
	rc=0
	printf 'alice\n' > "$approved_dir/maintainer"
	( ALLOW_MAINTAINER_CHANGE=1; gate_maintainer "paruguard-test-maint" "mallory" ) >/tmp/paruguard-test-3c.out 2>&1 || rc=$?
	if (( rc != 0 )); then
		report "3 maintainer-hardstop" 1 "--allow-maintainer-change (ALLOW_MAINTAINER_CHANGE=1) did not override"
		return
	fi
	report "3 maintainer-hardstop" 0
}

# --- test 8: passthrough --------------------------------------------------
test_8_passthrough() {
	local fakebin; fakebin=$(mktemp -d)
	trap 'rm -rf "$fakebin"' RETURN
	cat > "$fakebin/paru" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
	chmod +x "$fakebin/paru"

	local ok=1 op expected got
	for op in "-Q" "-Ss foo" "-Si foo" "-R foo" "-G foo" "-F foo" "-Sc" "-Qua"; do
		# shellcheck disable=SC2086
		expected=$(printf '%s\n' $op)
		# shellcheck disable=SC2086
		got=$(PATH="$fakebin:$PATH" PARUGUARD_LIB_DIR="$REPO_ROOT/lib" "$REPO_ROOT/bin/paruguard" $op 2>/tmp/paruguard-test-8.err)
		if [[ "$got" != "$expected" ]]; then
			ok=0
			printf '    mismatch for "%s": got=%q expected=%q\n' "$op" "$got" "$expected"
		fi
	done
	report "8 passthrough" $(( ok ? 0 : 1 ))
}

# --- test 10: fail-closed on missing tool ---------------------------------
test_10_fail_closed() {
	local realbin t
	realbin=$(mktemp -d)
	trap 'rm -rf "$realbin"' RETURN
	for t in command paru pacman makechrootpkg arch-nspawn repo-add jq curl git bsdtar unshare sudo; do
		local p; p=$(command -v "$t" 2>/dev/null) || continue
		ln -sf "$p" "$realbin/$t"
	done
	# deliberately omit aur-scan

	local rc=0
	( PATH="$realbin"; source "$REPO_ROOT/lib/common.sh"; assert_environment ) >/tmp/paruguard-test-10.out 2>&1
	rc=$?
	if (( rc == 0 )); then
		report "10 fail-closed" 1 "assert_environment succeeded with aur-scan missing from PATH"
	else
		report "10 fail-closed" 0
	fi
}

# --- test 11: scan-findings override (default fails closed; flag proceeds) ---
test_11_scan_override() {
	local dir="$fixtures/dle-001-curl-pipe-bash"
	if ! command -v aur-scan >/dev/null 2>&1; then
		skip "11 scan-override" "aur-scan not on PATH"
		return
	fi

	# (a) non-interactive, no pre-approval => confirm() defaults No => abort.
	local rc=0
	( FAIL_ON=critical WARN_ON=high ALLOW_SCAN_FINDINGS=0
	  gate_static_scan "paruguard-test-dle-001" "$dir" ) </dev/null >/tmp/paruguard-test-11a.out 2>&1 || rc=$?
	if (( rc == 0 )); then
		report "11 scan-override" 1 "gate_static_scan did not fail closed on critical without override"
		return
	fi

	# (b) ALLOW_SCAN_FINDINGS=1 pre-approves => proceeds past the same finding.
	rc=0
	( FAIL_ON=critical WARN_ON=high ALLOW_SCAN_FINDINGS=1
	  gate_static_scan "paruguard-test-dle-001" "$dir" ) </dev/null >/tmp/paruguard-test-11b.out 2>&1 || rc=$?
	if (( rc != 0 )); then
		report "11 scan-override" 1 "gate_static_scan aborted even with ALLOW_SCAN_FINDINGS=1"
		return
	fi
	report "11 scan-override" 0
}

# --- test 12: existing clone is fast-forwarded to upstream (§6.1) ----------
# `paru -G` only fetches an existing clone; gate_sync_clone must move HEAD to
# upstream, and must fail closed on a dirty tree or a rewritten upstream.
test_12_clone_sync() {
	local tmp upstream clone rc
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN
	upstream="$tmp/upstream"; clone="$tmp/clone"
	local -a g=(git -c user.email=t@t -c user.name=t -c init.defaultBranch=master)

	mkdir -p "$upstream"
	( cd "$upstream" && "${g[@]}" init -q && printf 'pkgver=1\n' > PKGBUILD \
		&& "${g[@]}" add -A && "${g[@]}" commit -q -m v1 ) || { report "12 clone-sync" 1 "fixture setup"; return; }
	"${g[@]}" clone -q "$upstream" "$clone" 2>/dev/null
	( cd "$upstream" && printf 'pkgver=2\n' > PKGBUILD && "${g[@]}" commit -q -am v2 )
	: > "$clone/x-package.log"   # untracked build leftover must be tolerated

	# (a) stale clone + new upstream commit => HEAD advances to upstream.
	rc=0
	( gate_sync_clone test-pkg "$clone" ) >/tmp/paruguard-test-12a.out 2>&1 || rc=$?
	if (( rc != 0 )) || [[ "$(git -C "$clone" rev-parse HEAD)" != "$(git -C "$upstream" rev-parse HEAD)" ]] \
		|| ! grep -q 'pkgver=2' "$clone/PKGBUILD"; then
		report "12 clone-sync" 1 "clone was not fast-forwarded to upstream (rc=$rc)"
		return
	fi

	# (b) locally modified tracked file => fail closed.
	printf 'pkgver=evil\n' > "$clone/PKGBUILD"
	rc=0
	( gate_sync_clone test-pkg "$clone" ) >/tmp/paruguard-test-12b.out 2>&1 || rc=$?
	if (( rc == 0 )); then
		report "12 clone-sync" 1 "did not fail closed on locally modified PKGBUILD"
		return
	fi
	git -C "$clone" checkout -q -- PKGBUILD

	# (c) upstream history rewritten (non-fast-forward) => fail closed.
	( cd "$upstream" && "${g[@]}" commit -q --amend -m v2-rewritten )
	rc=0
	( gate_sync_clone test-pkg "$clone" ) >/tmp/paruguard-test-12c.out 2>&1 || rc=$?
	if (( rc == 0 )); then
		report "12 clone-sync" 1 "did not fail closed on non-fast-forward upstream"
		return
	fi
	report "12 clone-sync" 0
}

# --- test 13: post-install cleanup helpers are pure + bounded (§6.3 step 5) --
test_13_cleanup_prune() {
	# shellcheck source=lib/build.sh
	source "$REPO_ROOT/lib/build.sh"
	local tmp rc=0 got want
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN
	local repo="$tmp/repo" pool="$tmp/pool" work="$XDG_STATE_HOME/paruguard/work"
	mkdir -p "$repo" "$pool" "$work/foo" "$work/bar"

	# repo: foo has 4 versions (+ a -debug and a prefix-collision foo-bar), bar 1
	local i
	for i in 1 2 3 4; do
		: > "$repo/foo-$i.0-1-x86_64.pkg.tar.zst"; touch -d "2026-01-0$i" "$repo/foo-$i.0-1-x86_64.pkg.tar.zst"
		: > "$repo/foo-debug-$i.0-1-x86_64.pkg.tar.zst"; touch -d "2026-01-0$i" "$repo/foo-debug-$i.0-1-x86_64.pkg.tar.zst"
	done
	: > "$repo/foo-bar-9.0-1-x86_64.pkg.tar.zst"
	: > "$repo/bar-1.0-1-any.pkg.tar.zst"

	# (a) keep=1 => current (4.0) + one older (3.0) survive; 1.0, 2.0 go.
	got=$(AUR_REPO_DIR="$repo" build_old_repo_files foo 1 | sed 's#.*/##' | sort | tr '\n' ' ')
	want="foo-1.0-1-x86_64.pkg.tar.zst foo-2.0-1-x86_64.pkg.tar.zst "
	[[ "$got" == "$want" ]] || { rc=1; echo "    (a) got=[$got] want=[$want]"; }
	# (b) keep=0 => only the current survives; the -debug companion is separate.
	got=$(AUR_REPO_DIR="$repo" build_old_repo_files foo-debug 0 | wc -l)
	[[ "$got" == 3 ]] || { rc=1; echo "    (b) foo-debug keep=0 pruned $got, want 3"; }
	# (c) a single version is never pruned, even at keep=0; foo-bar untouched.
	got=$(AUR_REPO_DIR="$repo" build_old_repo_files bar 0 | wc -l)
	[[ "$got" == 0 ]] || { rc=1; echo "    (c) bar pruned $got, want 0"; }
	got=$(AUR_REPO_DIR="$repo" build_old_repo_files foo 0 | grep -c 'foo-bar' || true)
	[[ "$got" == 0 ]] || { rc=1; echo "    (c) foo-bar matched as foo"; }

	# source filenames: name::url, plain url, git+url with fragment, local file
	cat > "$work/foo/.SRCINFO" <<'SRC'
pkgbase = foo
	source = foo-2.0.tar.gz::https://example.com/dl?v=2.0
	source = https://example.com/foo-extra.zip
	source = git+https://example.com/foo.git#tag=v2
	source = foo.desktop
	source_x86_64 = foo-x86_64.bin::https://example.com/foo-x86_64
SRC
	printf 'pkgbase = bar\n\tsource = https://example.com/bar-1.0.tar.gz\n' > "$work/bar/.SRCINFO"
	got=$(build_source_filenames "$work/foo" | tr '\n' ' ')
	want="foo foo-2.0.tar.gz foo-extra.zip foo-x86_64.bin "
	[[ "$got" == "$want" ]] || { rc=1; echo "    (d) got=[$got] want=[$want]"; }

	# (e) pool pruning: only unreferenced regular files; VCS dirs untouched.
	: > "$pool/foo-2.0.tar.gz"; : > "$pool/foo-1.0.tar.gz"; : > "$pool/bar-1.0.tar.gz"
	: > "$pool/stale-0.1.tar.gz"; mkdir -p "$pool/foo"   # git checkout dir
	got=$(AUR_SRCPOOL="$pool" build_unreferenced_srcpool_files | sed 's#.*/##' | sort | tr '\n' ' ')
	want="foo-1.0.tar.gz stale-0.1.tar.gz "
	[[ "$got" == "$want" ]] || { rc=1; echo "    (e) got=[$got] want=[$want]"; }
	# (f) no .SRCINFO anywhere => prune nothing (never wipe the pool).
	rm -f "$work/foo/.SRCINFO" "$work/bar/.SRCINFO"
	got=$(AUR_SRCPOOL="$pool" build_unreferenced_srcpool_files | wc -l)
	[[ "$got" == 0 ]] || { rc=1; echo "    (f) pruned $got with no .SRCINFO, want 0"; }

	report "13 cleanup-prune" "$rc"
}

# --- live tests (§11 tests 4,5,6,7,9) -------------------------------------

live_setup_clonedir() {
	local fixture="$1" name="$2" clonedir
	clonedir=$(mktemp -d)
	cp -r "$fixture"/. "$clonedir"/
	( cd "$clonedir" && makepkg --printsrcinfo > .SRCINFO 2>/tmp/paruguard-test-srcinfo.err ) \
		|| { echo "makepkg --printsrcinfo failed for $name" >&2; return 1; }
	( cd "$clonedir" && git init -q && git -c user.email=t@t -c user.name=t add -A \
		&& git -c user.email=t@t -c user.name=t commit -q -m init )
	printf '%s\n' "$clonedir"
}

test_4_network_off_build() {
	# shellcheck source=lib/build.sh
	source "$REPO_ROOT/lib/build.sh"
	local clonedir; clonedir=$(live_setup_clonedir "$fixtures/network-off-build" network-off) || { report "4 network-off-build" 1 "fixture setup failed"; return; }
	local rc=0
	( build_target "paruguard-test-network-off" "$clonedir" ) >/tmp/paruguard-test-4.out 2>&1 || rc=$?
	# AUR_CHROOT_ROOT is never reassigned; false positive
	# shellcheck disable=SC2031
	sudo rm -rf "$AUR_CHROOT_ROOT/paruguard-paruguard-test-network-off" 2>/dev/null
	if (( rc == 0 )); then
		report "4 network-off-build" 1 "build succeeded despite network-off (I2 violated) — see /tmp/paruguard-test-4.out"
	else
		report "4 network-off-build" 0
	fi
	log "test 4: to verify the control side (build succeeds WITH network), temporarily bypass" \
	    "build_do_build's 'unshare -n' for a one-off manual run — do not leave that change in place."
}

test_5_noscriptlet() {
	# shellcheck source=lib/build.sh
	source "$REPO_ROOT/lib/build.sh"
	# shellcheck source=lib/install.sh
	source "$REPO_ROOT/lib/install.sh"
	rm -f /tmp/paruguard-scriptlet-ran
	local clonedir; clonedir=$(live_setup_clonedir "$fixtures/noscriptlet" noscriptlet) || { report "5 noscriptlet" 1 "fixture setup failed"; return; }
	local rc=0
	( build_target "paruguard-test-noscriptlet" "$clonedir" ) >/tmp/paruguard-test-5-build.out 2>&1 || rc=$?
	if (( rc != 0 )); then
		report "5 noscriptlet" 1 "build failed — see /tmp/paruguard-test-5-build.out"
		return
	fi
	local f; f=$(build_latest_repo_file paruguard-test-noscriptlet)
	ALL_AUR_NAMES=(paruguard-test-noscriptlet); EXPLICIT_AUR_FILES=("$f"); DEP_AUR_FILES=()
	( install_run ) >/tmp/paruguard-test-5-install.out 2>&1 || rc=$?
	sudo pacman -Rns --noconfirm paruguard-test-noscriptlet >/dev/null 2>&1
	# AUR_CHROOT_ROOT is never reassigned; false positive
	# shellcheck disable=SC2031
	sudo rm -rf "$AUR_CHROOT_ROOT/paruguard-paruguard-test-noscriptlet" 2>/dev/null
	if [[ -e /tmp/paruguard-scriptlet-ran ]]; then
		rm -f /tmp/paruguard-scriptlet-ran
		report "5 noscriptlet" 1 "post_install ran (I4 violated) — /tmp/paruguard-scriptlet-ran was created"
	else
		report "5 noscriptlet" 0
	fi
}

test_6_secrets_isolation() {
	# shellcheck source=lib/build.sh
	source "$REPO_ROOT/lib/build.sh"
	local clonedir; clonedir=$(live_setup_clonedir "$fixtures/secrets-isolation" secrets) || { report "6 secrets-isolation" 1 "fixture setup failed"; return; }
	local rc=0
	( build_target "paruguard-test-secrets" "$clonedir" ) >/tmp/paruguard-test-6.out 2>&1 || rc=$?
	# AUR_CHROOT_ROOT is never reassigned; false positive
	# shellcheck disable=SC2031
	sudo rm -rf "$AUR_CHROOT_ROOT/paruguard-paruguard-test-secrets" 2>/dev/null
	report "6 secrets-isolation" "$rc" "$( (( rc != 0 )) && echo 'see /tmp/paruguard-test-6.out' )"
}

test_7_scriptlet_split() {
	skip "7 scriptlet-split" "needs a real official-repo dependency with a scriptlet; verify manually per PLAN.md §11 test 7"
}

test_9_idempotent_setup() {
	local before after
	before=$(sha256sum "${XDG_CONFIG_HOME:-$HOME/.config}/paru/paru.conf" 2>/dev/null)
	"$REPO_ROOT/bin/paruguard-setup" --yes >/tmp/paruguard-test-9a.out 2>&1
	"$REPO_ROOT/bin/paruguard-setup" --yes >/tmp/paruguard-test-9b.out 2>&1
	after=$(sha256sum "${XDG_CONFIG_HOME:-$HOME/.config}/paru/paru.conf" 2>/dev/null)
	local header_count
	header_count=$(grep -c '^\[options\]' "${XDG_CONFIG_HOME:-$HOME/.config}/paru/paru.conf" 2>/dev/null || echo 0)
	local rc=1
	if diff -q <(echo "$before") <(echo "$after") >/dev/null 2>&1 || [[ -z "$before" ]]; then
		if [[ "$header_count" == 1 ]]; then rc=0; fi
	fi
	report "9 idempotent-setup" "$rc" "paru.conf [options] header count=$header_count (want 1)"
}

echo "paruguard test suite (fast tier)"
test_1_static_gate_blocks
test_2_install_escalates
test_3_maintainer_hardstop
test_8_passthrough
test_10_fail_closed
test_11_scan_override
test_12_clone_sync
test_13_cleanup_prune

if (( LIVE )); then
	echo
	echo "paruguard test suite (live tier — real chroot builds, real installs, real paruguard-setup)"
	warn "these tests mutate real system state and need interactive sudo"
	test_4_network_off_build
	test_5_noscriptlet
	test_6_secrets_isolation
	test_7_scriptlet_split
	test_9_idempotent_setup
else
	echo
	echo "(skipping live tier — re-run with --live to exercise real chroot builds/installs; PLAN.md §11 tests 4,5,6,7,9)"
fi

echo
printf 'results: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
