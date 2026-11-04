# Verified signing for the 88kbleirad repository

The production and staging repositories publish GPG-signed packages and a
signed pacman database. This page documents how a **client** verifies and
trusts the repository, and how the repository owner configures the signing
key.

---

## 1. Client: obtain and verify the public signing key

The publish pipeline exports the repository's public signing key to every
release as `88kbleirad.pub.asc`. Download it from the production release:

```bash
curl -fLO https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository/88kbleirad.pub.asc
```

Verify the file is a well-formed OpenPGP public key:

```bash
gpg --show-keys 88kbleirad.pub.asc
# pub   ed25519 YYYY-MM-DD [SC]
#       1111111111111111111111111111111111111111
# uid   [ unknown] 88kbleirad <88kbleirad@users.noreply.github.com>
```

**Fingerprint verification is mandatory.** Compare the fingerprint above
with the value published out-of-band (e.g. the repository README or an
announcement the owner controls). If they do not match, stop — the key
may be an impersonation. The expected fingerprint for this repository is:

```
<FINGERPRINT-PLACEHOLDER>
```

## 2. Import the key with pacman-key

```bash
sudo pacman-key --add 88kbleirad.pub.asc
```

Check the imported key's fingerprint:

```bash
pacman-key --finger 88kbleirad@users.noreply.github.com
```

## 3. Trust it locally

pacman-key only considers a key trusted after you explicitly sign it with
a key you trust. Treat the repository key as locally trusted:

```bash
sudo pacman-key --lsign-key 88kbleirad@users.noreply.github.com
```

Verify the trust level:

```bash
pacman-key --list-keys 88kbleirad@users.noreply.github.com
# pub   ed25519 YYYY-MM-DD [SC] [trusted: unknown]
#       ... [expires: ...]
```

A `[trusted: unknown]` label is expected; proper verification only
requires the key to be in the keyring and the fingerprint to match.
(Optional: `--edit-key` → `trust` → `5` also works, but `--lsign-key`
is cleaner: it asserts the key is trusted by a key you own.)

## 4. Enable Required signature checks in pacman.conf

Edit `/etc/pacman.conf`. The `[88kbleirad]` section previously used
`Optional TrustAll` (no verification). Replace it with:

```ini
[88kbleirad]
SigLevel = Required TrustedOnly
Server = https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository
```

- `Required` — every package and the database must carry a valid
  signature; unsigned or invalid signatures cause installation to fail.
- `TrustedOnly` — only keys imported into the keyring (step 2) are
  accepted. `TrustAll` would accept any self-signed key, which defeats
  the purpose.

Do **not** switch to `Required` until the repository actually publishes
signatures (the current release is still pre-signing).

## 5. Test signature verification

Sync the signed database and verify a signature:

```bash
sudo pacman -Sy
# If the database is signed, pacman prints something like:
#   :: Synchronizing package databases...
#   88kbleirad ...   1.2 MiB ... (signed by 88kbleirad@users.noreply.github.com)
```

Then verify a package signature explicitly (choose any installed package
from this repository):

```bash
curl -fLO https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository/nmtui-go-0.2.7-1-x86_64.pkg.tar.zst
curl -fLO https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository/nmtui-go-0.2.7-1-x86_64.pkg.tar.zst.sig
gpg --verify nmtui-go-0.2.7-1-x86_64.pkg.tar.zst.sig nmtui-go-0.2.7-1-x86_64.pkg.tar.zst
# gpg: Good signature from "88kbleirad <...>" [full]
```

The database signature is verified in the same way:

```bash
curl -fLO https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository/88kbleirad.db.sig
curl -fLO https://github.com/88kbleirad/88kbleirad-arch-repo/releases/download/repository/88kbleirad.db.tar.gz
gpg --verify 88kbleirad.db.sig 88kbleirad.db.tar.gz
```

## 6. Negative test (optional but recommended)

A tampered package must be rejected:

```bash
printf 'x' | dd of=nmtui-go-0.2.7-1-x86_64.pkg.tar.zst bs=1 seek=1000 count=1 conv=notrunc
gpg --verify nmtui-go-0.2.7-1-x86_64.pkg.tar.zst.sig nmtui-go-0.2.7-1-x86_64.pkg.tar.zst
# gpg: BAD signature from "88kbleirad <...>"
```

And `pacman -S nmtui-go` under `SigLevel = Required TrustedOnly` must
fail rather than install a modified archive.

## 7. Installing and validating a signed package in an Arch Linux VM

On an Arch Linux VM (or container) with an x86-64-v4-capable CPU:

```bash
# 1. import + trust (steps 1–3 above)
# 2. switch SigLevel to Required TrustedOnly (step 4)
sudo pacman -Sy
sudo pacman -S nmtui-go
# 3. confirm the package is the signed one
pacman -Qi nmtui-go | grep -E 'Name|Version|Packager'
# Packager: 88kbleirad <88kbleirad@users.noreply.github.com>
# 4. run it (requires AVX-512-capable CPU)
nmtui-go --version
# 5. verify the installed archive's signature from the local cache
gpg --verify /var/cache/pacman/pkg/nmtui-go-0.2.7-1-x86_64.pkg.tar.zst.sig \
                /var/cache/pacman/pkg/nmtui-go-0.2.7-1-x86_64.pkg.tar.zst
```

---

## Owner operations: the signing key

- The private key is stored **only** in GitHub's secret store, wired to
  the protected `package-signing` environment. It is never committed to
  the repository.
- Only the `publish` job of `build-release.yml` / `build-staging.yml`
  touches the key; PKGBUILD build jobs never see it.
- The key is imported into an ephemeral GNUPGHOME inside the publish
  container. It is passed by bind-mount (host secret file → container
  `/run/secrets/gpg-key`), so it never appears in `docker inspect` or
  the process list.
- Every package archive and both database files (`<db>.db.tar.gz` and
  `<db>.files.tar.gz`) are signed; the plain `.db.sig`/`.files.sig`
  names pacman fetches are published alongside them.
- Any signing or verification failure aborts publication before upload.
- To rotate the key: generate a new key, update `GPG_PRIVATE_KEY` in
  GitHub secrets, publish the new public key, and re-sign the next run.
  Clients re-import the new public key and re-trust it.

See `docs/operator-signing.md` for the full setup and key-generation
commands.
