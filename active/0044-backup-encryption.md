# Encrypted and Authenticated Data Backups

## Changelog

* 2026-08-12: @zmstone Initial draft
* 2026-08-12: Rename policy to `node.data_import_encryption`; define the
  `.tar.gz.enc` format and the `emqx ctl data encrypt` command

## Abstract

EMQX data backup archives are plaintext `tar.gz` files, and the import path
applies them after checking only the EMQX edition and version. An archive
carries the whole cluster state: `cluster.hocon` and every Mnesia table dump,
which include API keys, authentication and authorization records, connector
passwords, and other secrets. Restore therefore both discloses those secrets to
anyone who reads a backup file and injects arbitrary configuration and database
state into the cluster when a file is imported.

This EIP adds optional authenticated encryption for backups. A backup is
encrypted with an operator-supplied key using an AEAD cipher, so the archive is
confidential and tamper-evident. Import through the REST API succeeds only when
the matching key was provisioned out of band, so an API caller cannot import an
archive the operator did not authorize. The producing cluster stores no key.

## Motivation

Restore is one of the most powerful operations in the product. It rewrites
`cluster.hocon`, which can enable plugins, change `os_mon` limits, and install
rule-engine actions, and it loads Mnesia table dumps that include credentials.
An attacker who gets a crafted archive imported gains control of the cluster.
The current import path does not check integrity or provenance, so a tampered or
attacker-supplied archive is applied as-is once a caller reaches the import
endpoint.

Backups are also a confidentiality problem on their own. A plaintext archive
that leaves the node, for example copied to object storage or shared for
support, exposes every cluster secret to anyone who reads the file.

Two properties are needed:

* Confidentiality of the archive at rest and in transit.
* A guarantee that an archive imported through the REST API was produced by a
  party the operator trusts and was not modified.

Restore is a dangerous capability that should be gated, in the same spirit as
the control over which plugin CLI commands are allowed to run.

## Design

### Overview

A backup is encrypted with an AEAD cipher (for example AES-256-GCM or
XChaCha20-Poly1305). AEAD gives confidentiality and integrity in one step: an
archive that decrypts and authenticates under the expected key is proven both
unmodified and produced by a holder of that key. A separate signature or MAC is
not required.

The scheme is symmetric. The key that encrypts a backup is the key that
decrypts it. This fits the common case, which is moving a backup between
clusters owned by the same operator. It does not separate the ability to produce
a backup from the ability to import one, so it does not defend one organization
against another; that case is discussed under Declined Alternatives.

### Key handling

The producing cluster stores no key.

* **Create through the REST API.** The operator supplies the key in an
  `x-encryption-key` request header. The value is either the plaintext key or a
  `file://` reference. A header is the idiomatic channel for a per-request secret,
  the same as `Authorization`, and it avoids a request-body field. Body redaction
  in the audit log is key-name based, so a body field would either leak or force a
  common name such as `key` into the global sensitive-key list, which over-redacts
  elsewhere. The `x-encryption-key` name must be added to the sensitive-header
  redaction list so the audit log and traces mask it; otherwise it is recorded in
  cleartext, the same gap tracked for other provider headers. The header is
  protected in transit only when the API listener uses TLS.
* **Create through the CLI.** The operator supplies the key as a `file://`
  reference, or through stdin or a prompt. An inline CLI argument is not accepted,
  because the process table and shell history expose it.
* EMQX uses the supplied key to encrypt and then discards it.
* **Import through the REST API.** The key must be provisioned in advance through
  a `ctl` command on the importing node. The import request does not carry the
  key. If the request carried the key, a caller who can reach the import endpoint
  could supply both a crafted archive and a key that decrypts it, which would
  defeat the control. Provisioning through `ctl` places the trust material on the
  node-owner plane, which the API caller does not control.
* **Import through the CLI.** The caller already has node-owner access, so the
  key may be passed as a `file://` argument. CLI import is the trusted plane.

Moving a backup between clusters is therefore: pick a key, create the backup on
the source with that key, provision the key on the importer through `ctl`, then
import. The key is exchanged once per trust relationship, not once per backup.

### Envelope encryption

Each backup is encrypted with a fresh random data key. The data key is wrapped
with the operator-supplied key and stored, with a key identifier and the AEAD
nonce, in a small cleartext header prepended to the archive. Import reads the key
identifier, selects the matching provisioned key, unwraps the data key, and
decrypts. Envelope encryption lets the operator rotate the provisioned key
without re-encrypting existing archives and lets the importer reject an archive
whose key it does not hold before doing any other work.

### Order of operations on import

Import decrypts and authenticates the archive first, from the raw uploaded bytes,
before it parses `META.hocon` or extracts the `tar`. Reading metadata or
extracting members from an unauthenticated archive would mean trusting
attacker-controlled content to make a security decision, and would expose the
extractor to malicious archive members. Decryption is the outer gate; the
existing edition, version, and namespace handling runs on the authenticated
plaintext.

### Archive format and file name

Encryption wraps a finished archive. EMQX builds the plaintext `tar.gz` first,
exactly as today, and then encrypts the whole file. The encrypted output is not a
`tar` and does not carry members of its own; it is a single opaque blob with a
small cleartext header.

* Plaintext backup: `<name>.tar.gz`, unchanged.
* Encrypted backup: `<name>.tar.gz.enc`.

The `.enc` file is `header || AEAD(plaintext tar.gz)`. The header is cleartext and
starts with a fixed magic marker so a reader, and the importer, can tell an
encrypted backup from a plaintext one without relying on the extension. After the
magic marker the header carries the format version, the AEAD cipher identifier,
the key identifier, the nonce, and the wrapped data key. The importer detects the
magic marker, reads the header, unwraps the data key with the provisioned key,
decrypts and authenticates the body to recover the `tar.gz`, and only then runs
the existing import on the plaintext. The producing side computes the extension
and the importer's format detection from the header, not from the file name, so a
renamed file is still handled correctly.

### Node policy

Whether encryption is required is a property of the importing node, not of the
archive. A node setting `node.data_import_encryption` controls it, with values
`per_profile | true | false`. It defaults to `per_profile`, which requires
encryption under the hardened security profile and does not require it under the
legacy profile. `true` and `false` force the behavior regardless of profile. When
encryption is required, an API import must be an encrypted archive that
authenticates under a provisioned key; a plaintext or wrongly-keyed archive is
rejected. When it is not required, plaintext import keeps working.

The archive's self-reported `version` never relaxes this decision. Reading the
version to decide whether to verify would let an attacker label a crafted archive
as an old, pre-encryption backup and skip the check. The version is used only for
configuration-schema upgrade, after the decryption gate has passed.

### Importing older or plaintext backups

A node that requires encryption still needs a path for genuine plaintext backups
made before this feature. That path is operator-driven, never archive-driven:

* Import through the CLI, which is the trusted plane and is exempt.
* Re-encrypt the plaintext archive out of band with a provisioned key, then
  import the result through the API.
* Temporarily set `node.data_import_encryption` to `false` for a maintenance
  window, which is an explicit and audited configuration change.

### Auditing

The audit log records every import: the key identifier that decrypted a
successful import, and every rejected attempt as a security event. A CLI import
that bypasses the requirement is recorded as such. The create-backup key is a
`file://` reference and is never recorded.

## Configuration Changes

* `node.data_import_encryption`: enum `per_profile | true | false`. Default
  `per_profile` (required under the hardened profile, not required under the legacy
  profile). When encryption is required, REST API import requires an encrypted
  archive that authenticates under a provisioned key.
* Create-backup accepts an optional key. The REST API takes it in the
  `x-encryption-key` header, whose value is the plaintext key or a `file://`
  reference. The CLI takes a `file://` reference, stdin, or a prompt. When absent,
  the backup is plaintext as today.
* `x-encryption-key` is added to the sensitive-header redaction list so the audit
  log and traces mask it.

New `ctl` commands manage keys and encrypt or decrypt archives out of band:

```
# Provision the keys the importer trusts.
emqx ctl data import-key add <key-id> file://<path-to-key>
emqx ctl data import-key list
emqx ctl data import-key delete <key-id>

# Encrypt an existing plaintext backup, for example to re-encrypt an old
# backup before importing it through the API. Produces <name>.tar.gz.enc.
emqx ctl data encrypt /var/lib/emqx/backup/cluster-2026-08-12.tar.gz \
  --key-id prod-2026 --key file:///run/secrets/backup-key

# Decrypt on the trusted plane, for inspection.
emqx ctl data decrypt /path/cluster-2026-08-12.tar.gz.enc \
  --key file:///run/secrets/backup-key --out /tmp/cluster.tar.gz
```

The encrypted output is a separate file (`<name>.tar.gz.enc`), not a change to the
`tar` layout. `META.hocon` inside the plaintext archive gains no secret material;
the wrapped data key, key identifier, cipher, and nonce live in the encrypted
file's cleartext header.

## Backwards Compatibility

The feature is opt-in and off by default under the legacy profile.

* Existing plaintext backups continue to import unchanged while encryption is not
  required (`node.data_import_encryption = false`, or `per_profile` under the
  legacy profile).
* A create request without a key produces a plaintext backup, as today.
* Under the hardened profile, `node.data_import_encryption = per_profile` requires
  encryption, which is a behavior change for hardened deployments: plaintext API
  import is rejected, and operators use the CLI, re-encryption, or an explicit
  policy relaxation for old backups. This is called out as an intentional
  hardening default.

No archive-format field is repurposed. The encrypted format is a distinct layout
identified by its header, so a reader can tell an encrypted archive from a
plaintext one without guessing.

## Document Changes

* The backup and restore documentation gains a section on encrypted backups: how
  to supply the key on create, how to provision keys on the importer, the API and
  CLI import behavior, key rotation, and the operator's responsibility for the
  key, including that a lost key makes a backup unrecoverable because there is no
  escrow.
* The Security Checklist gains an entry recommending encrypted backups and the
  hardened default.

## Testing Suggestions

* Create an encrypted backup and import it with the correct provisioned key.
* Import with a wrong or missing key and confirm rejection.
* Tamper with one byte of an encrypted archive and confirm the AEAD check fails
  the import before any extraction.
* Confirm import decrypts before parsing `META.hocon` and before `tar`
  extraction, including that a malicious member in an unauthenticated archive is
  never written to disk.
* Enforce `node.data_import_encryption`: plaintext API import is rejected when
  encryption is required and accepted when it is not, across the `per_profile`,
  `true`, and `false` values under both profiles.
* `emqx ctl data encrypt` on a plaintext backup produces a `<name>.tar.gz.enc`
  that imports through the API under a provisioned key, and `emqx ctl data decrypt`
  round-trips it back to the original `tar.gz`.
* Confirm CLI import is exempt and is audited as a bypass.
* Confirm the `x-encryption-key` header is redacted in the audit log and traces,
  for both a plaintext value and a `file://` value.
* Confirm the CLI does not accept an inline key argument, and that a `file://` or
  stdin key never appears in the process arguments.
* Round-trip a backup between two clusters with a key exchanged through `ctl`.
* Key rotation: an archive made with an older provisioned key still imports after
  a new key is added, and stops importing after the old key is deleted.

## Declined Alternatives

* **Digital signatures with an on-cluster signing key.** Signing gives integrity
  and provenance but not confidentiality, and an automatic on-cluster signer
  requires the private key to live on every node that can create a backup, which
  is a cluster-wide secret and a larger attack surface. AEAD encryption with an
  operator-supplied key gives integrity and confidentiality together and leaves
  the producing cluster stateless.
* **Asymmetric signatures for untrusted importers.** Asymmetric signing lets a
  producer sign with a private key while importers verify with a public key, so
  an importer cannot forge a backup the producer would be blamed for. This is the
  only model that defends across organization boundaries. It is heavier: it needs
  key generation, public-key distribution, key identifiers, and rotation, and it
  still needs separate encryption for confidentiality. It is deferred. The
  symmetric scheme here covers the same-operator case, which is the common one.
  Asymmetric signing can be added later for the cross-organization case without
  changing the archive-is-authenticated-before-extract model.
* **Carrying the import key in the import request.** This would let a caller who
  reaches the import endpoint supply both a crafted archive and a key that
  decrypts it, which provides no protection. The import key must come from `ctl`
  provisioning, which the caller does not control.
* **Relaxing verification for old-version backups.** Any rule of the form "skip
  the check when the archive says it is old" is defeated by an attacker labeling a
  crafted archive as old. The requirement is a node policy, and the archive
  version never relaxes it.
* **Passing the create key in the request body.** A body field would rely on
  key-name based redaction in the audit log, so it would either leak or require
  adding a common name such as `key` to the global sensitive-key list, which
  over-redacts unrelated configuration. An `x-encryption-key` header uses the
  separate sensitive-header list, which is the correct tool for a per-request
  secret.
* **Plain, non-authenticated encryption.** Encryption without an authentication
  tag gives confidentiality but not tamper detection, so it would still need a
  separate MAC. AEAD provides both and avoids a second primitive.
* **A persisted node-level encryption key.** A key configured on the cluster
  removes the per-request key-handling step but reintroduces a cluster-wide secret
  on every node. The ad-hoc, operator-supplied key keeps the producing cluster
  stateless. A persisted key may be offered later as an explicit convenience
  option for operators who accept the weaker posture.
