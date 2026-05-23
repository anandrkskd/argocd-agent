# Proposal: Helm Chart Release Automation

**Author:** Anand Kumar Singh
**Date:** 2026-05-23
**Status:** Draft

## Summary

Automate Helm chart versioning and publishing as part of the existing release pipeline. Currently, the `init-release` and `release` workflows handle VERSION file updates, Kustomize manifests, container images, CLI binaries, SBOMs, and provenance attestations -- but the Helm chart at `install/helm-repo/argocd-agent-agent/` is not updated or published.

This proposal adds two capabilities:

1. **Version bumping** during release initialization (`init-release.yaml`)
2. **OCI-based chart publishing** to quay.io during release (`release.yaml`)

## Motivation

- Chart `appVersion` and `values.yaml` image tag must be updated manually each release -- easy to forget and causes drift between the container image and chart defaults.
- The chart is not published to any registry, requiring users to clone the repo and install from source.
- OCI-based Helm registries are the standard distribution mechanism since Helm 3.8+.

## Design

### 1. Release Initialization (`init-release.yaml`)

Add two steps to the existing `init-release` workflow:

#### Install yq

Reuse the exact `yq` v4.53.2 installation pattern already in `ci.yaml` (SHA-256 verified binary download). This ensures consistency across workflows and makes version upgrades straightforward.

#### Update Helm chart versions

Using `yq` (not `sed`), update three fields:

| File | Field | Value |
|------|-------|-------|
| `Chart.yaml` | `appVersion` | `v${TARGET_VERSION}` |
| `Chart.yaml` | `version` | Current patch + 1 (e.g., `0.2.0` -> `0.2.1`) |
| `values.yaml` | `image.tag` | `v${TARGET_VERSION}` |

**Why `yq` over `sed`:** `values.yaml` contains two `tag:` fields -- `image.tag` (line 20) and `tests.tag` (line 298). The `yq` path `.image.tag` targets the correct field without ambiguity.

**Chart version strategy:** The chart version `Z`-stream (patch) is auto-incremented by 1 on each release. Major/minor bumps remain manual for intentional breaking changes or feature additions to the chart itself (as opposed to the application).

These changes are included in the PR created by `peter-evans/create-pull-request`, so they go through normal review before merge.

#### Updated step order

```
1. Checkout source code
2. Export current version
3. Validate provided version
4. Update VERSION file
5. Install Kustomize
6. Install yq                    <-- NEW
7. Generate new manifests
8. Update Helm chart versions    <-- NEW
9. Print changes to be pushed
10. Create PR
```

### 2. Release Publishing (`release.yaml`)

Add a new `helm-chart` job that runs in parallel with `container-image` (both depend only on `setup-variables`):

```
setup-variables
  |
  +-- container-image --> container-provenance --> cli-binaries --> ...
  |
  +-- helm-chart (NEW, runs in parallel)
```

#### Job steps

1. **Checkout code** -- same pinned `actions/checkout` as other jobs
2. **Install Helm** -- `azure/setup-helm` v5.0.0, Helm v3.20.2 (matches `ci.yaml`)
3. **Login to OCI registry** -- `helm registry login` using existing `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` secrets (same credentials as container image push)
4. **Package chart** -- `helm package install/helm-repo/argocd-agent-agent`
5. **Push to OCI registry** -- `helm push <package>.tgz oci://quay.io/argoproj-labs`

#### Registry location

The chart is pushed to:

```
oci://quay.io/argoproj-labs/argocd-agent-agent
```

Users install via:

```bash
helm install argocd-agent oci://quay.io/argoproj-labs/argocd-agent-agent --version <chart-version>
```

This co-locates the chart with the container image (`quay.io/argoproj-labs/argocd-agent`) under the same registry namespace.

#### Permissions

The job requires only `contents: read`. No additional secrets are needed -- it reuses the existing `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` secrets already configured for quay.io container image pushes.

#### Fork support

The job respects the existing fork release mechanism: it runs when `github.repository == 'argoproj-labs/argocd-agent'` or `allow_fork_releases == 'true'`, using the configurable `IMAGE_REPOSITORY` and `IMAGE_NAMESPACE` variables.

## CI Validation

No new CI validation steps are required. The existing `validate-helm-charts` job in `ci.yaml` automatically triggers on changes to `install/helm-repo/**` and runs:

- `make validate-values-schema` (schema validation + `helm lint`)
- `helm-docs` with `fail-on-diff: true` (documentation freshness)

## Files Changed

| File | Change |
|------|--------|
| `.github/workflows/init-release.yaml` | Add `Install yq` and `Update Helm chart versions` steps; update PR body text |
| `.github/workflows/release.yaml` | Add `helm-chart` job for OCI packaging and push |

## Prerequisites

- The quay.io repository `argoproj-labs/argocd-agent-agent` must exist (or quay.io must be configured to auto-create repositories on push). The existing `REGISTRY_USERNAME` account needs push access to this repository.

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `yq` reformats YAML whitespace/comments | Low | `yq` v4 preserves comments; verify in init-release PR review |
| quay.io repo `argocd-agent-agent` doesn't exist | One-time | Create repo before first release, or enable auto-create in quay.io org settings |
| Chart version collision if release re-run | Low | OCI registries allow overwriting same tag; chart version is deterministic from `Chart.yaml` state |
| Future charts added (e.g., principal) | Medium | Extend the steps to loop over chart directories; document pattern |

## Future Considerations

- **Chart signing with Cosign:** Similar to container image signing already in the pipeline. Can be added as a follow-up.
- **Chart provenance attestation:** SLSA provenance for the Helm chart OCI artifact, matching the existing container and CLI provenance jobs.
- **Helm chart testing:** Integration test job that deploys the packaged chart to a kind cluster before publishing.
