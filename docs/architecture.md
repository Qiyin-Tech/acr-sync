# Architecture

## Goal and constraints

The repository supports two related tasks: copying one tagged image through a reusable GitHub composite action, and synchronizing a repository-owned list of public Docker Hub images.

The design keeps these constraints explicit:

- `tag` is required; digest selection is not supported.
- The reusable action and manual workflow default `arch` to `amd64`; callers can explicitly select one other architecture.
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

repository batch workflow          organization policy and scheduling
    |
skopeo-sync.yaml                  native Skopeo source contract
    |
    +---- skopeo sync ----------> Docker Hub and ACR
```

### Composite action

The root `action.yml` is the reusable contract and GitHub runner adapter. It owns required inputs, reference validation and mapping, Skopeo availability, temporary credential-file lifecycle, optional source authentication, GHCR fallback authentication through the caller's `GITHUB_TOKEN`, and ACR authentication through explicitly passed organization configuration. Credentials are not command-line arguments and the temporary auth file is removed after each invocation.

Source credentials form one optional pair. If both are absent, non-GHCR sources are read anonymously and GHCR falls back to the caller token. If both are present, the action derives the source Registry hostname from `source` and authenticates before copying. Supplying only one value is an input error.

GitHub downloads the action at the exact `@tag` or `@SHA` selected by the caller. This removes the cross-repository checkout problem.

The repository-local manual workflow owns the organization defaults for architecture and the Chengdu ACR address. It maps `vars.ACR_USERNAME` and `secrets.ACR_PASSWORD` to action inputs. It does not bind generic source credentials because the manually entered source Registry is not fixed. Public sources are anonymous; GHCR can still use the action's domain-specific caller-token fallback. The workflow checks out the selected repository ref and invokes the local action with `uses: ./`, so manual runs exercise the action from the same revision.

### Native single-image copy

The action invokes `skopeo copy` directly with `--override-arch`, `--preserve-digests`, and `--digestfile`. It does not use a repository-owned copy wrapper. Skopeo checks each selected-platform blob at the target repository and uploads only missing blobs. The digest file reports the copied single-platform manifest without two additional remote inspections.

The action defaults `arch` to `amd64` and requires `target_registry` explicitly. The Chengdu ACR default belongs only to the manual workflow; it is organization policy rather than an invariant of the copy operation.

## Alternatives considered

| Candidate | Current simplicity | Single-image reuse | Version correctness | Batch evolution | Decision |
| --- | --- | --- | --- | --- | --- |
| Put every command directly in a reusable workflow | High initially | Poor | Self-contained | Duplicates copy rules later | Rejected |
| Reusable workflow checks out and runs this repository's script | Medium | Good | Checkout targets the caller repository by default; private cross-repo checkout also needs extra credentials | Fragile | Rejected |
| Versioned composite action invokes `skopeo copy` directly | High | Good | One versioned action contract | Batch can use native `skopeo sync` | Chosen |
| Build a general manifest engine now | Low | Good | Unclear until manifest contract exists | Predicts unconfirmed schema and policy | Deferred |

## Public Docker Hub batch boundary

`skopeo-sync.yaml` is parsed directly by `skopeo sync --src yaml`; this repository does not define a second schema or write a manifest adapter. The YAML owns only source registry, repository, and tag selection. It must not contain credentials or target policy.

The repository-local batch workflow owns:

- workflow scheduling and organization defaults;
- credential mapping;
- target Registry and namespace;
- the selected single architecture;
- Skopeo retry and keep-going behavior.

Native `skopeo sync --src yaml --dest docker` copies grouped repositories and tags in one process. This retains Registry-side layer reuse and reduces repeated process, authentication, and connection setup.

Without `--scoped`, Skopeo appends each source repository basename to the destination. This matches the current target contract but creates a collision if two configured repositories share a basename. `--scoped` preserves the full source path but changes target names. A custom manifest engine is justified only if a real requirement needs per-image target mappings that neither behavior can represent.

## Re-evaluation triggers

Revisit these boundaries when one of the following becomes real:

- target tags must differ from source tags;
- target repository names can no longer be derived from the source basename;
- batch execution needs cross-image dependency ordering or transactional semantics;
- Skopeo installation time becomes a measured bottleneck and justifies a pinned runner image.

No independent high-privilege test or Agent debug surface is part of the current design.
