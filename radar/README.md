# Radar Helm Repository

This directory contains the Redis Radar Helm chart published at
`https://helm.redis.io/radar`.

Chart layout:

- `radar/charts/radar`

## Making Changes

Unlike the other charts in this monorepo, the radar chart is **not authored
here**. Its source of truth is the Radar application repository
(`redislabsdev/radar`, `helm/radar`), which develops and tests the chart
alongside the application. For each Radar release, that repository's
`Publish Helm Chart (on-prem)` workflow produces a publishable copy — chart
`version`/`appVersion` stamped from the release tag, image defaults pointed
at the public Docker Hub images, internal overlays stripped, and the
PostgreSQL subchart vendored — which is synced into `radar/charts/radar`
via a PR to this repository.

Do not hand-edit `radar/charts/radar` except to fix a broken release; send
chart changes to the Radar repository instead so they are not overwritten by
the next sync.

## Local Validation

```bash
helm lint radar/charts/radar
helm template radar radar/charts/radar \
  --set database.host=postgres.example \
  --set database.url='postgres://user:pass@postgres.example:5432/radar?sslmode=disable'
```

## Release Process

Radar chart releases are manual and run only from `master`.

- workflow: `.github/workflows/release-radar.yaml`
- chart: `radar/charts/radar`
- publication target: `gh-pages/radar/index.yaml`

Release steps:

1. Merge the sync PR (from the Radar repository's publish workflow) to
   `master`; it carries the desired `version` in
   `radar/charts/radar/Chart.yaml`.
2. In GitHub Actions, run `Release Redis Radar Chart` from `master`.

The workflow reads the chart version from `Chart.yaml`, creates the tag
`radar-<version>`, packages and publishes the chart to this repository's
GitHub Releases, and updates the index under `gh-pages/radar/`.

## Consuming The Repo

```bash
helm repo add radar https://helm.redis.io/radar
helm repo update radar
helm search repo radar/radar --versions
```
