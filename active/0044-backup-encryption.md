# Encrypted and Authenticated Data Backups

## Changelog

* 2026-08-12: @zmstone Initial draft

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

* **Create.** The operator supplies the key in the create-backup request or CLI
  invocation. EMQX uses it to encrypt and then discards it. The key is supplied
  only as a `file://` reference, never inline. An inline CLI argument is visible
  through the process table and shell history, and an inline request body is
  recorded by the audit log. `file://` keeps the key out of both.
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

### Node policy

Whether encryption is required is a property of the importing node, not of the
archive. A node setting `data_backup.import.require_encryption` controls it, and
it defaults to on under the hardened security profile. When the setting is on,
an API import must be an encrypted archive that authenticates under a provisioned
key; a plaintext or wrongly-keyed archive is rejected. When it is off, plaintext
import keeps working.

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
* Temporarily set `require_encryption` to off for a maintenance window, which is
  an explicit and audited configuration change.

### Auditing

The audit log records every import: the key identifier that decrypted a
successful import, and every rejected attempt as a security event. A CLI import
that bypasses the requirement is recorded as such. The create-backup key is a
`file://` reference and is never recorded.

## Configuration Changes

* `data_backup.import.require_encryption`: boolean. Default off under the legacy
  profile, on under the hardened profile. When on, REST API import requires an
  encrypted archive that authenticates under a provisioned key.
* Backup-key store on the importer, populated through new `ctl` commands, for
  example:
  * `emqx ctl data import-key add <key-id> file://<path>`
  * `emqx ctl data import-key list`
  * `emqx ctl data import-key delete <key-id>`
* Create-backup accepts an optional key parameter, supplied only as a `file://`
  reference, on both the REST API and the CLI. When absent, the backup is
  plaintext as today.

The AEAD ciphertext and its cleartext header are new members of the backup
archive layout. `META.hocon` gains no secret material; the wrapped data key, key
identifier, cipher, and nonce live in the header.

## Backwards Compatibility

The feature is opt-in and off by default under the legacy profile.

* Existing plaintext backups continue to import unchanged while
  `require_encryption` is off.
* A create request without a key produces a plaintext backup, as today.
* Under the hardened profile, `require_encryption` defaults on, which is a
  behavior change for hardened deployments: plaintext API import is rejected, and
  operators use the CLI, re-encryption, or an explicit policy relaxation for old
  backups. This is called out as an intentional hardening default.

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
* Enforce `require_encryption`: plaintext API import is rejected when on and
  accepted when off.
* Confirm CLI import is exempt and is audited as a bypass.
* Confirm the create key is accepted only as `file://` and never appears in the
  audit log or process arguments.
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
* **Plain, non-authenticated encryption.** Encryption without an authentication
  tag gives confidentiality but not tamper detection, so it would still need a
  separate MAC. AEAD provides both and avoids a second primitive.
* **A persisted node-level encryption key.** A key configured on the cluster
  removes the per-request key-handling step but reintroduces a cluster-wide secret
  on every node. The ad-hoc, operator-supplied key keeps the producing cluster
  stateless. A persisted key may be offered later as an explicit convenience
  option for operators who accept the weaker posture.
