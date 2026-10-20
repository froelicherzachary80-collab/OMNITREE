# Privacy

- **Local-only by default.** All data is stored in your browser's IndexedDB. OmniTree makes no network requests with your data, and cloud sync does not exist.
- **DNA.** Files are parsed in a Web Worker in the browser. Once a vault passphrase is set, kits are stored encrypted with AES-256-GCM, using a key derived with PBKDF2-SHA256 (310k iterations) through the browser's built-in WebCrypto. Without the passphrase, an encrypted kit cannot be recovered.
- **Logs.** The audit log stores only actions and record metadata, never genotypes. A test checks this.
- **AI.** OmniAI runs locally. Its retrieval summaries leave out DNA and hide the details of people marked living-private. Nothing is sent to third-party AI services.
- **Consent.** Uploading a kit requires confirming ownership or consent. Consent to process a kit is not consent to publish it, and there is no publishing feature.
- **Exports.** GEDCOM export can hide living-private people. Backups are passphrase-encrypted, and including DNA is a separate opt-in.
- **Deletion.** "Delete workspace" removes all of the workspace's tables, including DNA.
- **Eviction.** Browsers can clear local storage. OmniTree asks for persistent storage, and you should still keep encrypted backups.
- **Fixtures.** Every bundled sample person and genotype is synthetic and fictional.
