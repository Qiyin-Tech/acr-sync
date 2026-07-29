#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SYNC_SCRIPT="${REPO_ROOT}/scripts/sync-image.sh"

test_dir="$(mktemp -d)"
cleanup() {
  rm -f "${test_dir}/skopeo" "${test_dir}/copy-args" "${test_dir}/auth.json"
  rmdir "${test_dir}" 2>/dev/null || true
}
trap cleanup EXIT

cat > "${test_dir}/skopeo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  copy)
    printf '%s\n' "$@" > "${SKOPEO_TEST_COPY_ARGS}"
    ;;
  inspect)
    printf '%s\n' "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ;;
  *)
    printf 'unexpected fake Skopeo command: %s\n' "${1:-}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${test_dir}/skopeo"
touch "${test_dir}/auth.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
}

SKOPEO_BIN="${test_dir}/skopeo" \
SKOPEO_TEST_COPY_ARGS="${test_dir}/copy-args" \
REGISTRY_AUTH_FILE="${test_dir}/auth.json" \
  "${SYNC_SCRIPT}" \
    --source ghcr.io/qiyin-tech/orchestra-backend \
    --tag v1.2.3 \
    --target-namespace qiyin \
    --target-registry acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com >/dev/null

mapfile -t copy_args < "${test_dir}/copy-args"
[[ "${copy_args[0]}" == "copy" ]] || fail "copy command was not used"
[[ "${copy_args[1]}" == "--all" ]] || fail "--all was not passed"
[[ "${copy_args[2]}" == "--preserve-digests" ]] ||
  fail "--preserve-digests was not passed"
[[ "${copy_args[3]}" == "--authfile" ]] || fail "--authfile was not passed"
[[ "${copy_args[4]}" == "${test_dir}/auth.json" ]] ||
  fail "the expected auth file was not passed"
[[ "${copy_args[5]}" == "docker://ghcr.io/qiyin-tech/orchestra-backend:v1.2.3" ]] ||
  fail "source reference was constructed incorrectly"
[[ "${copy_args[6]}" == "docker://acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com/qiyin/orchestra-backend:v1.2.3" ]] ||
  fail "target reference was constructed incorrectly"

expect_failure env \
  SKOPEO_BIN="${test_dir}/skopeo" \
  "${SYNC_SCRIPT}" \
    --source ghcr.io/qiyin-tech/orchestra-backend \
    --target-namespace qiyin \
    --target-registry acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com

expect_failure env \
  SKOPEO_BIN="${test_dir}/skopeo" \
  "${SYNC_SCRIPT}" \
    --source ghcr.io/qiyin-tech/orchestra-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --tag v1.2.3 \
    --target-namespace qiyin \
    --target-registry acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com

expect_failure env \
  SKOPEO_BIN="${test_dir}/skopeo" \
  "${SYNC_SCRIPT}" \
    --source ghcr.io/qiyin-tech/orchestra-backend \
    --tag v1.2.3 \
    --target-namespace Qiyin \
    --target-registry acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com

expect_failure env \
  SKOPEO_BIN="${test_dir}/skopeo" \
  "${SYNC_SCRIPT}" \
    --source ghcr.io/qiyin-tech/orchestra-backend \
    --tag v1.2.3 \
    --target-namespace qiyin

printf 'PASS: sync-image contract\n'
