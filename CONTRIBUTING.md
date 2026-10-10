# Contributing

## Quick start

- **Bugs:** Open an issue using the bug-report template.
- **Features:** Open an issue using the feature-request template.
- **PRs:** Fork, branch from `develop`, keep the change focused, open against `develop`.

```bash
shellcheck -S warning -s bash scripts/*.sh
make image
make fetch
make config
```

## Conventions

- Prefix commits semantically (`feat:`, `fix:`, `docs:`, `ci:`, `deps:`).
- One logical change per PR.
- Make sure CI is green before requesting review.

## License

By contributing, you agree that your contributions will be licensed under the project's GPL-2.0 license.
