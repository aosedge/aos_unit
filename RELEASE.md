# Release Process

This document covers the conventions and setup required to publish a release.
It focuses on project-specific rules and pitfalls; for general GPG and
Launchpad documentation follow the links provided.

---

## Table of Contents

- [Versioning](#versioning)
- [Git Tag Format](#git-tag-format)
- [Signing a Release Tag](#signing-a-release-tag)
- [Secrets and Keys](#secrets-and-keys)
- [Publishing a Release](#publishing-a-release)

---

## Versioning

Versions follow [Semantic Versioning 2.0.0](https://semver.org/) —
`MAJOR.MINOR.PATCH` (e.g. `1.0.4`). Git tags use a `v` prefix: `v1.0.4`.

The build script derives the Debian package version from the tag:

| Context          | Version format               | Example                          |
|------------------|------------------------------|----------------------------------|
| PPA (per series) | `<ver>~<series>`             | `1.0.4~jammy`, `1.0.4~noble`    |
| Local dev build  | `<ver>+git<sha>+<timestamp>` | `1.0.4+gitabc123+20260210120000` |

The `~series` suffix ensures the PPA package sorts below any future native
distro package of the same upstream version (`~` sorts before everything in
Debian version ordering).

---

## Git Tag Format

The PPA publish pipeline extracts the changelog entry entirely from the
annotated tag message. **Both subject and body must be non-empty** — the
pipeline refuses to proceed otherwise.

### Subject line

The subject is written into the changelog as-is, without a bullet prefix.
It also becomes the release title on GitHub. Keep it concise. Do not include
the version number — it is encoded in the tag name itself.

### Body

Body lines are interpreted as follows:

- A line starting with `-` becomes a `[ Section Header ]` in the changelog,
  useful for grouping related changes or crediting contributors.
- Any other non-blank line is prefixed with `* ` and becomes a changelog bullet.
- Blank lines between groups are preserved as paragraph separators.
- Leading and trailing blank lines are stripped.

### The mandatory blank line

Git splits subject from body at the **first blank line**. Without it,
everything ends up in the subject and the body is empty, which the pipeline
rejects. This is a common mistake — if you see:

```
ERROR: Tag body (release description) for vX.Y.Z is empty; refusing to proceed
```

the tag was created without a blank line separator. Delete it and recreate:

```sh
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
```

### Complete example

```sh
cat > /tmp/tag-v1.2.0.txt << 'EOF'
Add systemd watchdog support

- Core changes
Add systemd watchdog support via sd_notify
Increase default reconnect timeout to 30s

- Bug fixes
Fix race condition in connection teardown

- Dependencies
Update dependency: libmosquitto >= 2.0
EOF

git tag -s -F /tmp/tag-v1.2.0.txt v1.2.0
```

Using `-F` is preferred over `-m` or opening an editor — it makes the message
reviewable before signing and avoids accidentally collapsing newlines.

This produces the following `debian/changelog` entry:

```
mypkg (1.2.0~jammy) jammy; urgency=medium

  Add systemd watchdog support

  [ Core changes ]
  * Add systemd watchdog support via sd_notify
  * Increase default reconnect timeout to 30s

  [ Bug fixes ]
  * Fix race condition in connection teardown

  [ Dependencies ]
  * Update dependency: libmosquitto >= 2.0

 -- Jane Smith <jane@example.com>  Mon, 10 Feb 2026 12:00:00 +0000
```

### Urgency: CRITICAL releases

If the subject begins with `CRITICAL: `, urgency is set to `critical` instead
of `medium`. Use this only for security fixes or severe regressions.

```
CRITICAL: fix authentication bypass in session handler

- Details
Fix missing token validation in session_handler.c that allowed
unauthenticated clients to issue privileged commands.
```

---

## Signing a Release Tag

The pipeline **only triggers on signed tags** matching `v[0-9]*.[0-9]*.[0-9]*`
and **verifies the signature** against `TAG_SIGNING_PUBKEYS` before proceeding.

Verify the tag before pushing:

```sh
git tag -v v1.2.0
```

Look for `gpg: Good signature`. If you see `BAD signature` or
`Can't check signature`, delete the tag and re-create it — do not push.

For GPG key generation and git signing configuration see the
[Git Tools — Signing Your Work](https://git-scm.com/book/en/v2/Git-Tools-Signing-Your-Work)
chapter of the Git book.

---

## Secrets and Keys

Two distinct GPG keys are involved. They must not be the same key.

| Key | Purpose | Registered where |
|-----|---------|-----------------|
| **Tag signing key** | Authorises the release | GitHub secret `TAG_SIGNING_PUBKEYS` (public key only) |
| **PPA signing key** | Signs `.dsc`/`.changes` for Launchpad | Launchpad + GitHub secrets `PPA_GPG_PRIVATE_KEY`, `PPA_GPG_KEY_ID` |

### PPA signing key — passphrase

> **Prefer a passphrase-free PPA signing key.** The private key is already
> protected by GitHub's secrets store, which is sufficient for a key whose sole
> purpose is signing CI build artefacts. A passphrase adds operational
> complexity and failure modes with no meaningful security gain in this context.
> Reserve passphrase protection for keys on developer workstations or hardware
> tokens. Leave `GPG_PASSPHRASE` unset.

### GitHub secrets and variables

Navigate to **Settings → Secrets and variables → Actions** and configure:

**Secrets** (sensitive — encrypted at rest, never shown in logs):

| Name | Value |
|------|-------|
| `PPA_GPG_PRIVATE_KEY` | Armored private key (`-----BEGIN PGP PRIVATE KEY BLOCK-----` block) |
| `PPA_GPG_KEY_ID` | Long key ID or fingerprint of the PPA signing key |
| `GPG_PASSPHRASE` | Passphrase if set on the PPA signing key (see note above) |
| `TAG_SIGNING_PUBKEYS` | Armored public key(s) of all developers authorised to cut releases; multiple keys can be concatenated |

**Variables** (non-sensitive):

| Name | Example | Description |
|------|---------|-------------|
| `PPA_SERIES` | `jammy noble` | Space-separated Ubuntu series to build for |
| `PPA_TARGET` | `ppa:myteam/mypackage` | Launchpad PPA identifier |

See [GitHub's secrets documentation](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions)
for how to add and manage secrets and variables.

### Registering the PPA signing key in Launchpad

The PPA signing key must be registered with Launchpad before it will accept
uploads. Follow the
[Launchpad OpenPGP key registration guide](https://help.launchpad.net/ReadingOpenPgpMail).

> Rotate the PPA signing key if you suspect compromise: revoke it on Launchpad,
> generate a new one, and update `PPA_GPG_PRIVATE_KEY`, `PPA_GPG_KEY_ID`, and
> the Launchpad registration simultaneously.

---

## Publishing a Release

1. Ensure the target commit is on `main` and all CI checks pass.

2. Create and push a signed tag:
   ```sh
   git tag -s -F /tmp/tag-v1.2.0.txt v1.2.0
   git push origin v1.2.0
   ```
   Push the tag separately — `git push` alone does not push tags.

3. Monitor the `ppa-publish` workflow in the **Actions** tab. On success,
   source packages appear in the PPA within minutes; binary builds complete
   within 15–30 minutes depending on Launchpad queue depth.

4. Build artefacts (`.dsc`, `.changes`, `.buildinfo`, orig tarball) are
   retained for 7 days as GitHub Actions artefacts for audit purposes.

---

## Reproducible Builds

The build script uses `SOURCE_DATE_EPOCH` to produce a deterministic changelog
timestamp, which is a requirement for
[reproducible builds](https://reproducible-builds.org/). It is derived
automatically from the HEAD commit time when not set explicitly. To override:

```sh
export SOURCE_DATE_EPOCH=1739185200
./build_release.sh ppa 1.2.0 --msg-from-tag v1.2.0 --upload
```
