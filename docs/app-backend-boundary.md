# App 与 NAS 后端职责边界（V1.5：直连数据源）

本文件回答一个问题：**每块能力的数据从哪来、App 做什么、NAS 后端做什么。**
配套接口见 [`api-contract.md`](api-contract.md)，需求与验收基线见 [`需求规格书.md`](需求规格书.md) §22。

## 0. 总则

| 侧 | 职责 |
| --- | --- |
| 移动端（Flutter） | 交互与展示、表单与参数、本地缓存与凭据保管、**可达性探测**、**直连数据源**（V1.5）、把结果按统一字段渲染、失败态与空态的呈现 |
| NAS 后端 | 站点页面与 API 的抓取与解析、下载器协议调用、定时任务与补签、跨站聚合与归一化、历史快照与趋势、等级/保号规则匹配、凭据加密存储 |

三条硬性约束：

1. **App 不直连数据库 / Redis**（规格书 §7.1）；页面不得自己拼第三方请求，所有第三方协议细节集中在
   `lib/core/direct/`。V1.5 修订：NAS 后端未实现期间，App **可以**直连公开状态页、站点用户页 / 搜索页
   与 qBittorrent WebUI，这是本轮刻意引入的「直连数据源」（见 §1 与规格书 §22）。
2. **后端未实现时，App 只能显示空态或「数据未提供」占位说明，不得用占位数字伪造成站点数据**
   （直连取到的真实数据当然照常展示；缺字段一律标「未提供 / 未采集」）。
3. 任何写操作都带幂等键；站点凭据只在后端落地（直连模式下另需本机保存该站 Cookie / 下载器 WebUI 账号密码，
   同样走 `flutter_secure_storage`），App 侧只保存「已配置」这一状态位。

## 1. 能力清单与职责划分（V1.5）

「数据来源」列里，**App 直连**表示 App 自己发起请求；**NAS** 表示经 `/api/v1` 由后端完成。

| 能力 | 数据来源 | App 侧职责 | NAS 侧职责 | 现状 |
| --- | --- | --- | --- | --- |
| 监护室（病危 / 站庆 / 死亡 / 恢复） | **App 直连公开状态页 savept.icu**（`/` 与 `/api/history/*`） | 解析站点卡片与四类公告、本地汇总顶部统计、按状态 / 内外站 / 近期站庆筛选、缓存回退与「缓存」标注、历史事件分页 | 已部署时补充巡检事件（`GET /api/v1/monitor/events`） | App 直连**已实现**；后端巡检事件为可选补充 |
| 站点数据面板 | **App 直连站点用户页**（NexusPHP 结构，带站点 Cookie）；配置了后端时可回退 | 解析上传 / 下载 / 分享率 / 魔力 / 做种 / 下载中 / 邀请 / 邮件 / H&R / 等级 / 注册时间；四态筛选、打码、扩展展示、逐个刷新 | 抓取与解析站点用户页、维护 `err_msg` 与刷新时间、消息未读数 | App 直连**已实现**；字段缺 6 项（连接数等）标「未采集」 |
| 我的数据 / 统计 | **App 直连站点用户页 + 本机每日采样** | 展示累计与今日指标、站点排序、时间轴；缺基线标「基线不足」、时魔标「本地估算」 | 每日快照、当日增量、趋势聚合 | App 直连**已实现**（本机最多 400 条 / 站） |
| 养老进度 / 保号 | **App 直连站点用户页 + 内置等级路线** | 展示等级路线阶梯、下一等级与「还差多少」、保号进度、任选条件（满足任一项） | 站点专属等级规则匹配、保号判定 | App 直连**已实现**（内置 NexusPHP 默认口径，页面标明「估算」） |
| 多站聚合搜索 | **App 逐站直连站内搜索页**；配置后端时可回退 | 逐站解析结果（id / 标题 / 大小 / 做种 / 下载 / 促销 / 分类 / 时间）、并发 3、可中途停止、逐站失败原因 | 按站点并发检索、结果分批返回、单站失败原因 | App 直连**已实现**；MP 增强仍由后端提供 |
| 下载器任务与操作 | **App 直连 qBittorrent WebUI**（`/api/v2`）；非 qB 引擎走后端 | 任务列表 / 全局速度 / 分类标签路径候选、暂停 / 继续 / 删除 / 改分类 / 改标签 / 改路径、状态计数筛选与排序 | 各引擎协议调用（Transmission / Aria2）与凭据托管、写操作幂等键 | qBittorrent 直连**已实现**；<br>Transmission / Aria2 需后端（无后端时页面说明原因） |
| 保种 / 做种统计 | 下载器任务（tracker 归属）+ 站点账户数据 | 展示做种 / 暂停 / 辅种 / 做种体积、时魔标注（估算须标注） | 任务读取、按 tracker 归站、时魔估算（窗口 0.5–12h）、健康告警 | 部分可用（直连任务已通，跨站归集待补） |
| 站点用户详情（连接数） | 站点用户详情页：BT 客户端列表 | 展示连接数 / 客户端 / IP 聚合 | 定时采集、uid 缓存、请求上限与同站间隔 | 直连模式暂未采集（标「未采集」） |
| H&R 情况 | 站点用户页 H&R 区块 | 展示 H&R 计数与风险项 | 解析 H&R 区块 | 直连已解析（`H&R 0/0/15` 形态），风险项计算待补 |
| 登录 / 签到 | 站点登录与签到页 | 触发批量 / 单站签到、展示结果与原因 | 逐站登录与签到、失败补签、cron 调度 | 仅后端（未实现）；App 已有签到页与记录模型 |
| 地址与链路 | 客户端直连探测 | 地址录入、内外网分别探测、**一个按色切换按钮**、结果持久化 | 提供 `/api/v1/health` 供选路判定 | App 已完成；V1.5 合并按钮 |

## 2. 参考实现要点（本轮对齐依据）

参考仓库与站点：
[`jxxghp/MoviePilot-Plugins`](https://github.com/jxxghp/MoviePilot-Plugins)、
[`KoWming/MoviePilot-Plugins`](https://github.com/KoWming/MoviePilot-Plugins)、
[`changzhanghs/MoviePilot-Plugins`](https://github.com/changzhanghs/MoviePilot-Plugins)、
[`pt-plugins/PT-depiler`](https://github.com/pt-plugins/PT-depiler)、公开状态页 <https://savept.icu/>。

| 需求里提到的名字 | 参考实现 / 数据源 | 本轮落地口径 |
| --- | --- | --- |
| PT 监护室（savept.icu / Vue-PT 监护室） | 公开状态页 savept.icu：站点卡片（存活 / 站庆 / 开站关站）+ 四类公告；历史接口 `/api/history/dead|anniversary` | App 直连并解析（`SavePtMonitorClient`），顶部统计本地汇总，失败回退缓存并标注；见规格书 §22.1 |
| PT 数据统计（`plugins.v2/ptdatastatistics`） | 数据源为 MoviePilot 已保存的站点用户数据；当日 = 当日累计 − 前一自然日累计，缺快照显示「基线不足」 | 直连站点用户页取代 MoviePilot 数据源，口径保持一致：今日增量缺基线 → 「基线不足」，累计下降按 0；见 §22.2 |
| PT-depiler「我的数据 · 时间轴」 | 浏览器端按站点列出历史数据 | 本机每日采样按自然日列出增量与累计，非相邻日不标增量；见 §22.2 |
| PT-depiler「我的下载器」/ Bit Control | 浏览器 / 客户端直接调用下载器接口并展示任务与速度 | App 直连 qBittorrent `/api/v2`，任务页加全局速度条与状态计数；见 §22.5 |
| 站点自动签到（`plugins/autosignin`） | 每站一个 `_ISiteSigninHandler`（`match` + `signin`） | 签到仍由后端下发（`SignInMode` / `SignInAction`），直连模式未实现签到页解析 |
| 站点数据统计（`plugins/sitestatistic`） | 按框架解析站点用户页 | 直连解析 NexusPHP 用户页（标签 + 就近数值的宽容口径） |
| 站点数据刷新 | 插件的定时 / 手动刷新 | App 逐个直连刷新（`SiteRefreshController`），配置后端时同时下发后端刷新 |
| 搜索实时展示 | PT-depiler 状态弹窗 + 逐站结果表 | 逐站直连（并发 3、可停止、逐站归因），见 §22.4 |

> 「PT 保号状态」「站点考核状态」在参考仓库里没有同名插件：保号能力由 `ptdatastatistics` 的
> 养老进度承担；考核 / H&R 由 `contractcheck` 与 `hrblocker` 承担。本文件与规格书按这个映射描述，
> 不虚构不存在的插件能力。

## 3. 直连数据源的实现边界（V1.5）

集中在 `mobile/flutter_app/lib/core/direct/`：

| 文件 | 职责 |
| --- | --- |
| `savept_monitor_client.dart` | 监护室公开状态页抓取与解析（含历史事件接口） |
| `nexusphp_client.dart` | 站点用户页与站内搜索页抓取与解析（`NexusPhpUserParser` / `NexusPhpSearchParser`） |
| `site_stats_service.dart` | 快照 + 本地采样 + 等级规则 → `SiteStats` |
| `stats_history_store.dart` | 本机每日采样（今日增量 / 综合时魔估算 / 时间轴） |
| `care_rules.dart` | 内置等级路线与保号进度评估 |
| `qbittorrent_client.dart` | qBittorrent WebUI `/api/v2` 客户端（登录 / 任务 / 选项 / 写操作） |
| `downloader_gateway.dart` | 下载器通道：qB 直连优先、后端回退、非 qB 引擎走后端 |
| `site_search_gateway.dart` | 搜索通道：逐站直连优先、后端回退 |
| `direct_providers.dart` | 直连相关的 provider（Dio 复用 App 代理设置、监护室缓存、会话缓存） |

纪律：

- 产出模型与后端接口一致，因此页面不区分数据来源；后端落地后只需把 provider 的取数指向 `api_*` 即可切换。
- 解析失败 / 凭据缺失 / 限流 / 网络不可达分别归类（`SiteFetchFailureKind` / `DownloaderFailureKind`），
  界面按分类给出可执行建议；**不得把失败原因写成与数据源无关的结论**（本轮的六处「获取失败」正是该问题）。
- 解析器必须能用页面结构样本做单元测试；页面改版时解析不到结构要明确报「结构未识别」，不静默返回空。

## 4. 本轮需要补的字段（App 侧模型）

现有字段（`lib/core/models/status_models.dart` 的 `SiteStats`）：上传、下载、分享率、魔力、做种数、
下载中数量、加入时间、等级、今日签到、连续签到、保号状态与进度、综合时魔、H&R、邮件未读数、邀请数、
连接数、刷新时间与刷新状态（四态）、今日上传 / 下载与基线标记、等级路线、任选条件、保种契约。

V1.5 新增：

| 字段 | 含义 |
| --- | --- |
| `SiteStats.signInKnown` | 签到状态是否真的采集到；直连模式为 `false`，界面显示「未采集」而不是「未签到」 |
| `SiteStats.levelSteps` | 等级路线阶梯（每个等级的门槛与是否达成） |
| `SiteStats.promotionNote` | 等级规则口径说明（例如「按 NexusPHP 默认规则估算」） |
| `PtDataSnapshot.signInKnownCount` | 真的采集到签到状态的站点数（用于「今日签到」分母） |
| `SiteUserSnapshot`（直连私有模型） | 站点用户页解析结果与缺失字段清单 |
| `MonitorDashboard` 系列模型 | 监护室站点卡片、公告分组、历史事件与缓存序列化 |

所有新字段一律「缺省即未提供」，不填 0 冒充；需要区分「0」与「无数据」的地方另给布尔标记。

「保种契约」与「保号进度」是两套口径，页面上分开呈现：前者看未完成的契约项数量（`hrCount`），
后者看等级与分享率等保号条件。

## 5. 站点刷新状态口径

面板筛选用的四态由数据来源给出，App 只渲染：

| 状态 | 判定 |
| --- | --- |
| 已刷新 | 本次刷新成功且数据时间在阈值内（参考 seedstats 默认 24 小时） |
| 未刷新 | 从未成功刷新，或上一次刷新已超过阈值 |
| 失败 | 最近一次刷新失败，`err_msg` / `refreshMessage` 有具体原因 |
| 未登录 | 凭据缺失 / 失效，需要重新登录或导入 Cookie |

直连模式下：成功解析 → 「已刷新」；缺少 Cookie / 登录态失效 / 被限流 → 「未登录」；
其他失败（网络、结构未识别、HTTP 错误） → 「失败」，并在卡片上写明原因分类与建议。

## 6. 后端接口（保留为可选回退通道）

| 方法 / 路径 | 用途 |
| --- | --- |
| `GET /api/v1/sites/{id}/stat` | 单站数据面板字段（含刷新状态、时魔、H&R、邮件、邀请、连接数） |
| `POST /api/v1/sites/{id}/refresh`、`POST /api/v1/sites/refresh` | 单站 / 全部刷新 |
| `GET /api/v1/sites/{id}/clients` | BT 客户端列表（服务器筛选数据源） |
| `GET /api/v1/sites/{id}/torrents` | 该站下载中种子（含促销标签） |
| `GET /api/v1/stats/overview?range=day\|week\|month` | 我的数据与统计趋势（含历史快照） |
| `GET /api/v1/care/plan` | 等级路线、下一等级条件、保号目标与任选条件（站点专属规则） |
| `GET /api/v1/seedstats` | 按站点汇总的做种 / 辅种 / 体积 / 时魔估算 |
| `GET /api/v1/downloaders/{id}/tasks`（扩展参数） | 任务页需要的排序、状态、分类、标签、路径、服务器筛选 |

> 现有契约（搜索、推送、任务、个人数据、监护事件、签到）见 [`api-contract.md`](api-contract.md)；
> 直连数据源的目标地址与参数见该文件 §9。