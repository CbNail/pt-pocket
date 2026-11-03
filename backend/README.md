# 服务端后端目录结构与实现约定

本目录是 NAS 后端服务的实现位置。代码最终部署到
`/data/docker-compose/pt_pocket/backend`（或其子目录），由
`deploy/docker-compose.yml` 构建与运行。

## 目录结构（规格书 §13）

```
backend/
├── pyproject.toml                # 依赖与工具配置（ruff / pytest）
├── alembic.ini
├── migrations/                   # Alembic 迁移（模型变更必须带迁移）
└── app/
    ├── main.py                   # FastAPI 应用装配（挂载 /api/v1）
    ├── api/
    │   └── v1/                   # 版本化接口（移动端唯一入口）
    │       ├── health.py         # GET /api/v1/health（App 选路探测）
    │       ├── search.py         # POST /api/v1/search
    │       ├── torrents.py       # POST /api/v1/torrents/push
    │       ├── downloaders.py    # /api/v1/downloaders/*
    │       ├── profile.py        # GET /api/v1/profile
    │       ├── monitor.py        # GET /api/v1/monitor/events
    │       ├── signin.py         # /api/v1/signin/*、/api/v1/sites/{id}/signin
    │       └── notify.py         # POST /api/v1/notify/test
    ├── core/                     # 配置、日志、鉴权、依赖注入、错误码
    ├── models/                   # SQLAlchemy 模型
    ├── schemas/                  # 请求 / 响应模型（与 docs/api-contract.md 对齐）
    ├── services/                 # 业务编排（搜索聚合、去重、推送、签到、巡检）
    ├── adapters/                 # 第三方差异隔离层
    │   ├── sites/                # 站点适配器（NexusPHP / Unit3D / Gazelle / 自定义）
    │   ├── downloaders/          # qBittorrent / Transmission / Aria2
    │   └── moviepilot/           # MoviePilot v2 适配器 + v3 适配层预留
    └── workers/                  # 定时任务：巡检、签到补签、站庆日历、通知推送
```

## 实现约定

1. **接口前缀固定 `/api/v1`**，响应结构统一为
   `{code, message, data}`；错误码见规格书 §9.5。
2. **适配器隔离**：站点、下载器、MoviePilot 的所有协议细节只出现在
   `app/adapters/**`，接口层与业务层不得直接拼接第三方请求。
3. **适配器变更须同步能力声明与契约测试**；新增 MoviePilot v3 支持时，
   只需新增 `adapters/moviepilot/v3.py` 并注册，无需改动调用方。
4. **数据库**：模型变更必须携带 Alembic 迁移；PostgreSQL / Redis 数据目录不得放在 NFS。
5. **凭据**：站点 Cookie / Passkey / API Key、下载器账号、MoviePilot 令牌、
   推送通道凭据统一加密存储（密钥来自 `PT_POCKET_SECRET_KEY`），不写入日志。
6. **定时任务**：签到（含失败补签）、巡检、站庆提醒、推送都在 `workers/` 中调度，
   时间取自 `PT_POCKET_SIGNIN_CRON` / `PT_POCKET_MONITOR_CRON`。
7. **移动端契约**：任何接口调整都必须同步更新 `docs/api-contract.md`，
   并保持向前兼容或提供版本升级路径（`/api/v2`）。
8. **健康检查**：`/api/v1/health` 必须快速返回 2xx；App 的内外网选路以它为准。