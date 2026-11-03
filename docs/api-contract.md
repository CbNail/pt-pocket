# `/api/v1` 接口契约（移动端已实现侧）

本文件列出**移动端代码里已经实现调用**的接口，供 NAS 后端实现对齐。
所有请求都由移动端经内外网双通道发出，前缀固定 `/api/v1`。

约定：

- 认证：移动端在请求头带 `X-Session-Token`（配对后由后端下发，存本机安全存储）；
  写操作额外带 `X-Idempotency-Key`（uuid v4），后端应据此去重；
- 错误：非 2xx 视为失败，响应体优先取 `{code, message}`（也兼容 `detail`）；
- 结构：成功响应可以是数组，也可以是 `{items: [...]}` / `{records: [...]}`
  （移动端两种都做了兼容）。

## 1. 健康检查

| 项 | 值 |
| --- | --- |
| 方法 / 路径 | `GET /api/v1/health` |
| 用途 | 内外网链路探测；**只有 2xx 才会被选路采用** |
| 响应 | 2xx 即可，无结构要求 |

## 2. 聚合搜索

| 项 | 值 |
| --- | --- |
| 方法 / 路径 | `POST /api/v1/search` |
| 请求体 | `{keyword, siteIds[], mpInstanceIds[], promotion, sort, page, pageSize}` |

字段说明：

- `keyword`：字符串，已 trim；
- `siteIds`：为空数组表示"后端按已启用站点全量搜索"；
- `mpInstanceIds`：参与搜索增强的 MoviePilot 实例 id（后端据此合并 MP 命中结果）；
- `promotion`：`all` / `free` / `twoXFree` / `half`；
- `sort`：`relevance` / `seeders` / `publishedAt` / `size`；
- `page` / `pageSize`：页码（从 1 起）与每页条数（默认 50）。

响应体：

```json
{
  "items": [
    {
      "id": "站点内种子 id",
      "title": "标题",
      "siteId": "站点 id",
      "siteName": "站点名",
      "subtitle": "副标题（可选）",
      "sizeBytes": 1073741824,
      "seeders": 10,
      "leechers": 2,
      "publishedAt": "2026-11-01T00:00:00Z",
      "promotion": "2xfree",
      "downloadUrl": "由后端携带凭据生成或抓取的下载地址",
      "detailUrl": "站点详情页（可选）",
      "category": "分类（可选）",
      "source": "site | moviepilot"
    }
  ],
  "page": 1,
  "pageSize": 50,
  "hasMore": true,
  "siteErrors": { "站点名": "失败原因" },
  "notice": "可选提示（如搜索增强降级说明）"
}
```

说明：`siteErrors` 用于「部分成功」展示——单个站点失败不应清空其它站点的成功结果。

## 3. 推送到下载器

| 项 | 值 |
| --- | --- |
| 方法 / 路径 | `POST /api/v1/torrents/push` |
| 请求体 | `{downloadUrl, downloaderId, savePath?, category?, mpInstanceId?}` |

- `downloadUrl` 来自搜索结果，后端负责用站点凭据完成实际抓取与投递；
- `savePath` 为空时使用该下载器的默认目录；
- 目标下载器的账号密码由后端按 `downloaderId` 从加密库读取。

## 4. 下载器任务

| 方法 / 路径 | 说明 |
| --- | --- |
| `GET /api/v1/downloaders/{id}/tasks` | 归一化任务数组 |
| `POST /api/v1/downloaders/{id}/tasks/pause` | body `{hashes: [...]}` |
| `POST /api/v1/downloaders/{id}/tasks/resume` | body `{hashes: [...]}` |
| `POST /api/v1/downloaders/{id}/tasks/remove` | body `{hashes: [...], deleteFiles: bool}` |

任务字段（后端应归一化，字段别名移动端也做了兼容）：

```json
{
  "hash": "info hash",
  "name": "任务名",
  "sizeBytes": 0, "completedBytes": 0,
  "state": "downloading|seeding|paused|queued|checking|completed|error|unknown",
  "downloadSpeed": 0, "uploadSpeed": 0, "etaSeconds": -1,
  "savePath": "", "category": "", "ratio": 0.0
}
```

> 返回非数组时移动端会抛出结构异常，而不是静默当作"没有任务"。

## 5. 个人数据与统计

| 项 | 值 |
| --- | --- |
| 方法 / 路径 | `GET /api/v1/profile?siteIds=s1,s2`（`siteIds` 可选，逗号分隔） |
| 用途 | 我的数据（历程、统计）与养老进度 |

响应体：

```json
{
  "sites": [
    {
      "siteId": "s1", "siteName": "站点一",
      "username": "", "userClass": "",
      "uploadedBytes": 0, "downloadedBytes": 0,
      "bonus": 0, "seedingCount": 0, "leechingCount": 0,
      "joinDate": "2020-01-01T00:00:00Z",
      "ratio": 1.25,
      "signedInToday": true, "consecutiveSignInDays": 12,
      "careState": "healthy|attention|atRisk|unknown",
      "careProgress": 0.8,
      "policy": {
        "minimumRatio": 0.6, "minimumSeedingDays": 30,
        "minimumUploadBytes": 0, "requiresSignIn": true, "note": ""
      }
    }
  ],
  "generatedAt": "2026-11-03T10:00:00Z",
  "notice": ""
}
```

## 6. 监护事件

| 项 | 值 |
| --- | --- |
| 方法 / 路径 | `GET /api/v1/monitor/events?limit=N` |
| 用途 | 病危、站庆、维护、签到失败等事件流（需求 6） |

事件字段：

```json
{
  "id": "e1", "title": "站点 A 疑似病危",
  "siteId": "", "siteName": "站点一",
  "type": "danger|anniversary|maintenance|signInFailure|warning|other",
  "severity": "info|warning|critical",
  "description": "", "occurredAt": "2026-11-01T00:00:00Z", "link": ""
}
```

## 7. 签到

| 方法 / 路径 | 说明 |
| --- | --- |
| `POST /api/v1/signin/run` | body `{siteIds: [...]}`，为空表示全部启用站点 |
| `POST /api/v1/sites/{siteId}/signin` | 单站签到 / 补签 |
| `GET /api/v1/signin/records?limit=N` | 最近签到记录 |

签到结果：

```json
{
  "records": [
    { "siteId": "s1", "siteName": "站点一", "success": true, "message": "", "signedAt": "..." }
  ],
  "ranAt": "2026-11-03T08:00:00Z",
  "notice": ""
}
```

> 未成功的站点由后端 worker 按 `PT_POCKET_SIGNIN_CRON` 自动补签；
> 移动端只在「签到中心」展示开关、时间与结果。

## 8. 推送通道测试

| 项 | 值 |
| --- | --- |
| 方法 / 路径 | `POST /api/v1/notify/test` |
| 请求体 | `{channel: "wecom" | "telegram"}` |
| 用途 | 让后端用当前配置实际发送一条测试消息 |

企业微信 Webhook Key、Telegram Bot Token / Chat ID 由移动端配置在本地，
实际发送由后端执行；后端需要的凭据应通过配对/配置接口同步，不得回显明文。