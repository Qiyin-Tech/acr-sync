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
| `source_username` | 否 | 空 | 源 Registry 用户名；公开镜像留空 |
| `source_password` | 否 | 空 | 源 Registry 密码或 token；公开镜像留空 |
| `acr_username` | 是 | - | ACR 用户名，应从组织 Actions variable 传入 |
| `acr_password` | 是 | - | ACR 密码，应从组织 Actions secret 传入 |

目标镜像名取源镜像路径的最后一段。例如：

```text
ghcr.io/qiyin-tech/orchestra-backend:v1.2.3
  -> ${ACR_ENDPOINT}/qiyin/orchestra-backend:v1.2.3
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
          acr_username: ${{ vars.ACR_USERNAME }}
          acr_password: ${{ secrets.ACR_PASSWORD }}
```

组织需要提供 Actions variables `ACR_ENDPOINT`、`ACR_USERNAME` 和 Actions secret `ACR_PASSWORD`，并授权调用仓库使用它们。`ACR_ENDPOINT` 是固定的组织策略，action 不提供覆盖它的输入。

`source_username` 和 `source_password` 必须同时提供或同时留空。两者留空时，Docker Hub 等公开源仓库使用匿名读取；对于 `ghcr.io`，action 会自动回退到调用方的 `GITHUB_TOKEN`，因此调用方需要授予 `packages: read`。

## 手动同步

本仓库提供 `.github/workflows/sync-image.yml`。该 workflow 支持 `workflow_dispatch`，可从 Actions 页面手动填写源镜像、tag、架构和目标 namespace；`arch` 在工作流层默认使用 `amd64`。ACR 地址直接读取组织 variable `ACR_ENDPOINT`，不提供手动输入。

手动 workflow 会检出用户选择的本仓库 ref，再通过 `uses: ./` 调用同一版本的 composite action。它读取目标 ACR 的组织 variable `ACR_USERNAME` 和组织 secret `ACR_PASSWORD`，不绑定任何通用源仓库凭据。公共源使用匿名读取；GHCR 源仍可由 action 按域名自动使用调用方的 `GITHUB_TOKEN`。

## 基于 manifest 批量同步

`manifest/` 中的文件使用 Skopeo 原生 YAML source schema，不是本仓库自定义格式。例如 `manifest/dockerhub.yml`：

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

根目录的 `sync.yml` 将可操作的 alias 映射到 manifest、架构列表和目标 namespace：

```yaml
dockerhub:
  archs:
    - amd64
  target_namespace: public
  manifest_path: manifest/dockerhub.yml
```

`archs` 保持列表结构，供 workflow 统一生成 matrix；当前每个 alias 只允许一个架构。多个单架构 job 写同一目标 tag 时不会自动合并为多架构 index，因此 prepare 脚本会拒绝包含多个架构的 alias，避免最后一个 job 覆盖前面的结果。

`.github/workflows/sync-manifest.yml` 在 `main` 的 `sync.yml` 或 `manifest/**` 发生变更时启动。push 触发时：

- `sync.yml` 变更会选择全部 alias；
- manifest 变更只选择 `manifest_path` 指向该文件的 alias；
- 每个 alias 的 `archs` 被展开为 Actions matrix。

手动触发时只填写 `sync.yml` 中的 `name`，例如 `dockerhub`。手动运行不检查 Git diff，总是强制执行该 alias。ACR 地址由 workflow 直接读取 `vars.ACR_ENDPOINT`。

workflow YAML 只负责编排。`scripts/prepare-sync-matrix` 使用 runner 自带的 `yq` 读取 `sync.yml` 并生成 matrix；`scripts/sync-manifest` 处理临时认证文件后直接调用 `skopeo sync`。根 composite action 同样只保留输入和上下文映射，实际单镜像同步位于随 action 一起下载的 `scripts/sync-image`。同步任务在 workflow 层串行，避免连续清单提交同时写相同 tags。

push 选中的空 manifest 会打印 warning 并跳过，便于先登记尚未填充的 alias；手动指定空 manifest 会失败，因为手动触发表示强制执行。配置引用不存在的 manifest 始终是错误。

若 manifest 顶层包含 `ghcr.io`，脚本会自动使用 `github.actor` 和当前 workflow 的 `GITHUB_TOKEN` 登录；workflow 已声明 `packages: read`。私有 GHCR package 仍须在其 Actions access 设置中允许 `Qiyin-Tech/acr-sync` 仓库访问。凭据不写入 manifest 或 `sync.yml`。

Skopeo 会将 `docker.io/library/nginx` 映射为目标 repository `public/nginx`，并在同一进程内同步配置中的所有 tags。不同源 repository 若 basename 相同会映射到同一目标 repository；当前原生配置不支持自定义目标名，出现实际冲突时应拆分目标 namespace 或评估 Skopeo 的 `--scoped`。

## 复制与 layer 复用

Composite Action 通过随 action 一起发布的 `scripts/sync-image` 调用 Skopeo：

```bash
skopeo copy \
  --override-arch amd64 \
  --preserve-digests \
  docker://docker.io/library/nginx:stable-alpine3.24-perl \
  "docker://${ACR_ENDPOINT}/public/nginx:stable-alpine3.24-perl"
```

Skopeo 会按 digest 检查目标 repository 中的 layer。已有 layer 直接复用，只传输缺失 layer；`--preserve-digests` 保证复制过程中不改变所选单平台 manifest 的 digest。Action 使用 Skopeo 的 `--digestfile` 返回复制结果，不再额外执行远程 `inspect`。

Composite Action 默认同步 `amd64`，调用方可用 `arch: arm64` 显式覆盖。ACR endpoint 直接来自调用方可见的组织 variable `ACR_ENDPOINT`，不是 action 输入。

仓库的职责边界、候选方案和批量同步约束见 [`docs/architecture.md`](docs/architecture.md)。
