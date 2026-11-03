# PT Pocket

面向个人 PT 用户的自托管移动管理中枢：站点凭据与状态、多下载器任务、多站聚合搜索与推送、
个人数据与养老进度、站点监护与签到，统一由自有 NAS 后端调度，App 只负责交互与展示。

- 规格基线：《PT Pocket 产品需求与设计规格书 v1.1（硬件适配版）》
- 目标设备：HUAWEI Mate 70 Pro+（HarmonyOS 6.1.0）
- 服务端宿主：威联通 TS-451D、自组设备（PVE）

## 仓库结构

```
.
├── AGENTS.md                 # 协作与工程约定（提交、适配器、迁移、部署）
├── README.md
├── docs/                     # 产品与架构文档
├── mobile/flutter_app/       # Flutter 移动端（Android / iOS）
├── backend/                  # NAS 后端服务（FastAPI + PostgreSQL + Redis）
│   ├── app/
│   │   ├── api/v1/           # 版本化 HTTP 接口
│   │   ├── core/             # 配置、日志、鉴权、依赖注入
│   │   ├── models/           # SQLAlchemy 模型
│   │   ├── schemas/          # 请求/响应模型
│   │   ├── services/         # 业务编排
│   │   ├── adapters/         # sites / downloaders / moviepilot 三类适配器
│   │   └── workers/          # 定时任务：巡检、签到补签、通知
│   └── migrations/           # Alembic 迁移
├── deploy/                   # docker-compose 与部署脚本
└── .github/workflows/        # CI：format / analyze / test
```

## 移动端（Flutter）

```bash
cd mobile/flutter_app
flutter pub get
flutter analyze
flutter test
flutter run          # 需连接设备或模拟器
flutter build apk    # 需安装 Android SDK + JDK
```

约定：

- 状态管理 `flutter_riverpod`，分层为 data provider / service provider / ui provider；
- 路由 `go_router` + `StatefulShellRoute.indexedStack`，五个底部主入口状态互不丢失；
- 所有间距、圆角、动效时长取自 `lib/core/theme/design_tokens.dart`，不在页面内硬编码；
- 非敏感配置走 `SharedPreferences`，凭据与令牌走 `flutter_secure_storage`；
- 配置结构变更必须递增 `AppConfig.configSchemaVersion` 并注册迁移，保证升级后用户已填配置自动继承。

## 服务端（NAS 后端）

- 部署目录固定为 `/data/docker-compose/pt_pocket` 或其子目录。
- 站点访问、搜索并发、定时任务与通知统一在后端调度，移动端不直连数据库与 Redis。
- PostgreSQL 与 Redis 的数据目录不放在 NFS 上。
- 对外只暴露 `/api/v1` 版本化接口；错误码规范见规格书 §9.5。

## 网络与链路

访问自建服务时始终提供内网与外网（lucky 反代）两条通道：

- 自动模式：内网优先（2 秒探测），失败回退外网（10 秒探测）；
- 已使用外网时仍会先探测内网，回到家庭网络后自动切回内网；
- 选路结果缓存 5 分钟，网络切换事件与请求失败会立即失效缓存。

## 文档

`docs/` 下维护产品需求、架构决策、适配器能力声明与运维说明。