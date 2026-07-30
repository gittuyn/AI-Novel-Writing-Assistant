# 服务器云端构建设计

## 目标

生产服务器不再执行 TypeScript 或 Vite 构建。GitHub Actions 手动构建部署制品，服务器仅下载、校验、备份、切换制品并重启服务。

## 架构

- `.github/workflows/server-build-artifact.yml` 在 GitHub 托管 runner 上安装锁定依赖并执行现有 `pnpm build`。
- 工作流打包服务端、客户端和共享包的构建产物，以及服务端运行需要的 Prisma schema、迁移和包清单。
- `scripts/deploy-server-artifact.sh` 接收本地制品压缩包。它校验目录和文件、备份 SQLite、暂存旧构建、复制新构建、重启 systemd，并通过健康接口验收。
- 部署失败时恢复旧构建并再次启动服务。脚本不运行 `pnpm build`、`tsc` 或 Vite。

## 安全边界

- 工作流只生成 Artifact，不连接生产服务器。
- 部署脚本只接受明确的压缩包路径，不从不可信 URL 下载。
- SQLite 使用在线 `.backup` 并执行 `PRAGMA quick_check`。
- 不删除用户未跟踪文件，不修改 `.env`，不执行数据库 reset。
- 仅替换 `server/dist`、`client/dist` 和 `shared/dist`。

## 验证

- 检查 workflow YAML 可解析，且只有 `workflow_dispatch` 触发。
- 检查部署脚本通过 `bash -n`。
- 用伪制品执行 `--verify-only`，确认缺失文件会失败、完整清单会成功。
- 实际升级以 systemd active、`/api/health` 返回 HTTP 200 为完成条件。

