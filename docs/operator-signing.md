# Operator guide: GPG signing key for the repository

This page is for the repository owner/operator. Clients should read
`docs/pacman-signing.md`.

## Generating a dedicated signing key

Create a dedicated key on a trusted machine (NOT on the GitHub runner):

```bash
# Choose a strong passphrase; store it in a password manager.
gpg --full-generate-key
# Please select what kind of key you want: (8) ECC (set your own capabilities)
# - set key to [S] sign-only
# - curve: ed25519
# - real name: 88kbleirad
# - email: 88kbleirad@users.noreply.github.com   (public, non-personal)
# - no expiration (or a long one)
```

Export the public key and the private key:

```bash
gpg --armor --export 88kbleirad@users.noreply.github.com > 88kbleirad.pub.asc
gpg --armor --export-secret-keys 88kbleirad@users.noreply.github.com > 88kbleirad.key.asc
chmod 600 88kbleirad.key.asc
```

## Configuring GitHub

1. Repository **Settings → Environments → New environment** named
   `package-signing`.
2. In that environment, add a **secret**:
   - `GPG_PRIVATE_KEY` — the armored private key (content of
     `88kbleirad.key.asc`).
   - `GPG_PASSPHRASE` (optional) — the passphrase. If set, the publish
     container pipes it to gpg via fd 0 (loopback pinentry). If empty,
     the key must have an empty passphrase.
3. Under **Environment protection rules**, add protection (e.g. require
   approval) so the key cannot be used by unapproved runs.
4. The `publish` job in `build-release.yml` / `build-staging.yml` already
   declares `environment: package-signing`; build jobs do not.

## How the key is used

- `publish-in-docker.sh` bind-mounts the host secret file into the
  container read-only (`/run/secrets/gpg-key`). The value never appears
  in `docker inspect`, argv, or logs.
- `sign-helpers.sh` imports it into an ephemeral `$GNUPGHOME`, then:
  - signs every `.pkg.tar.zst` → `.pkg.tar.zst.sig`
  - signs `.db.tar.gz`/`.files.tar.gz` → `.sig` files (and publishes the
    plain `.db.sig`/`.files.sig` aliases pacman fetches)
  - exports `88kbleirad.pub.asc`
- No signing or verification failure is tolerated: the run aborts before
  any upload.

## Important constraints

- **Never commit the private key or passphrase.**
- **Do not reuse a personal key.** Use the dedicated key.
- The key must be an **ed25519 sign-only** key; repo-add's `--sign`
  path is not used (it cannot pass a passphrase non-interactively), so
  signing is done by our own gpg wrapper; passphrase-protected keys work.
- Rotating: update the secret, publish the new `88kbleirad.pub.asc`
  (the next publish run does this automatically), then have clients
  re-import and re-trust.

## Verifying the pipeline locally (no GitHub)

```bash
# simulate a publish with a local key
export GPG_KEY_FILE=/path/to/key.asc
# optional: export GPG_PASSPHRASE_FILE=/path/to/passphrase
export GPG_PASSPHRASE=...   # or leave empty
# run publish-prod.sh / publish-stage.sh in a container as usual
```

All signature operations are implemented in `.github/scripts/sign-helpers.sh`.
