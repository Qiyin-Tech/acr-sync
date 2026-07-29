#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sync-image.sh \
    --source <registry/repository/image> \
    --tag <tag> \
    --target-namespace <namespace> \
    --target-registry <registry>

Example:
  sync-image.sh \
    --source ghcr.io/qiyin-tech/orchestra-backend \
    --tag v1.2.3 \
    --target-namespace qiyin \
    --target-registry acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"

  [[ -n "${value}" && "${value}" != --* ]] ||
    fail "${option} requires a value"
}

source_image=""
tag=""
target_namespace=""
target_registry=""

while (( $# > 0 )); do
  case "$1" in
    --source)
      require_value "$1" "${2:-}"
      source_image="$2"
      shift 2
      ;;
    --tag)
      require_value "$1" "${2:-}"
      tag="$2"
      shift 2
      ;;
    --target-namespace)
      require_value "$1" "${2:-}"
      target_namespace="$2"
      shift 2
      ;;
    --target-registry)
      require_value "$1" "${2:-}"
      target_registry="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ -n "${source_image}" ]] || fail "--source is required"
[[ -n "${tag}" ]] || fail "--tag is required"
[[ -n "${target_namespace}" ]] || fail "--target-namespace is required"
[[ -n "${target_registry}" ]] || fail "--target-registry is required"

source_image="${source_image#docker://}"
source_image="${source_image%/}"
target_registry="${target_registry#https://}"
target_registry="${target_registry#http://}"
target_registry="${target_registry%/}"
target_namespace="${target_namespace#/}"
target_namespace="${target_namespace%/}"

image_name="${source_image##*/}"

[[ "${source_image}" == */* ]] ||
  fail "--source must include a registry or namespace"
[[ "${image_name}" != *:* && "${image_name}" != *@* ]] ||
  fail "--source must not include a tag or digest"
[[ "${image_name}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] ||
  fail "source image name is not a valid lowercase repository name"
[[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
  fail "--tag is not a valid container image tag"
[[ "${target_namespace}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]] ||
  fail "--target-namespace is not a valid lowercase repository path"
[[ -n "${target_registry}" && "${target_registry}" != */* ]] ||
  fail "--target-registry must be a registry hostname without a path"

skopeo_bin="${SKOPEO_BIN:-skopeo}"
command -v "${skopeo_bin}" >/dev/null 2>&1 ||
  fail "Skopeo is not installed or SKOPEO_BIN is invalid"

source_ref="docker://${source_image}:${tag}"
target_ref="docker://${target_registry}/${target_namespace}/${image_name}:${tag}"

copy_args=(copy --all --preserve-digests)
if [[ -n "${REGISTRY_AUTH_FILE:-}" ]]; then
  [[ -f "${REGISTRY_AUTH_FILE}" ]] ||
    fail "REGISTRY_AUTH_FILE does not exist: ${REGISTRY_AUTH_FILE}"
  copy_args+=(--authfile "${REGISTRY_AUTH_FILE}")
fi

printf 'Syncing %s -> %s\n' "${source_ref}" "${target_ref}"
"${skopeo_bin}" "${copy_args[@]}" "${source_ref}" "${target_ref}"

inspect_args=(inspect)
if [[ -n "${REGISTRY_AUTH_FILE:-}" ]]; then
  inspect_args+=(--authfile "${REGISTRY_AUTH_FILE}")
fi

source_digest="$("${skopeo_bin}" "${inspect_args[@]}" --format '{{.Digest}}' "${source_ref}")"
target_digest="$("${skopeo_bin}" "${inspect_args[@]}" --format '{{.Digest}}' "${target_ref}")"

[[ -n "${source_digest}" && -n "${target_digest}" ]] ||
  fail "digest verification returned an empty digest"
[[ "${source_digest}" == "${target_digest}" ]] ||
  fail "digest verification failed: source=${source_digest}, target=${target_digest}"

printf 'Verified target digest: %s\n' "${target_digest}"
