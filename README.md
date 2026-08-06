# acr-sync

使用 [Skopeo](https://github.com/podman-container-tools/skopeo) 或 [ORAS](https://oras.land/) 将带 tag 的容器镜像/OCI artifact 同步到阿里云 ACR，不依赖 Docker daemon。

仓库提供两个入口：

- 根目录 `action.yml`：供其他仓库复用，一次同步一个镜像的一个架构。
- `.github/workflows/sync-manifest.yml`：按仓库内的 Skopeo manifest 批量同步。

## 组织配置

调用 workflow 必须能读取以下组织配置：

| 名称 | 类型 | 用途 |
| --- | --- | --- |
| `ACR_ENDPOINT` | Actions variable | ACR endpoint，例如 `acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com` |
| `ACR_USERNAME` | Actions variable | ACR 登录用户名 |
| `ACR_PASSWORD` | Actions secret | ACR 登录密码 |

`ACR_ENDPOINT` 可以带 `http://` 或 `https://`，但不能包含 repository path。调用 composite action 时通过 `acr_endpoint` input 传入。

## 单内容 composite action

### Inputs

| 参数 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `kind` | 否 | `image` | `image` 使用 Skopeo；`artifact` 使用 ORAS 复制 OCI artifact |
| `source` | 是 | - | 不带 tag 或 digest 的源仓库，例如 `ghcr.io/qiyin-tech/orchestra-backend` 或 `ghcr.io/qiyin-tech/1.0-renderer` |
| `tag` | 是 | - | 源 tag；目标使用同一个 tag |
| `arch` | 否 | `amd64` | 单个目标架构，例如 `amd64` 或 `arm64` |
| `target_namespace` | 是 | - | ACR namespace，例如 `qiyin` 或 `public` |
| `acr_endpoint` | 是 | - | ACR registry hostname，通常传入 `${{ vars.ACR_ENDPOINT }}` |
| `source_username` | 否 | 空 | 可选的源 Registry 用户名 |
| `source_password` | 否 | 空 | 可选的源 Registry 密码或 token |
| `acr_username` | 是 | - | ACR 用户名，通常传入 `${{ vars.ACR_USERNAME }}` |
| `acr_password` | 是 | - | ACR 密码，通常传入 `${{ secrets.ACR_PASSWORD }}` |

`source_username` 和 `source_password` 必须同时填写或同时留空。公开 Docker Hub 镜像留空即可。源地址是 `ghcr.io` 且两者留空时，action 使用 `github.actor` 和当前 workflow 的 `GITHUB_TOKEN`。

### Output

| 名称 | 说明 |
| --- | --- |
| `digest` | 已复制的 image/artifact manifest digest |

### 调用示例

使用 `v1` 跟踪当前主版本；需要完全不可变的调用时，将 `@v1` 替换为具体 commit SHA：

```yaml
name: Sync image to ACR

on:
  workflow_dispatch:

permissions:
  contents: read
  packages: read

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - name: Sync image
        id: sync
        uses: Qiyin-Tech/acr-sync@v1
        with:
          kind: image
          source: ghcr.io/qiyin-tech/orchestra-backend
          tag: v1.2.3
          target_namespace: qiyin
          acr_endpoint: ${{ vars.ACR_ENDPOINT }}
          acr_username: ${{ vars.ACR_USERNAME }}
          acr_password: ${{ secrets.ACR_PASSWORD }}

      - name: Print copied digest
        env:
          DIGEST: ${{ steps.sync.outputs.digest }}
        run: echo "${DIGEST}"
```

目标 repository 取源路径最后一段：

```text
ghcr.io/qiyin-tech/orchestra-backend:v1.2.3
  -> ${ACR_ENDPOINT}/qiyin/orchestra-backend:v1.2.3
```

同步 GHCR OCI artifact 时，`source` 和 `tag` 仍然指向 GHCR package，`target_namespace` 可以使用独立的 `binary` namespace：

```yaml
- name: Sync binary artifact to ACR
  uses: Qiyin-Tech/acr-sync@v1
  with:
    kind: artifact
    source: ghcr.io/qiyin-tech/1.0-renderer
    tag: v1.0.0
    target_namespace: binary
    source_username: ${{ github.actor }}
    source_password: ${{ github.token }}
    acr_endpoint: ${{ vars.ACR_ENDPOINT }}
    acr_username: ${{ vars.ACR_USERNAME }}
    acr_password: ${{ secrets.ACR_PASSWORD }}
```

目标为 `${ACR_ENDPOINT}/binary/1.0-renderer:v1.0.0`。artifact 的 manifest 和 zip layer 由 ORAS 原样复制；它不是 Docker image，因此不会使用 BuildKit 的容器分层缓存，但 Registry 仍会按 blob digest 复用已存在的内容。GHCR 等私有源需要凭据，公开 OCI registry 可以匿名读取。

私有 GHCR package 必须允许调用仓库通过 Actions 访问；仅声明 `packages: read` 不会绕过 package 自身的访问控制。

## 本仓库手动同步单个镜像

`.github/workflows/sync-image.yml` 提供 `workflow_dispatch`，表单只包含：

- `source`
- `tag`
- `arch`，默认 `amd64`
- `target_namespace`

该 workflow 检出用户选择的本仓库 ref，然后通过 `uses: ./` 执行同一 ref 的 composite action。表单不提供 ACR endpoint 或通用源仓库凭据输入：

- `acr_endpoint` input 来自 `vars.ACR_ENDPOINT`。
- ACR 用户名和密码来自 `vars.ACR_USERNAME` 与 `secrets.ACR_PASSWORD`。
- 公开源匿名读取。
- GHCR 使用 repository-level `vars.GHCR_USERNAME` 与 `secrets.GHCR_TOKEN`；两者只在 `source` 为 `ghcr.io/...` 时传给 composite action。
- 下游仓库直接调用 composite action 且不传源凭据时，仍回退到调用 workflow 的 `github.actor` 和 `GITHUB_TOKEN`。

## Manifest 批量同步

### 文件职责

```text
sync.yml                  alias、架构、目标 namespace、manifest 路径
manifest/dockerhub.yml    Skopeo 原生 Docker Hub source manifest
manifest/ghcr.yml         Skopeo 原生 GHCR source manifest
```

`manifest/*.yml` 直接交给 `skopeo sync --src yaml`，镜像列表不使用本仓库自定义 schema。例如：

```yaml
docker.io:
  images:
    library/nginx:
      - "stable-alpine3.24-perl"
    bitnami/postgresql:
      - "17"
```

- Docker Hub 官方镜像写成 `library/<name>`。
- 普通仓库保留 Docker Hub namespace。
- tag 建议始终加引号。
- 不要给 repository 配置空 tag 数组；Skopeo 会将其解释为同步全部 tags。
- 凭据不得写入 manifest。

`sync.yml` 当前配置为：

```yaml
dockerhub:
  archs:
    - amd64
  target_namespace: public
  manifest_path: manifest/dockerhub.yml

ghcr:
  archs:
    - amd64
  target_namespace: qiyin
  manifest_path: manifest/ghcr.yml
```

`manifest/ghcr.yml` 当前包含 `~/code/nomad-packs` 的 `main`、`dev` 和全部 Git tags 中出现过的全部默认 GHCR repository/tag。

### 自动与手动选择

`.github/workflows/sync-manifest.yml` 监听 `main` 上的：

```yaml
paths:
  - sync.yml
  - manifest/**
```

push 触发时，`scripts/prepare-sync-matrix` 根据本次 push 的 Git diff 选择 alias：

- `sync.yml` 发生变更：选择全部 alias。
- 某个 manifest 发生变更：只选择 `manifest_path` 指向该文件的 alias。
- 被选中的空 manifest：打印 warning 并跳过。
- 配置引用不存在的 manifest：失败。

手动触发只填写 `sync.yml` 中的 alias `name`，例如 `dockerhub`。手动运行不读取 Git diff，强制执行该 alias；如果对应 manifest 为空则失败。

每个 alias 的 `archs` 会展开成 Actions matrix。当前代码只允许每个 alias 配置一个架构，因为多个单架构 job 写相同目标 tags 时只会互相覆盖，不会自动合并为多架构 index。

`concurrency.group: sync-manifest` 保证不同 workflow run 不会同时执行；同一次 run 内不同 alias 的 matrix jobs 仍可能并行。

### 执行与认证

workflow YAML 只负责 GitHub Actions 编排：

- `scripts/prepare-sync-matrix` 使用 `git`、`yq` 和 `jq` 选择 alias 并输出 matrix。
- `scripts/sync-manifest` 使用 `yq` 检查 manifest，创建临时认证文件，然后直接调用 `skopeo sync`。

批量 workflow 直接读取：

```yaml
ACR_ENDPOINT: ${{ vars.ACR_ENDPOINT }}
ACR_USERNAME: ${{ vars.ACR_USERNAME }}
ACR_PASSWORD: ${{ secrets.ACR_PASSWORD }}
GHCR_USERNAME: ${{ vars.GHCR_USERNAME }}
GHCR_TOKEN: ${{ secrets.GHCR_TOKEN }}
```

`GHCR_USERNAME` 和 `GHCR_TOKEN` 是 `Qiyin-Tech/acr-sync` 的 repository-level Actions variable/secret。`GHCR_TOKEN` 必须是由 `GHCR_USERNAME` 对应账号创建、具有 `read:packages` scope 的 classic PAT。manifest 顶层包含 `ghcr.io` 时，脚本使用这组凭据登录 GHCR。

单镜像 action 的认证行为不变：下游仓库未填写 `source_username` 和 `source_password` 时，仍使用调用 workflow 的 `github.actor` 和 `GITHUB_TOKEN`。

`ubuntu-latest` runner 必须提供 `git`、`jq`、mikefarah `yq` 和 Skopeo；缺少任一命令时批量任务会直接失败并报告缺失的命令。

## 目标命名与 layer 复用

单镜像 action 和 manifest 批量同步都保留源 tag。未使用 `skopeo sync --scoped` 时，批量同步使用源 repository 的 basename 作为目标 repository：

```text
docker.io/library/nginx:stable-alpine3.24-perl
  -> ${ACR_ENDPOINT}/public/nginx:stable-alpine3.24-perl
```

如果两个源 repository 的 basename 相同，它们会写入同一个目标 repository；需要通过不同 `target_namespace` 避免冲突。

单镜像脚本实际调用：

```bash
skopeo copy \
  --authfile "${auth_file}" \
  --override-arch "${ARCH}" \
  --preserve-digests \
  --digestfile "${digest_file}" \
  "docker://${source_image}:${TAG}" \
  "docker://${acr_endpoint}/${target_namespace}/${image_name}:${TAG}"
```

Skopeo 按 digest 查询目标 repository 中的 blobs，只上传缺失 layers。`--preserve-digests` 保持所选单平台 manifest digest；`--digestfile` 直接产生 action 的 `digest` output，不额外执行远程 `inspect`。

架构设计与边界说明见 [`docs/architecture.md`](docs/architecture.md)。
