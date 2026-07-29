# Architecture

## Goal and constraints

The current product task is to copy one tagged image to ACR through a reusable GitHub composite action. The next known task is repository-owned manifest batch synchronization, including public Docker Hub images.

The design keeps these constraints explicit:

- `tag` is required; digest selection is not supported.
- A source tag is copied to the same target tag.
- The target repository is `<target-registry>/<target-namespace>/<source-basename>`.
- ACR credentials come from organization Actions secrets.
- A multi-architecture source must remain multi-architecture at the target.
- The single-image behavior must be reusable without GitHub workflow syntax.

## Chosen boundaries

```text
caller/manual workflow            organization policy
    |                             runner, defaults, permissions, secret mapping
    v
versioned composite action        public contract and runner integration
    |                             Skopeo installation, auth lifecycle
    v
scripts/sync-image.sh             single-image domain operation
    |                             validation, mapping, copy, verification
    +---------------------------> source registry
    |
    +---------------------------> ACR

future batch workflow/script
    |                             manifest parsing, concurrency, failure policy
    +---- invokes the same composite action or single-image script per entry
```

### Composite action

The root `action.yml` is the reusable contract and GitHub runner adapter. It owns required inputs, Skopeo availability, temporary credential-file lifecycle, optional source authentication, GHCR fallback authentication through the caller's `GITHUB_TOKEN`, and ACR authentication through explicitly passed organization secrets. Credentials are not command-line arguments and the temporary auth file is removed after each invocation.

Source credentials form one optional pair. If both are absent, non-GHCR sources are read anonymously and GHCR falls back to the caller token. If both are present, the action derives the source Registry hostname from `source` and authenticates before copying. Supplying only one value is an input error.

GitHub downloads the action and its scripts at the exact `@tag` or `@SHA` selected by the caller. This removes the cross-repository checkout problem and keeps the action metadata and script version together.

The repository-local manual workflow owns the organization default for the Chengdu ACR address and maps only the target ACR organization secret names to action inputs. It does not bind generic source credentials because the manually entered source Registry is not fixed. Public sources are anonymous; GHCR can still use the action's domain-specific caller-token fallback. The workflow checks out the selected repository ref and invokes the local action with `uses: ./`, so manual runs exercise the action and script from the same revision.

### Single-image script

`scripts/sync-image.sh` is the authoritative implementation of image-reference validation, target-name construction, Registry-to-Registry copying, and digest verification. It knows nothing about GitHub contexts or organization secret names.

Its contract is intentionally narrow:

```text
sync-image.sh
  --source <registry/repository/image>
  --tag <tag>
  --target-namespace <namespace>
  [--target-registry <registry>]
```

Authentication is supplied through Skopeo's `REGISTRY_AUTH_FILE`. This keeps secret acquisition outside the copy operation and allows the same operation to run locally, from a composite action, or from a future batch driver.

The script requires `--target-registry` explicitly. The composite action also requires `target_registry`. The Chengdu ACR default belongs only to the manual workflow; it is organization policy rather than an invariant of the copy operation.

## Alternatives considered

| Candidate | Current simplicity | Single-image reuse | Version correctness | Batch evolution | Decision |
| --- | --- | --- | --- | --- | --- |
| Put every command directly in a reusable workflow | High initially | Poor | Self-contained | Duplicates copy rules later | Rejected |
| Reusable workflow checks out and runs this repository's script | Medium | Good | Checkout targets the caller repository by default; private cross-repo checkout also needs extra credentials | Fragile | Rejected |
| Versioned composite action → single-image script | High | Good | Action and script are downloaded from the same ref | Batch layer can reuse the same primitive | Chosen |
| Build a general manifest engine now | Low | Good | Unclear until manifest contract exists | Predicts unconfirmed schema and policy | Deferred |

## Future batch boundary

The batch layer should be added only after its manifest contract is known. It should own:

- manifest parsing and schema validation;
- defaults and per-entry overrides;
- concurrency limits;
- fail-fast versus continue-on-error policy;
- batch summary and per-image results.

It should not own image-reference validation, target mapping, Skopeo flags, credential-file format, or digest verification. Those remain in the existing action and script.

Native `skopeo sync` can be reconsidered if the future manifest maps directly to its supported repository/tag model. A custom batch driver is justified only when the manifest needs per-image namespace mapping, heterogeneous source registries, or organization-specific failure policy.

## Re-evaluation triggers

Revisit these boundaries when one of the following becomes real:

- target tags must differ from source tags;
- target repository names can no longer be derived from the source basename;
- batch execution needs cross-image dependency ordering or transactional semantics;
- Skopeo installation time becomes a measured bottleneck and justifies a pinned runner image.

No independent high-privilege test or Agent debug surface is part of the current design.
