# paruguard — zero-trust AUR installer

`paruguard` is a thin, auditable Bash wrapper around **stock** `paru` + `pacman` + `devtools` +
[`ks-aur-scanner`](https://github.com/KiefStudioMA/ks-aur-scanner) that hardens AUR
install/upgrade against **supply-chain / maintainer-takeover** attacks — while keeping
`paru`/`pacman` muscle memory (`paruguard -S <pkg>`, `paruguard -Syu`).

It is **not** a fork of paru. paru is a dependency; paruguard orchestrates it.

## What it does

For AUR install/upgrade operations, paruguard:

1. **Reads and gates** every PKGBUILD / `.install` / maintainer change before building
   (git-diff gate + AUR-RPC maintainer gate + `aur-scan` static analysis — **fail closed**).
2. **Builds in a chroot with the network turned off** after sources/deps are provisioned,
   so a build-time payload can't fetch a second stage or exfiltrate. Packages that fetch
   their own build dependencies (cargo/go/npm/pip/…) can't build offline; paruguard detects
   these and prompts to run a **networked** build instead — still chroot- and secret-
   isolated, gated, and `--noscriptlet`-installed, but a conscious per-package waiver of the
   network-off guarantee (`--allow-build-net` to pre-approve).
3. **Installs on the host with `pacman -U --noscriptlet`** — the package's `.install`
   scriptlet never runs as root on your machine (libalpm hooks still run, so nothing
   normal breaks).
4. **Reads the skipped scriptlet and gates on it** instead of trusting sandbox replay.
5. Runs an **IOC self-check** (eBPF-rootkit maps + known-compromised package list).
6. Optionally folds in `flatpak update` on full upgrades.

Everything that isn't an AUR sync-install/upgrade passes straight through to `paru`.

## Requirements

- Arch Linux with `base-devel` and `devtools`.
- An AUR helper — **paru** — and **[ks-aur-scanner](https://github.com/KiefStudioMA/ks-aur-scanner)**,
  both from the AUR (bootstrap them once with plain paru or a hand-reviewed `makepkg -si`).
  paruguard orchestrates paru and uses ks-aur-scanner's `aur-scan` as its static-analysis gate.
- `paruguard-setup` installs the remaining dependencies (`jq`, `expac`, `bpf`, `flatpak`, …).

## Installation

**From the AUR** (once published):

```sh
paru -S paruguard
```

**From source — build a pacman package (recommended):**

```sh
git clone https://github.com/jesse-osiecki/paruguard.git
cd paruguard
makepkg -si          # builds via the Makefile (runs the fast test tier as `make check`)
```

Installs a pacman-tracked package; remove later with `sudo pacman -R paruguard-git`.

**From source — without packaging:**

```sh
git clone https://github.com/jesse-osiecki/paruguard.git
cd paruguard
sudo make install    # installs under /usr (PREFIX overridable); undo with `sudo make uninstall`
```

## Setup & first use

`paruguard-setup` configures the build environment. It is idempotent and prompts before it
touches any system file:

```sh
paruguard-setup      # sets up the [aur] local repo + aurbuild chroot, reconciles
                 # pacman.conf/paru.conf, installs deps, and offers to disable the
                 # non-gating ks-aur-scanner shell integration so paruguard's gate is authoritative
paruguard doctor     # verify every prerequisite is in place (fails loudly if not)
```

Then use it like paru/pacman — paruguard hardens AUR install/upgrade and passes everything else
straight through:

```sh
paruguard -S <pkg>            # hardened AUR install — review the PKGBUILD / maintainer gate
paruguard -Syu                # hardened full upgrade: official repos -> AUR -> flatpak
paruguard -Ss <term>          # passthrough to paru unchanged
paruguard --dry-run -S <pkg>  # print the plan without building or installing
```

A hardened operation asks for `sudo` **once at the start** and keeps the credential
refreshed in the background for the rest of the run — so a long build (or time spent
reviewing a gate diff) won't trigger a mid-run re-auth prompt. Nothing runs as root until
you've authenticated.

`paruguard --help` lists the full flag set: `--fail-on`, `--allow-maintainer-change`,
`--allow-scan-findings`, `--allow-build-net`, `--replay-hook`, `--no-flatpak`, `--no-ioc`,
`--sandbox`, `--dry-run`.

## Uninstall

```sh
paruguard-setup --uninstall   # undo the build-environment setup (prompted, reversible)
sudo pacman -R paruguard-git  # or `sudo make uninstall` for a `make install`
```

## Status

Implemented and tagged **v1.0.0**. See **[PLAN.md](./PLAN.md)** for the full design
(network-off build recipe, scriptlet-split install, the gates, the IOC check, security
invariants I1–I7, and the test plan). `tests/run.sh` runs the fast, non-privileged
acceptance tier; the live tier (real chroot builds/installs) runs in a disposable VM via
`testrig/` rather than on your host.

## Honest limits

paruguard is **defense-in-depth, not a guarantee.** Static analysis can't catch every payload;
it protects *build* and *install* time, not the inherent risk of *running* untrusted
software afterward; and the chroot shares the host kernel (a build-time kernel-escape
exploit is only mitigated by the planned gVisor backend). See PLAN.md §10.

## License

GPL-3.0-or-later (matches the paru / ks-aur-scanner ecosystem).
