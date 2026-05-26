# Security Policy

## Supported Versions

This repository contains deployment configuration and documentation. Security fixes are applied to the latest version on the `main` branch.

## Reporting a Vulnerability

Please do not open a public issue for suspected secrets, credential exposure, or exploitable configuration problems.

Report security issues privately through GitHub's private vulnerability reporting if it is available on this repository. If private reporting is not available, contact the repository owner directly and include:

- The affected file or configuration area
- A short description of the impact
- Reproduction steps or evidence, if safe to share
- Any suggested mitigation

## Secrets

Never commit real `.env` files, TLS private keys, generated certificates, database dumps, backups, or exported service data. Use the committed `.env.example` files as templates only.
