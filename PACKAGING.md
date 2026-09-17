# Packaging & AUR submission

Maintainer notes for shipping paruguard. paruguard is pure Bash, so a package
just installs files (`make install`); there is nothing to compile.

## Two AUR packages

| AUR package | Built from | PKGBUILD in this repo |
|---|---|---|
| **`paruguard`** | the latest **tagged release** tarball (verified sha256) | `PKGBUILD.release` |
| **`paruguard-git`** | the tip of **`main`** (VCS) | `PKGBUILD` |

Both `build()`→`make build`, `check()`→`make test` (fast tier), and
`package()`→`make PREFIX=/usr DESTDIR="$pkgdir" install`. Runtime deps (`paru`,
`ks-aur-scanner`) are themselves AUR packages — fine for an AUR package; a
helper resolves them.

`paruguard-git` tracks `main`, so **a plain `git push` already ships code
changes** to `-git` users on their next rebuild — no AUR action needed. The AUR
metadata (and the stable `paruguard` package) only change when you cut a
tagged release.

## Cutting a release — one command

```sh
make release VERSION=1.2.0                      # auto-generated GitHub notes
make release VERSION=1.2.0 NOTES="Highlights…"  # or your own notes
```

`scripts/release.sh` does the whole ceremony (run it interactively — the GitHub
and AUR pushes use your ssh agent / AUR key and may prompt for a passphrase):

1. preflight — on `main`, clean tree, `make build` + `make test` pass;
2. bump the `-git` `pkgver` placeholder, commit, tag `vX.Y.Z`, push `main` + tag;
3. create the GitHub Release (auto notes or `NOTES=`);
4. download the tag tarball, compute its **sha256**, update `PKGBUILD.release`
   (`pkgver` + checksum), commit, push;
5. refresh `.SRCINFO` and push **both** AUR repos:
   `aur-pkg/` → `paruguard-git`, `aur-pkg-release/` → `paruguard`.

`aur-pkg/` and `aur-pkg-release/` are local clones of the two AUR repos
(git-ignored); the script creates them on first run.

## Prerequisites (one-time)

- An [AUR account](https://aur.archlinux.org) with your **SSH public key**
  registered (Account → My Account). AUR git auth is SSH, not PGP.
- `~/.ssh/config` offering that key to `aur.archlinux.org` (and, given a large
  agent, `IdentitiesOnly yes` so it isn't refused for `MaxAuthTries`).
- `gh` (github-cli), authenticated.

## Manual submission (first import of a new package base)

The AUR auto-creates a package base on first push if the name is free:

```sh
git clone ssh://aur@aur.archlinux.org/<pkgbase>.git
cd <pkgbase>
cp ../paruguard/PKGBUILD .           # or PKGBUILD.release for the stable pkg
makepkg --printsrcinfo > .SRCINFO    # REQUIRED by the AUR
git add PKGBUILD .SRCINFO && git commit -m "<pkgbase> <version>" && git push
```

Never commit build artifacts (`pkg/`, `src/`, `*.pkg.tar.zst`). Sanity-check a
PKGBUILD with `namcap PKGBUILD` and a real `makepkg -si` (ideally in the VM
rig) before pushing.

## After publishing

Re-run `testrig/smoke-packaged.sh` against the pushed tree to confirm the exact
`makepkg -si` → `paruguard-setup` → real-install path a user will run.
