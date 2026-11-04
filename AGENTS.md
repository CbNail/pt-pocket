# 工程协作约定（AGENTS）

本文件规定本仓库的硬性约定，任何自动化协作与人工提交都必须遵守。

**构建前置（第一条）**：任何构建 / 打包 / 发版动作之前，先重新通读一遍需求规格书
[`docs/需求规格书.md`](docs/需求规格书.md)；行为变更必须同时回写到规格书与 `README.md`。

**推送前置（第二条）**：每次项目更新完成后，必须把 `README.md`、需求规格书的
[`docs/需求规格书.md`](docs/需求规格书.md) 与 [`docs/需求规格书.docx`](docs/需求规格书.docx) 两个版本、
以及整个项目一起重新推送到 GitHub。三处文档必须同口径，不允许只推代码不推文档，
也不允许只在本地改完而不推送。

## 分支与提交

- `main` 分支始终可构建、可运行：不允许合入编译失败或静态分析报错的提交。
- 提交信息遵循 Conventional Commits（`feat:` / `fix:` / `refactor:` / `docs:` / `chore:` / `test:`）。
- 不提交任何凭据：`.env`、Cookie、API Key、站点令牌、下载器账号、证书私钥一律不入库。

## 目录职责

- `mobile/flutter_app/`：移动端。页面只做交互与展示，不直接实现站点 HTTP 逻辑。
- `backend/app/adapters/`：第三方差异隔离层，分 `sites` / `downloaders` / `moviepilot` 三类。
- `backend/app/api/v1/`：移动端唯一入口，接口前缀 `/api/v1`。
- `deploy/`：部署编排，服务端代码路径固定为 `/data/docker-compose/pt_pocket` 或其子目录。
- `docs/`：需求、架构、适配器能力声明与运维手册。

## 适配器（Adapter）

- 站点访问、下载器交互、MoviePilot 调用必须经适配器，页面与其他服务不得直接拼接第三方接口。
- 新增或修改适配器时，必须同步更新该适配器的能力声明，并补齐契约测试。
- MoviePilot 首期按 v2 打通，v3 通过独立适配层接入；适配层与业务代码解耦，v3 正式版发布后新增实现即可，不改动调用方。

## 数据库

- 使用 PostgreSQL，配合 Alembic 迁移；任何模型变更必须携带对应 migration，不允许手工改表。
- PostgreSQL 与 Redis 的数据目录不得放在 NFS 上。

## 移动端工程约定

- 依赖与版本在 `mobile/flutter_app/pubspec.yaml` 集中维护。
- 间距、圆角、动效时长统一取自 `lib/core/theme/design_tokens.dart`。
- 非敏感配置写入 `SharedPreferences`（`ptp.` 命名空间），凭据与令牌写入 `flutter_secure_storage`（`ptp_` 命名空间）。
- 配置结构发生结构性变更时：递增 `AppConfig.configSchemaVersion`，并在 `ConfigInheritanceService` 注册一条只做补充/改名/结构升级的迁移；迁移绝不能删除或覆盖用户已填写的值。
- 页面必须处理规格书 §4.3 规定的全局状态：首次加载、加载中、部分成功、空状态、离线缓存、鉴权失败、限流、服务端错误与手动刷新。

## 网络链路

- 所有访问自建服务的功能都必须支持内网与外网（lucky 反代）两条通道，并支持自动切换。
- 自动模式下内网优先、失败回退外网；已在外网时仍先探测内网，以便回到家庭网络自动切回。
- 链路可用性以 API 健康检查为准，不以 TCP 可连接为准。

## 质量门禁

- 移动端：`flutter analyze` 无错误、`flutter test` 全部通过。
- 服务端：格式化、静态检查、单元测试与适配器契约测试通过。
- CI 在 `.github/workflows/` 中维护，`main` 变更必须通过门禁。