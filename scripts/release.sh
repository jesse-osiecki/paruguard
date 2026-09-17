#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# scripts/release.sh VERSION ["release notes"] — cut a tagged paruguard release
# and update BOTH AUR packages in one command.
#
#   1. preflight: on main, clean tree, `make build` + `make test` pass
#   2. bump the -git PKGBUILD placeholder to VERSION, commit, tag vVERSION
#   3. push main + tag to GitHub, create the GitHub Release
#   4. compute the release tarball's sha256 (now that the tag exists on GitHub),
#      update PKGBUILD.release (pkgver + checksum), commit, push
#   5. refresh + push both AUR packages:
#        aur-pkg/         -> paruguard-git  (tracks main)
#        aur-pkg-release/ -> paruguard      (this tagged release, verified sum)
#
# Run interactively: the GitHub and AUR pushes use your ssh agent / AUR key and
# may prompt for a passphrase. (For plain code changes you don't need this at
# all — paruguard-git tracks main, so `git push` already ships them.)
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
[[ -t 2 ]] || { C_R=; C_G=; C_Y=; C_0=; }
log()  { printf '%s==>%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s==> WARNING:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s==> ERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

GH_SLUG="jesse-osiecki/paruguard"
AUR_GIT_DIR="$REPO_ROOT/aur-pkg"           # paruguard-git (tracks main)
AUR_REL_DIR="$REPO_ROOT/aur-pkg-release"   # paruguard (tagged release)
AUR_GIT_REMOTE="ssh://aur@aur.archlinux.org/paruguard-git.git"
AUR_REL_REMOTE="ssh://aur@aur.archlinux.org/paruguard.git"

[[ $# -ge 1 ]] || die "usage: scripts/release.sh VERSION [\"release notes\"]  (e.g. 1.2.0)"
version="${1#v}"; shift
notes="${1:-}"
tag="v$version"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be X.Y.Z"

# --- preflight --------------------------------------------------------------
command -v gh >/dev/null 2>&1 || die "gh (github-cli) is required"
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "not on 'main'"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean — commit or stash first"
git rev-parse "$tag" >/dev/null 2>&1 && die "tag $tag already exists locally"
log "preflight: syntax check + fast test tier"
make build >/dev/null
make test  >/dev/null || die "tests failed — not releasing"

# --- refresh_aur DIR REMOTE — copy a PKGBUILD in, regen .SRCINFO, push -------
refresh_aur() {
	local dir="$1" remote="$2" pkgfile="$3" msg="$4"
	[[ -d "$dir/.git" ]] || git clone "$remote" "$dir" \
		|| die "could not clone AUR repo $remote — check your AUR ssh key"
	cp "$pkgfile" "$dir/PKGBUILD"
	( cd "$dir" && makepkg --printsrcinfo > .SRCINFO )
	if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
		git -C "$dir" add PKGBUILD .SRCINFO
		git -C "$dir" commit -q -m "$msg"
		git -C "$dir" push origin master \
			|| warn "AUR push failed for $remote (auth?) — retry: (cd ${dir##*/} && git push origin master)"
	else
		log "${remote##*/}: already up to date"
	fi
}

# --- 1. bump -git placeholder, commit, tag ----------------------------------
log "setting -git PKGBUILD placeholder to $version"
sed -i "s/^pkgver=.*/pkgver=$version/" PKGBUILD
[[ -n "$(git status --porcelain PKGBUILD)" ]] && { git add PKGBUILD; git commit -q -m "release $tag"; }
log "tagging $tag and pushing to GitHub"
git tag -a "$tag" -m "paruguard $tag"
git push origin main
git push origin "$tag"

# --- 2. GitHub release ------------------------------------------------------
log "creating GitHub release $tag"
if [[ -n "$notes" ]]; then
	gh release create "$tag" --repo "$GH_SLUG" --title "paruguard $tag" --latest --notes "$notes"
else
	gh release create "$tag" --repo "$GH_SLUG" --title "paruguard $tag" --latest --generate-notes
fi

# --- 3. stable release metadata (checksum now that the tag tarball exists) ---
log "computing release tarball sha256"
tarball_url="https://github.com/$GH_SLUG/archive/refs/tags/$tag.tar.gz"
sum=$(curl -fsSL "$tarball_url" | sha256sum | cut -d' ' -f1)
[[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "could not compute tarball checksum from $tarball_url"
log "  sha256: $sum"
sed -i -e "s/^pkgver=.*/pkgver=$version/" \
       -e "s/^pkgrel=.*/pkgrel=1/" \
       -e "s/^sha256sums=.*/sha256sums=('$sum')/" PKGBUILD.release
if [[ -n "$(git status --porcelain PKGBUILD.release)" ]]; then
	git add PKGBUILD.release
	git commit -q -m "paruguard $version: release tarball metadata"
	git push origin main
fi

# --- 4. refresh + push both AUR packages ------------------------------------
log "updating AUR: paruguard-git"
refresh_aur "$AUR_GIT_DIR" "$AUR_GIT_REMOTE" "$REPO_ROOT/PKGBUILD"          "paruguard-git $version"
log "updating AUR: paruguard (stable)"
refresh_aur "$AUR_REL_DIR" "$AUR_REL_REMOTE" "$REPO_ROOT/PKGBUILD.release"  "paruguard $version"

log "release $tag complete"
printf '  GitHub:  https://github.com/%s/releases/tag/%s\n' "$GH_SLUG" "$tag" >&2
printf '  AUR:     https://aur.archlinux.org/packages/paruguard  (+ paruguard-git)\n' >&2
