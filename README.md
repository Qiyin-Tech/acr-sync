# acr-sync

使用 [Skopeo](https://github.com/podman-container-tools/skopeo) 将单个容器镜像的指定架构同步到阿里云 ACR。同步直接在两个 Registry 之间进行，不依赖 Docker daemon。

## Composite action

仓库根目录的 `action.yml` 是公共入口，入参如下：

| 参数 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `source` | 是 | - | 不带 tag 的源镜像，例如 `ghcr.io/qiyin-tech/orchestra-backend` 或 `docker.io/library/nginx` |
| `tag` | 是 | - | 要同步的 tag；目标镜像使用相同 tag |
| `arch` | 否 | `amd64` | 要同步的架构，例如 `amd64` 或 `arm64`；一次只能指定一个 |
| `target_namespace` | 是 | - | ACR namespace，例如 `qiyin` |
| `target_registry` | 是 | - | ACR Registry 地址 |
| `source_username` | 否 | 空 | 源 Registry 用户名；公开镜像留空 |
| `source_password` | 否 | 空 | 源 Registry 密码或 token；公开镜像留空 |
| `acr_username` | 是 | - | ACR 用户名，应从组织 Actions variable 传入 |
| `acr_password` | 是 | - | ACR 密码，应从组织 Actions secret 传入 |

目标镜像名取源镜像路径的最后一段。例如：

```text
ghcr.io/qiyin-tech/orchestra-backend:v1.2.3
  -> acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com/qiyin/orchestra-backend:v1.2.3
```

调用示例：

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
        uses: Qiyin-Tech/acr-sync@v1
        with:
          source: ghcr.io/qiyin-tech/orchestra-backend
          tag: v1.2.3
          target_namespace: qiyin
          target_registry: acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com
          acr_username: ${{ vars.ACR_USERNAME }}
          acr_password: ${{ secrets.ACR_PASSWORD }}
```

组织需要提供 Actions variable `ACR_USERNAME` 和 Actions secret `ACR_PASSWORD`，并授权调用仓库使用它们。

`source_username` 和 `source_password` 必须同时提供或同时留空。两者留空时，Docker Hub 等公开源仓库使用匿名读取；对于 `ghcr.io`，action 会自动回退到调用方的 `GITHUB_TOKEN`，因此调用方需要授予 `packages: read`。

## 手动同步

本仓库提供 `.github/workflows/sync-image.yml`。该 workflow 支持 `workflow_dispatch`，可从 Actions 页面手动填写源镜像、tag、架构和目标 namespace；`arch` 在工作流层默认使用 `amd64`，`target_registry` 默认使用 `acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com`。

手动 workflow 会检出用户选择的本仓库 ref，再通过 `uses: ./` 调用同一版本的 composite action。它读取目标 ACR 的组织 variable `ACR_USERNAME` 和组织 secret `ACR_PASSWORD`，不绑定任何通用源仓库凭据。公共源使用匿名读取；GHCR 源仍可由 action 按域名自动使用调用方的 `GITHUB_TOKEN`。

## 批量同步公共 Docker Hub 镜像

仓库根目录的 `skopeo-sync.yaml` 使用 Skopeo 原生 YAML source schema，不是本仓库自定义格式：

```yaml
docker.io:
  images:
    library/nginx:
      - "stable-alpine3.24-perl"
```

- Docker Hub 官方镜像使用 `library/<name>`，例如 `library/nginx`。
- 普通公共仓库保留其 Docker Hub namespace，例如 `bitnami/postgresql`。
- tag 建议始终使用字符串引号。
- 不要用空数组，Skopeo 将其解释为同步该 repository 的所有 tags。

`.github/workflows/sync-public-dockerhub.yml` 从 Actions 页面手动触发，直接运行：

```bash
skopeo sync \
  --src yaml \
  --dest docker \
  --override-arch amd64 \
  --preserve-digests \
  --keep-going \
  skopeo-sync.yaml \
  acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com/public
```

workflow 默认同步 `amd64` 到 namespace `public`。Skopeo 会将 `docker.io/library/nginx` 映射为目标 repository `public/nginx`，并在同一进程内同步配置中的所有 tags。不同源 repository 若 basename 相同会映射到同一目标 repository；当前原生配置不支持自定义目标名，出现实际冲突时应拆分目标 namespace 或评估 Skopeo 的 `--scoped`。

## 复制与 layer 复用

Composite Action 直接调用 Skopeo：

```bash
skopeo copy \
  --override-arch amd64 \
  --preserve-digests \
  docker://docker.io/library/nginx:stable-alpine3.24-perl \
  docker://acr-chegndu-registry.cn-chengdu.cr.aliyuncs.com/public/nginx:stable-alpine3.24-perl
```

Skopeo 会按 digest 检查目标 repository 中的 layer。已有 layer 直接复用，只传输缺失 layer；`--preserve-digests` 保证复制过程中不改变所选单平台 manifest 的 digest。Action 使用 Skopeo 的 `--digestfile` 返回复制结果，不再额外执行远程 `inspect`。

Composite Action 默认同步 `amd64`，调用方可用 `arch: arm64` 显式覆盖。它没有 Registry 默认值；成都 ACR 地址只存在于手动 workflow 的调用表单中。

仓库的职责边界、候选方案和批量同步约束见 [`docs/architecture.md`](docs/architecture.md)。
