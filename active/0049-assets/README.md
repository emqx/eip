# Prototype evidence for EIP 0049

These are reports from the author's Rustls MQTT listener 0.5.0 prototype,
measured on 2026-10-29. They support the proposal's motivation and describe
qualification limits; they are not independent certification.

The EIP proposes a plugin-owned configuration interface. The measured prototype
still used the disabled SSL profile and side file described in the migration
section. The proposed interface was not part of these tests.

| File | Contents |
|---|---|
| [functional-validation.json](functional-validation.json) | Three official EMQX releases, test groups, cleanup and prototype source hashes |
| [tls-probe-report.txt](tls-probe-report.txt) | Public TLS probe scope, failures and limitations |
| [tls-probe-verification.json](tls-probe-verification.json) | TLS probe counters and harness/log hashes |
| [performance-report.txt](performance-report.txt) | Benchmark method, individual trials and pooled results |
| [performance-verification.json](performance-verification.json) | Numeric summaries, trial values and comparison calculations |
| [benchmark-method.txt](benchmark-method.txt) | Commands and measurement definitions used in the prototype workspace |
| [provenance.json](provenance.json) | Original relative paths and SHA256 of the copied reports |

The native package, prototype implementation, complete traffic histograms and
runtime logs are not published in this EIP PR. Commands and relative source paths
in these records refer to that prototype workspace. Independent reproduction
requires a subsequent implementation/source publication with those artifacts;
these reports alone do not provide it.

The functional manifest retains original test labels. Some rejection labels
refer to a TLS1.3-only or otherwise restricted test configuration; separate
positive groups cover TLS1.2 and the additional features. Read the labels with
the declared profile and the TLS probe report's limits.

No benchmark or protocol suite was rerun for this documentation PR. Local
publication checks verified the recorded prototype source/package hashes and
that these report copies are byte-identical to their recorded originals.
