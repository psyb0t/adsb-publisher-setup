# Changelog

All notable changes per release. Versions follow [semver](https://semver.org).

## v1.1.4 — 2026-08-01

Infrastructure only. Nothing in this repository's own code changed — every
commit in this release touches `.github/workflows/`.

- The pipeline was split: building and publishing stay in `pipeline.yml`, and
  everything that leaves the host now lives beside it in
  `mirror-and-archive.yml`.
- The repository is mirrored to Codeberg as well as GitLab.
- It is archived to the Wayback Machine, Software Heritage, and archive.org.
- Issues opened on either mirror are copied back to GitHub every six hours, and
  the GitHub copy is closed when the original closes.
- Pull requests are switched off on both mirrors. They are force-pushed from
  GitHub, so anything merged on a mirror would be destroyed by the next sync.
  Issues and forking stay enabled.

## v1.1.3 — 2026-07-27

- Added a GitHub Actions CI status badge to the README.

## v1.1.2 — 2026-07-27

Add README status badges.

- Added self-hosted version and license badges (rendered as SVGs on the `badges` branch by the `create-badges` CI job, no third-party render service). Added a pipeline.yml running the badges job.
