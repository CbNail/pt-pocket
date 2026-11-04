# `/api/v1` 接口契约（移动端已实现侧）

本文件列出**移动端代码里已经实现调用**的接口，供 NAS 后端实现对齐。
所有请求都由移动端经内外网双通道发出，前缀固定 `/api/v1`。

> **V1.5 补充（直连数据源与后端的关系）：** 本文件描述的 `/api/v1` 接口仍是移动端的
> **唯一后端入口**，但从 V1.5 起，监护室、站点统计 / 我的数据 / 养老进度、站内搜索、
> 下载器任务在 App 内**优先直连**（公开状态页 savept.icu、站点用户页与搜索页、qBittorrent WebUI），
> **只有在直连取不到（缺凭据 / 网络不可达 / 被限流 / 结构未识别）且后端已配置时**才回退到这里列出的接口。
> 也就是说：这些接口现在是**可选回退通道**，而不是唯一数据来源；直连实现与产出模型见
> `docs/app-backend-boundary.md` 与规格书 §22。

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
| `GET /api/v1/downloaders/{id}/task-options` | 可选分类 / 标签 / 路径，供批量操作的选择器使用 |
| `POST /api/v1/downloaders/{id}/tasks/category` | body `{hashes: [...], category: ""}`，空串表示清除分类 |
| `POST /api/v1/downloaders/{id}/tasks/tags` | body `{hashes: [...], tags: [...], mode: "add\|remove\|set"}` |
| `POST /api/v1/downloaders/{id}/tasks/location` | body `{hashes: [...], savePath: "/downloads/PT"}` |

任务字段（后端应归一化，字段别名移动端也做了兼容）：

```json
{
  "hash": "info hash",
  "name": "任务名",
  "sizeBytes": 0, "completedBytes": 0,
  "state": "downloading|seeding|paused|queued|checking|completed|error|unknown",
  "downloadSpeed": 0, "uploadSpeed": 0, "etaSeconds": -1,
  "savePath": "", "category": "", "ratio": 0.0,
  "tags": ["官种"], "tracker": "tracker.example.com",
  "addedAt": "2026-11-01T00:00:00Z"
}
```

- `tags` 支持数组或逗号串；Transmission 没有独立分类，其 `labels` 同时充当分类与标签；
- `tracker`（站点 / 服务器域名）是任务页「服务器筛选」的数据源，缺省显示「未标注」；
- `addedAt` 兼容 ISO 字符串与 epoch（秒或毫秒），缺省则该任务在「加入时间」排序里落到末尾；
- `task-options` 未实现时，移动端按空候选处理，批量操作仍可手填分类 / 标签 / 路径。

> 返回非数组时移动端会抛出结构异常，而不是静默当作"没有任务"。

## 5. 个人数据与统计（站点数据面板共用）

| 项 | 值 |
| --- | --- |
| 方法 / 路径 | `GET /api/v1/profile?siteIds=s1,s2`（`siteIds` 可选，逗号分隔） |
| 用途 | 我的数据（历程、统计）、养老进度，以及站点页的数据面板 |

站点页与「我的数据」共用这一份口径，站点的四态刷新状态也在同一响应里给出——
同一批数据两套字段会让两边的数字对不上。

响应体：

```json
{
  "sites": [
    {
      "siteId": "s1", "siteName": "站点一",
      "iconUrl": "", "username": "", "userClass": "",
      "uploadedBytes": 0, "downloadedBytes": 0,
      "bonus": 0, "hourlyBonus": 0,
      "seedingCount": 0, "leechingCount": 0,
      "connections": 0, "hrCount": 0, "unreadMessages": 0, "invites": 0,
      "joinDate": "2020-01-01T00:00:00Z",
      "ratio": 1.25,
      "signedInToday": true, "consecutiveSignInDays": 12,
      "careState": "healthy|attention|atRisk|unknown",
      "careProgress": 0.8,
      "policy": {
        "minimumRatio": 0.6, "minimumSeedingDays": 30,
        "minimumUploadBytes": 0, "requiresSignIn": true, "note": ""
      },
      "refreshState": "refreshed|stale|failed|notLoggedIn",
      "refreshMessage": "失败原因（仅失败 / 未登录时给）",
      "refreshedAt": "2026-11-04T08:00:00Z",
      "todayUploadedBytes": 0, "todayDownloadedBytes": 0,
      "todayBaselineAvailable": false,
      "nextClass": "", "nextClassRequirement": "",
      "contractMet": true, "contractNote": ""
    }
  ],
  "todayUploadedBytes": 0, "todayDownloadedBytes": 0, "todayBaselineAvailable": false,
  "generatedAt": "2026-11-03T10:00:00Z",
  "notice": ""
}
```

字段说明：

- `hourlyBonus`（综合时魔）、`connections`（连接数）、`hrCount`（H&R 未完成数）、
  `unreadMessages`（站内信未读数）、`invites`（可邀请名额）为站点页面板字段，
  后端未采集时**整个键缺省**，移动端显示「—」/「无」，不用 0 冒充真实数据；
- `iconUrl` 为空时移动端用站点名首字生成图标；
- `refreshState` 是站点页四态筛选的唯一口径：`refreshed` 已刷新 / `stale` 未刷新（含从未刷新、
  超过阈值）/ `failed` 失败 / `notLoggedIn` 未登录；其它取值按「未检测」处理（只出现在「全部」里）；
- **今日增量**：`todayUploadedBytes` / `todayDownloadedBytes` = 当日累计 − 前一自然日累计，
  由后端计算；`todayBaselineAvailable` 表示是否有前一自然日快照作基线。
  **基线不足时移动端显示「基线不足」，绝不用 0 冒充「今天没涨」**；顶层字段缺省时移动端按各站增量求和，
  并取「所有站点都有基线」为整体基线；
- `nextClass` / `nextClassRequirement`：等级路线（下一等级与其达成条件），站点未提供等级信息时留空；
- `contractMet` / `contractNote`：保种契约（H&R / 契约检查）是否达成与说明；未提供该键表示后端未采集，
  移动端显示「数据未提供」；
- `policy.alternatives` / `policy.satisfiedAlternative`：**任选条件**（满足其中任一项即达标）与当前已命中的那一项。

## 5.1 站点数据刷新

| 方法 / 路径 | 说明 |
| --- | --- |
| `POST /api/v1/sites/{siteId}/refresh` | 刷新单个站点的数据 |
| `POST /api/v1/sites/refresh` | body `{siteIds?: [...]}`，为空表示全部启用站点 |

刷新为异步动作：后端接受请求后立即返回（2xx 即可），抓取结果通过
`GET /api/v1/profile` 的 `refreshState` / `refreshedAt` 体现。
抓取站点页面由后端适配器完成，移动端只触发与消费结果，不下沉站点 HTTP 逻辑。

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
| `POST /api/v1/signin/run` | body `{siteIds?: [...], mode: "both\|signin\|login"}`，`siteIds` 为空表示全部启用站点 |
| `POST /api/v1/sites/{siteId}/signin` | 单站签到 / 补签，body `{mode}` |
| `GET /api/v1/signin/records?limit=N` | 最近签到记录 |

`mode` 与参考实现的「签到站点 + 仅模拟登录站点」两类口径一致：
`both` 两类都处理（默认）/ `signin` 只做签到 / `login` 只做模拟登录。

签到结果：

```json
{
  "records": [
    {
      "siteId": "s1", "siteName": "站点一",
      "success": true, "action": "signin|login",
      "message": "", "signedAt": "..."
    }
  ],
  "ranAt": "2026-11-03T08:00:00Z",
  "notice": ""
}
```

`action` 告诉移动端这次做的是签到还是模拟登录；缺省按 `signin` 处理。
**注意**：并非所有站点都把程序登录 / 签到计为用户活跃（例如馒头），后端与移动端都不应把
「提示成功」表达成「必然不会掉号」，移动端已在签到中心明确提示该风险。

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
## 9. 直连数据源（不走 `/api/v1`，列在此处便于对照）

以下通道由 App 自己发起，NAS 后端**不参与**（后端实现后仍可保留为回退）：

| 能力 | 目标 | 说明 |
| --- | --- | --- |
| 监护室 | `GET https://savept.icu/` | 解析站点卡片与病危 / 恢复 / 站庆 / 死亡公告；基址可改（偏好 `ptp.direct.monitor.baseUrl`） |
| 监护室历史事件 | `GET /api/history/dead?page=N`、`GET /api/history/anniversary?page=N` | 返回 `{items, next_page, has_more}`；`items[i] = {date, event_label, name, url, description}` |
| 站点用户页 | `GET {站点}/index.php` | 带该站 Cookie；解析上传 / 下载 / 分享率 / 魔力 / 做种 / 下载中 / 邀请 / 未读邮件 / H&R / 等级 / 注册时间 |
| 站内搜索 | `GET {站点}/torrents.php?search=关键字&notnewword=1[&page=N]` | 带该站 Cookie；解析结果行（id / 标题 / 大小 / 做种 / 下载 / 促销 / 分类 / 发布时间）；下载地址 `{站点}/download.php?id=<id>[&passkey=<passkey>]` |
| 下载器（qBittorrent） | `POST {下载器}/api/v2/auth/login`、`GET /api/v2/torrents/info`、`GET /api/v2/transfer/info`、`GET /api/v2/app/version`、`GET /api/v2/torrents/categories|tags`、`GET /api/v2/app/defaultSavePath`、`POST /api/v2/torrents/{pause|resume|delete|setCategory|addTags|removeTags|setLocation}` | 表单登录取 `SID` 并复用；写操作参数 `hashes`（多个用 `|` 连接） |

> 直连失败一律在界面上按**分类 + 可执行建议**呈现（缺少凭据 / 登录被拒绝 / 被限流 /
> 地址不可达 / 返回结构异常），不得把这些失败写成与 NAS 服务地址相关的原因。
