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
sync.yml                          alias, arch list, target namespace,
    |                             and manifest path
    |
manifest/*.yml                    native Skopeo source contracts
    |
    +---- skopeo sync ----------> Docker Hub and ACR
```

### Composite action

The root `action.yml` is the reusable contract and thin GitHub runner adapter. It owns input declarations and context-to-environment mapping. `scripts/sync-image`, downloaded as part of the same versioned action, owns reference validation and mapping, Skopeo availability, temporary credential-file lifecycle, optional source authentication, GHCR fallback authentication through the caller's `GITHUB_TOKEN`, and ACR authentication. Credentials are not command-line arguments and the temporary auth file is removed after each invocation.

Source credentials form one optional pair. If both are absent, non-GHCR sources are read anonymously and GHCR falls back to the caller token. If both are present, the action derives the source Registry hostname from `source` and authenticates before copying. Supplying only one value is an input error.

GitHub downloads the action and `scripts/sync-image` at the exact `@tag` or `@SHA` selected by the caller. The metadata invokes it through `github.action_path`, so no second checkout is required.

The repository-local manual workflow owns the organization default for architecture. The caller maps `vars.ACR_ENDPOINT`, `vars.ACR_USERNAME`, and `secrets.ACR_PASSWORD` to the action's `acr_endpoint`, `acr_username`, and `acr_password` inputs. The composite metadata then maps those inputs to the script environment, keeping the public caller contract uniform while preventing credentials from becoming command-line arguments. The workflow does not bind generic source credentials because the manually entered source Registry is not fixed. Public sources are anonymous; GHCR can still use the action's domain-specific caller-token fallback. The workflow checks out the selected repository ref and invokes the local action with `uses: ./`, so manual runs exercise the action from the same revision.

### Native single-image copy

`scripts/sync-image` invokes `skopeo copy` with `--override-arch`, `--preserve-digests`, and `--digestfile`. It is a runner adapter, not a second copy engine: layer discovery and transfer remain native Skopeo behavior. Skopeo checks each selected-platform blob at the target repository and uploads only missing blobs. The digest file reports the copied single-platform manifest without two additional remote inspections.

The action defaults `arch` to `amd64`. The required `acr_endpoint` input accepts the caller-visible organization variable `ACR_ENDPOINT`; the action maps it to the internal script environment alongside the ACR credential inputs.

## Alternatives considered

| Candidate | Current simplicity | Single-image reuse | Version correctness | Batch evolution | Decision |
| --- | --- | --- | --- | --- | --- |
| Put every command directly in a reusable workflow | High initially | Poor | Self-contained | Duplicates copy rules later | Rejected |
| Reusable workflow checks out and runs this repository's script | Medium | Good | Checkout targets the caller repository by default; private cross-repo checkout also needs extra credentials | Fragile | Rejected |
| Versioned composite action invokes its versioned runner script | High | Good | Metadata and script share one action version | Batch can use native `skopeo sync` | Chosen |
| Build a general manifest engine now | Low | Good | Unclear until manifest contract exists | Predicts unconfirmed schema and policy | Deferred |

## Manifest batch boundary

Files under `manifest/` are parsed directly by `skopeo sync --src yaml`; this repository does not define a second image-selection schema or write a manifest adapter. Each manifest owns only source registry, repository, and tag selection. It must not contain credentials or target policy.

`sync.yml` is a repository policy index keyed by a stable alias. Each alias owns `archs`, `target_namespace`, and `manifest_path`, which Skopeo's source YAML cannot express. A manual run selects only the alias name; a push run maps changed manifest paths back to aliases. The ACR endpoint remains organization policy in `vars.ACR_ENDPOINT`.

`archs` is structurally a list so aliases expand uniformly into the workflow matrix. The current contract permits one entry per alias: separate single-platform jobs writing the same tags would overwrite each other rather than assemble a multi-platform index. Matrix preparation rejects that unsafe configuration until explicit index assembly is implemented.

The repository-local batch workflow owns:

- the `main` branch path trigger for `sync.yml` and `manifest/**`, manual reruns, and serialization;
- changed-path selection for push events and forced alias selection for manual events;
- workflow-level organization defaults;
- credential mapping;
- target Registry and namespace;
- architecture matrix expansion;
- Skopeo retry and keep-going behavior.

Long orchestration logic lives in repository scripts rather than inline workflow YAML. `scripts/prepare-sync-matrix` reads `sync.yml` with `yq`, validates references, and emits the GitHub matrix. `scripts/sync-manifest` owns temporary authentication state and invokes native `skopeo sync`. This is repository-local batch machinery; it does not change the cross-repository composite action contract.

Push selection skips an existing empty manifest with an explicit warning, allowing an alias to be reserved before its image list is populated. Manual selection treats the same state as an error because it is a forced execution. A missing referenced file is always an error.

For GHCR manifests, the workflow grants `packages: read` and passes its automatic `GITHUB_TOKEN` to the sync script. A private package must grant this repository Actions access. No source token is stored in either YAML file.

Native `skopeo sync --src yaml --dest docker` copies grouped repositories and tags in one process. This retains Registry-side layer reuse and reduces repeated process, authentication, and connection setup.

Without `--scoped`, Skopeo appends each source repository basename to the destination. This matches the current target contract but creates a collision if two configured repositories share a basename. `--scoped` preserves the full source path but changes target names. A custom manifest engine is justified only if a real requirement needs per-image target mappings that neither behavior can represent.

## Re-evaluation triggers

Revisit these boundaries when one of the following becomes real:

- target tags must differ from source tags;
- target repository names can no longer be derived from the source basename;
- batch execution needs cross-image dependency ordering or transactional semantics;
- Skopeo installation time becomes a measured bottleneck and justifies a pinned runner image.

No independent high-privilege test or Agent debug surface is part of the current design.
