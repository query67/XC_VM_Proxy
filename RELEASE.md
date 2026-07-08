# XC_VM_Proxy — Release Checklist

Step-by-step guide for building and publishing a proxy-node release.

The release artifact (`proxy.tar.gz` + hashes) is consumed by the XC_VM panel:
`ProxyArchiveUpdater` and the `cron:proxy` job download the **latest version in the
channel** from this repo's GitHub Releases, place it in the MAIN server's
`bin/install/`, and ship it to proxy nodes. There is **no gate on the panel side** —
a stable release automatically rolls out to every new proxy install — so never
publish an unverified stable build.

---

## 0. Prerequisites

- Tags must be **bare semver `X.Y.Z`** (no `v` prefix, no 4th component). The panel
  validates them with `isValidVersion()` (regex `^[0-9]+\.[0-9]+\.[0-9]+$`) and
  compares with `version_compare` — `v1.0.0` / `1.0.0.1` / `1.0.00` are rejected.
- The build requires **GNU tar** (`--sort` / `--owner` flags; BSD/macOS tar won't work).
- Permissions are normalised via `chmod`, which only works on a filesystem that
  honours it. Staging happens in `/tmp` (ext4/tmpfs) — on NTFS/exFAT/CIFS mounts
  `chmod` is a no-op and the archive would ship with 0777. CI (Ubuntu) builds on
  ext4; locally `/tmp` is fine too.

---

## 1. Prepare the release base

Finish all changes and make sure they are on `main`. Set the version once:

```bash
VERSION="X.Y.Z"   # bare semver, no "v"
```

---

## 2. Pre-release verification (required)

Build locally and confirm the archive is correct and reproducible:

```bash
make build VERSION="$VERSION"
make check-reproducible VERSION="$VERSION"    # two builds → identical sha256
```

**Inspect the archive:**

```bash
# 1. Valid gzip tar, lists without errors
tar -tzf dist/proxy.tar.gz >/dev/null && echo "OK: archive lists cleanly"

# 2. No world-writable (0777) files — must be 0
tar -tvzf dist/proxy.tar.gz | awk '$1 ~ /rwxrwxrwx/{c++} END{print (c+0)" world-writable"}'

# 3. Key executables present (php, php-fpm, nginx, service)
tar -tvzf dist/proxy.tar.gz | grep -E 'bin/php/bin/php$|sbin/php-fpm$|nginx/sbin/nginx$|/service$'

# 4. Hashes in the panel's format ("<hash>␠␠proxy.tar.gz")
cat dist/hashes.md5 dist/hashes.sha256
```

**For the first release `1.0.0`** — diff the layout/permissions against the historical
archive (if you have one) and consciously accept the diff (dropping world-write /
world-exec is expected):

```bash
diff <(tar -tvzf /path/to/old/proxy.tar.gz | awk '{print $1, $NF}' | sort) \
     <(tar -tvzf dist/proxy.tar.gz         | awk '{print $1, $NF}' | sort)
```

> ✅ Before publishing a stable build, confirm the archive actually installs a
> working proxy node (there is no panel-side gate — a broken release breaks new installs).

---

## 3. Create the release (GitHub Actions builds & attaches)

Production builds run via the `.github/workflows/build-release.yml` workflow.

1. Go to [GitHub Releases](https://github.com/Vateron-Media/XC_VM_Proxy/releases).
2. **Create a new release** → tag `X.Y.Z` (bare semver, from step 1).
3. Tick **Set as a draft** and save.
4. The workflow runs on release creation: it builds `proxy.tar.gz`, `hashes.md5`,
   `hashes.sha256`, runs `check-reproducible` + `tar -tzf`, uploads the assets, and
   **removes the draft flag as its last step** — so the panel only sees the tag once
   the assets are already in place.

> Alternative (rebuild an existing tag manually): **Actions → build-release →
> Run workflow → tag = X.Y.Z**.

> ⚠️ Do not attach `proxy.tar.gz` by hand — the workflow builds and uploads it
> (deterministically, with correct permissions). A manual build from an NTFS mount
> would ship 0777.

---

## 4. After the release

- [ ] **3 files** attached to the release: `proxy.tar.gz`, `hashes.md5`, `hashes.sha256`.
- [ ] Release is **published** (not a draft) — otherwise the panel can't see it.
- [ ] The asset's md5 matches `hashes.md5`:
      `curl -sL <asset-url> | md5sum` ↔ the contents of `hashes.md5`.
- [ ] On a test MAIN: `console.php cron:proxy --force` → `[OK] updated to X.Y.Z`, and
      `bin/install/proxy.tar.gz` + the `bin/install/proxy_version.json` index update.
- [ ] A test proxy-node install from the fresh archive succeeds.

---

## Command reference

| Command | Purpose |
| --- | --- |
| `make build VERSION=X.Y.Z` | Full build: `dist/proxy.tar.gz` + `hashes.md5` + `hashes.sha256` |
| `make check-reproducible VERSION=X.Y.Z` | Build twice, compare sha256 (determinism) |
| `make clean` | Remove `dist/` and the `/tmp` stage |
| `make set_permissions` | (internal) normalise permissions in the stage |
| `make verify_no_lfs_pointers` | (internal) fail if LFS pointer stubs leaked in |

**`build` target:** `clean → stage → set_permissions → write_version →
verify_no_lfs_pointers → archive → hashes`.
