# Architecture

## Goal and constraints

The current product task is to copy one tagged image to ACR through a reusable GitHub composite action. The next known task is repository-owned manifest batch synchronization, including public Docker Hub images.

The design keeps these constraints explicit:

- `tag` is required; digest selection is not supported.
- `arch` is required by the reusable action; the manual workflow defaults it to `amd64`.
- A source tag is copied to the same target tag.
- The target repository is `<target-registry>/<target-namespace>/<source-basename>`.
- The target contains the selected single-platform manifest, not the source image index.
- ACR username comes from an organization variable and its password from an organization secret.
- Layer reuse is delegated to Skopeo and the Registry protocol.

## Chosen boundaries

```text
caller/manual workflow            organization policy
    |                             runner, defaults, permissions, secret mapping
    v
versioned composite action        public contract and runner integration
    |                             Skopeo installation, auth lifecycle,
    |                             reference mapping, native copy invocation
    +---------------------------> source registry
    |
    +---------------------------> ACR

future batch workflow/script
    |                             native Skopeo YAML, scheduling, summary
    +---- invokes skopeo sync for grouped repositories and tags
```

### Composite action

The root `action.yml` is the reusable contract and GitHub runner adapter. It owns required inputs, reference validation and mapping, Skopeo availability, temporary credential-file lifecycle, optional source authentication, GHCR fallback authentication through the caller's `GITHUB_TOKEN`, and ACR authentication through explicitly passed organization configuration. Credentials are not command-line arguments and the temporary auth file is removed after each invocation.

Source credentials form one optional pair. If both are absent, non-GHCR sources are read anonymously and GHCR falls back to the caller token. If both are present, the action derives the source Registry hostname from `source` and authenticates before copying. Supplying only one value is an input error.

GitHub downloads the action at the exact `@tag` or `@SHA` selected by the caller. This removes the cross-repository checkout problem.

The repository-local manual workflow owns the organization defaults for architecture and the Chengdu ACR address. It maps `vars.ACR_USERNAME` and `secrets.ACR_PASSWORD` to action inputs. It does not bind generic source credentials because the manually entered source Registry is not fixed. Public sources are anonymous; GHCR can still use the action's domain-specific caller-token fallback. The workflow checks out the selected repository ref and invokes the local action with `uses: ./`, so manual runs exercise the action from the same revision.

### Native single-image copy

The action invokes `skopeo copy` directly with `--override-arch`, `--preserve-digests`, and `--digestfile`. It does not use a repository-owned copy wrapper. Skopeo checks each selected-platform blob at the target repository and uploads only missing blobs. The digest file reports the copied single-platform manifest without two additional remote inspections.

The action requires `arch` and `target_registry` explicitly. The `amd64` and Chengdu ACR defaults belong only to the manual workflow; they are organization policy rather than invariants of the copy operation.

## Alternatives considered

| Candidate | Current simplicity | Single-image reuse | Version correctness | Batch evolution | Decision |
| --- | --- | --- | --- | --- | --- |
| Put every command directly in a reusable workflow | High initially | Poor | Self-contained | Duplicates copy rules later | Rejected |
| Reusable workflow checks out and runs this repository's script | Medium | Good | Checkout targets the caller repository by default; private cross-repo checkout also needs extra credentials | Fragile | Rejected |
| Versioned composite action invokes `skopeo copy` directly | High | Good | One versioned action contract | Batch can use native `skopeo sync` | Chosen |
| Build a general manifest engine now | Low | Good | Unclear until manifest contract exists | Predicts unconfirmed schema and policy | Deferred |

## Future batch boundary

The preferred batch manifest is Skopeo's native YAML source format. The batch layer should own only:

- workflow scheduling and organization defaults;
- credential mapping;
- invocation summary and failure reporting.

Native `skopeo sync --src yaml --dest docker` should copy grouped repositories and tags in one process. This retains Registry-side layer reuse and reduces repeated process, authentication, and connection setup. A custom manifest engine is justified only if required target mappings cannot be represented by Skopeo's native model.

## Re-evaluation triggers

Revisit these boundaries when one of the following becomes real:

- target tags must differ from source tags;
- target repository names can no longer be derived from the source basename;
- batch execution needs cross-image dependency ordering or transactional semantics;
- Skopeo installation time becomes a measured bottleneck and justifies a pinned runner image.

No independent high-privilege test or Agent debug surface is part of the current design.
