# PT Pocket 服务端部署说明

## 1. 目录约定（硬约束）

服务端代码与编排文件必须放在 `/data/docker-compose/pt_pocket` 或其子目录下：

```
/data/docker-compose/pt_pocket/
├── docker-compose.yml      # 本仓库 deploy/docker-compose.yml
├── .env                    # 由 deploy/.env.example 复制填写（不入库）
├── backend/                # 本仓库 backend/ 目录内容
└── data/                   # 运行时数据（首次启动自动创建）
    ├── api/                # 后端日志与临时文件
    ├── worker/             # 定时任务工作目录
    ├── postgres/           # 数据库数据文件（必须本地磁盘，不要放 NFS）
    └── redis/              # AOF 数据
```

## 2. 部署步骤

```bash
cd /data/docker-compose/pt_pocket
cp deploy/.env.example .env        # 首次部署
vi .env                            # 填 POSTGRES_PASSWORD / REDIS_PASSWORD / 应用密钥等
docker compose up -d
docker compose ps
curl -s http://127.0.0.1:8000/api/v1/health
```

数据库迁移在 api 容器启动时执行（`alembic upgrade head`），迁移文件位于
`backend/migrations/`。

## 3. 与外网入口（lucky 反代）配合

- 反代目标：`http://<NAS 内网 IP>:8000`，路径 `/api/v1/*` 原样透传；
- App 端「我的 · 连接与服务」填写两条地址：
  - 内网：`http://<NAS 内网 IP>:8000`
  - 外网：lucky 反代后的入口，例如 `https://pt.example.com`
- App 默认自动模式：内网优先（2 秒探测），失败回退外网（10 秒探测），回到家网后自动切回。

## 4. 健康检查与升级

```bash
# 健康检查（App 的选路探测也用该接口，只有 2xx 才会选中该链路）
curl -fsS http://127.0.0.1:8000/api/v1/health

# 升级
docker compose pull            # 使用镜像时
docker compose up -d --build   # 使用本地源码构建时
docker compose logs -f api worker
```

## 5. 备份

需要备份的内容：

- `data/postgres/`（业务数据，含站点配置与巡检结果）；
- `.env`（应用密钥；丢失后已加密的站点凭据无法解密，需要重新录入）。

数据库在线备份建议：`docker compose exec postgres pg_dump -U pt_pocket pt_pocket > backup.sql`。

## 6. 与移动端的关系

- 移动端只访问 `/api/v1`，不直连 PostgreSQL / Redis，也不接触站点协议细节；
- 站点访问、聚合搜索并发、定时签到与补签、监护巡检、推送发送全部由本服务端完成；
- 移动端与后端的接口契约见 `docs/api-contract.md`。