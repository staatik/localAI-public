# Contributing

Thanks for helping improve this project.

## Pull Requests

- Open pull requests from a branch or fork.
- Keep changes focused and explain the deployment impact.
- Do not include real secrets, local IP addresses, private hostnames, generated certificates, service exports, or logs.
- Update the README when changing setup steps, environment variables, ports, paths, or service behavior.
- Run `docker compose config` for any compose file you modify.

## Security-Sensitive Changes

For anything involving authentication, secrets, TLS material, network exposure, or default permissions, explain the security tradeoff in the pull request description.

## Issues

Use public issues for documentation improvements, setup bugs, and non-sensitive feature requests. Use the security reporting process in `SECURITY.md` for vulnerabilities or accidental secret exposure.
