# PT Pocket

面向个人 PT 用户的自托管移动管理中枢：站点凭据与状态、多下载器任务、多站聚合搜索与推送、
个人数据与养老进度、站点监护与签到。数据通道为 **App 直连优先、NAS 后端可选回退**
（直连公开状态页、站点用户页 / 搜索页、qBittorrent WebUI；见 §1 与 `docs/app-backend-boundary.md`），
NAS 后端实现并可用后，本地直连取不到的条目会自动回退到 `/api/v1`。

## 0. 硬性规则（构建与发布前置）

1. **构建 / 打包 / 发版前，必须重新通读一遍《PT Pocket 产品需求与 App 设计规格书》**
   —— 仓库内路径 [`docs/需求规格书.md`](docs/需求规格书.md)。该文件是需求基线与验收基线，
   改代码前先读它，改完之后把行为变更同步回写进它。
2. **每次项目更新后，必须把本 README、需求规格书的 md 与 Word 两个版本、以及整个项目一起重新推送到 GitHub。**
   一次更新要同时更新 [`README.md`](README.md)、[`docs/需求规格书.md`](docs/需求规格书.md)、
   [`docs/需求规格书.docx`](docs/需求规格书.docx)，再提交并推送到远端；
   不允许只推代码不推文档，也不允许只在本地改完而不推送。
3. 规格书里区分「当前源码事实」与「目标产品要求」，验收以规格书为准，不以“代码里已经有”为准。

- 规格基线：《PT Pocket 产品需求与 App 设计规格书 V1.8（硬件适配版 + 交互改造 + 直连数据源 + 站点模块修复 + 凭据类型可选 + 下载器交互与直连能力）》
- 目标设备：HUAWEI Mate 70 Pro+（HarmonyOS 6.1.0）
- 服务端宿主：威联通 TS-451D、自组设备（PVE）

## 1. 本轮更新（V1.8：下载器模块交互与直连能力）

### 1.1 下载器列表页：视图切换、添加入口与卡片数据

| 事项 | 现在的行为 |
| --- | --- |
| 右上角入口 | 依次是**视图切换**、**刷新**、**「＋」添加下载器**；添加流程复用原有添加页 |
| 视图切换 | **列表图**（每行一个下载器 + 12 项数据网格）与**网格图**（两列卡片 + 状态占比环 / 分类柱状 / 速率曲线）；选择落盘（`ptp.downloaders.viewMode`），重进页面保持 |
| 正文里的添加入口 | 原来的「＋ 添加下载器」悬浮按钮已移除；空清单只提示「点右上角「＋」添加」 |
| 卡片数据 | 直连采集**种子总数 / 各状态计数 / 上传·下载限速 / 剩余空间 / 引擎版本**（qBittorrent 取 `/torrents/info` + `/sync/maindata`，Transmission 取 `torrent-get` + `session-stats` + `free-space`）；引擎没给的字段写「未采集」，限速 0 写「不限」，都不用 0 冒充 |
| 图表口径 | 占比环、分类柱状、速率曲线全部用真实观测值：速率先在内存里采样，采样不足两点时显示「采样中」，不补造数据点 |

### 1.2 任务页交互：左滑、长按多选、筛选、三点操作与添加任务

| 事项 | 现在的行为 |
| --- | --- |
| 单条任务 | **左滑**露出「暂停 / 继续」（按该任务当前状态）与「删除」；删除前二次确认（仅移除记录 / 同时删除文件） |
| 多选 | **长按**任务进入多选（左上角变成退出多选），底部批量条支持全选 / 暂停 / 继续 / 分类 / 标签 / 路径 / 删除；多选期间不做左滑，避免手势打架 |
| 筛选 | 右上角**三横线**打开筛选面板：状态（带各状态计数）/ 分类 / 标签 / 路径 / 服务器 + 排序（6 个排序字段 + 倒序）；候选值只来自当前任务，改动即时生效，有筛选时按钮带角标 |
| 任务操作 | 右上角**三个点**（任务卡片右上角也有）提供更改路径、更改分类、编辑标签、种子限速（KB/s）、复制种子哈希、复制磁力链接、重新汇报、重新校验、强制继续、自动种子管理；引擎不支持的项写明「该下载器不支持」并置灰 |
| 添加任务 | 右上角**「＋」**打开添加面板：种子链接（可多行）、种子文件、自动种子管理、添加分类 / 标签、保存路径、添加后暂停 |

### 1.3 直连能力与「该下载器不支持」口径

1. **qBittorrent（`/api/v2`）**：在原有取任务与暂停 / 继续 / 删除 / 分类 / 标签 / 路径之上，补齐
   **添加种子（链接 / 文件 multipart）、重新汇报、重新校验、强制继续、单任务下载 / 上传限速**，
   并补充读取 `force_start` / `dl_limit` / `up_limit` / `trackers_count` / `magnet_uri`。
2. **Transmission（`/transmission/rpc`）**：新增 `lib/core/direct/transmission_client.dart`——409 会话握手
   （`X-Transmission-Session-Id`）、HTTP Basic 认证、任务字段映射（`status` 数字 → 统一状态、
   `totalSize / leftUntilDone` → 已完成量）、会话统计与 `free-space`；支持添加种子（链接 / `metainfo`）、
   暂停 / 继续 / 强制开始、删除、改保存路径（`location-move`）、标签（整组覆盖：追加 / 移除先取回当前标签再算新集合）、
   重新校验 / 汇报、单任务限速（KB/s 换算）与 `auto-managed`。
3. **能力边界不造假**：Transmission 没有「分类」，分类调用直接报「**该下载器不支持**」并提示改用标签，
   不静默写进标签冒充成功；Transmission 也没有关闭「强制继续」的开关，关闭请求会说明原因；
   qBittorrent 没有「自动种子管理」，菜单该项置灰并写明原因。Aria2 仍只走 NAS 后端转发，后端未配置时给出明确原因。
4. **数据通道**：直连优先；直连因「缺少账号密码 / 网络不通」失败且 NAS 后端可用时回退 `/api/v1`，回退不改变页面结构。

### 1.4 排版、工程与校验

1. **排版对齐**：新增共用组件 `StatGrid`（等宽统计网格）与 `EqualChipGrid`（等宽胶囊网格）——
   固定列数、**行行铺满**，条目数不足一行时用等宽空位补齐，避免「第二行只占一半」；
   下载器列表的 12 项数据、任务卡片指标（改为三列网格）、筛选面板与添加面板的胶囊全部走这两套组件。
2. **任务页顶部**：四个速率指标等宽排列，引擎版本胶囊移到「条数 + 排序」摘要行，不再挤占四列宽度；
   任务卡片移除整排文字按钮，改为「左滑 + 三点菜单」，界面更整齐。
3. **工程**：新增 `lib/core/direct/transmission_client.dart`、`lib/core/direct/downloader_speed_history.dart`、
   `lib/shared/widgets/stat_grid.dart`、`lib/shared/widgets/equal_chip_grid.dart`、
   `lib/shared/widgets/mini_charts.dart`、`lib/features/downloaders/widgets/task_filter_sheet.dart`、
   `lib/features/downloaders/widgets/add_task_sheet.dart`；`SectionCard` 支持长按回调；
   新增偏好键 `ptp.downloaders.viewMode`；版本升到 `0.9.2+17`。
4. **校验**：`flutter analyze` 无任何问题；`flutter test` **305 个用例全部通过**
   （本轮新增 `test/features/downloader_round2_test.dart` 29 个用例与 `test/core/downloader_clients_test.dart` 11 个用例，
   并把既有下载器用例更新到新语义）。

### 1.5 历史轮次（V1.7：站点凭据类型可选择与默认项）

#### 1.5.1 凭据类型不再写死 Cookie

站点分不同架构、不同站点规则，凭据类型不能只有 Cookie。现在的口径是**给默认项、也允许用户自行选择**：

| 事项 | 现在的行为 |
| --- | --- |
| 默认认证方式 | 按站点架构给出推荐项并在下拉里标注「推荐」：NexusPHP → Cookie，BTiTracker → Cookie，Unit3D → API Key，Gazelle → API Key，自定义 → Cookie；用户随时可以改成该架构支持的任何一种 |
| 新增站点架构 | 补齐 **BTiTracker**（BtiTracker / TBDev 系），与 NexusPHP / Unit3D / Gazelle / 自定义并列 |
| 站点是否允许 Cookie 抓取 | 新增站点级开关「允许用 Cookie 抓取该站数据」，默认按域名规则给值：**M-Team 这类禁止以登录态抓取页面的站点默认关闭**，此时认证方式默认落到 API Key，Cookie 选项不再出现，并写明原因；其它站点默认允许，用户可自行改写 |
| 编辑站点 | 「站点架构」「认证方式」不再是只读信息，可在编辑页直接改并立即落盘；把认证方式从 Cookie 改成 API Key 时会提示重新录入对应凭据 |
| API Key 扩展字段 | API Key / 存取令牌类型支持可选的 **UID** 与 **Device ID**（M-Team 官方 API 需要），并在表单里说明用途 |
| 直连数据源归因 | 直连页面解析只在「站点用 Cookie 认证 且 允许 Cookie 抓取」时成立：非 Cookie 认证报「认证方式不支持直连，该站数据需要 NAS 后端或对应 API 适配器」；禁止 Cookie 抓取报「站点禁止 Cookie 抓取」；**只有真的 Cookie 认证且没录凭据才提示缺 Cookie** |

配套改动：`SiteFramework` 新增 `btitracker`；`SiteAdapterDescriptor` 新增推荐认证方式与推荐理由；
新增 `SiteCookiePolicy`（Cookie 抓取域名策略）与 `PtSite.cookieAllowed`（缺省按域名推断，兼容旧数据）；
`SiteAdapterRegistry.defaultAuthTypeFor()` 在关闭 Cookie 时优先落到官方接口凭据；
`NexusPhpClient.requireDirectCookie()` 统一做直连门禁与失败归因；
凭据表单与弹层支持 UID / Device ID。
新增 `test/features/site_auth_type_test.dart`（14 个用例）覆盖默认项、可选集合、Cookie 策略、模型落盘与直连归因。

#### 1.5.2 上一轮（V1.6）：「站点」模块 7 项修复

| 问题 | 现在的行为 |
| --- | --- |
| PTD 导入后站点可访问、已连通却仍显示「缺少凭据」 | 导入前先按本机安全存储校正凭据标记；已有站点若本机缺凭据则**补齐凭据**并置为已配置，本机已有凭据则**不被备份覆盖**；导入结果按「新增 X / 补齐 Y / 保留 Z」分类汇报；新站点的认证方式按真正写入的凭据类型决定 |
| 卡片右上角菜单没有「编辑」 | 菜单补齐「编辑站点」，顺序为 编辑站点 / 测试连接 / 刷新该站数据 / 收藏 / 删除站点 |
| 点击卡片应进入从站点拉取的资源信息 | 卡片点击进入「站点资源」页：站点概况 + **账号数据**（直连站点用户页取到的等级 / 上传下载 / 分享率 / 今日增量 / 魔力 / 做种 / 邀请 / 邮件 / HR / 签到）+ **等级路线** + **站点资源列表**（直连该站列表页，可检索、翻页，点进资源详情并推送下载器） |
| 卡片无法左滑 | 左滑露出「编辑」「删除」（复用与下载器列表一致的 `SwipeActionRow`，同一列表只展开一行） |
| 编辑页还在显示「导入与登录」 | 该分区移除；批量导入入口留在站点列表「更多」菜单，需要抓 Cookie 时用凭据区的「内置浏览器登录」 |
| 小眼睛按钮打码 / 取消打码 | 保留并**落盘**（`ptp.sites.masked`），重进页面保持；打码是替换字符而不是视觉模糊 |
| 田字按钮切换展示信息 | 切换「详细 / 概述」并**落盘**（`ptp.sites.viewMode`）；概述＝三列核心指标 + 做种 / 时魔 / 签到胶囊，详细＝全部指标（含今日增量、契约、保号口径） |
| 界面不工整 | 指标改为**三列对齐网格**（列宽相等、标签在上数值在下、溢出省略），卡片头统一「图标 + 名称 / 域名 + 固定顺序状态胶囊 + 右上角菜单」，卡片尾统一「刷新时间 + 失败原因」，间距与尺寸全部走 `design_tokens` |

配套改动：`SiteListNotifier.reconcileCredentials()`（凭据标记自愈）、`siteResourcesProvider` +
`NexusPhpClient.browse()`（站点资源数据源）、`AppRoutes.siteResourcesPath`、`formatDateTime()`；
新增 `test/features/sites_round2_test.dart`（10 个用例）覆盖上述行为。

#### 1.5.3 NAS 后端架构（10 个模块）

一句话定位：**手机是遥控器，NAS 是一直开机工作的控制中心**——手机负责展示、交互与操作，
后端负责真正执行任务、管理数据、连接外部服务；手机关机 / 没电 / 断网时，定时签到、数据采集与
站点监控仍由后端继续。

| # | 模块 | 主要职责 |
| --- | --- | --- |
| 1 | PT 站点管理 | Cookie / Passkey / 站点适配定义、连接测试、凭据加密存储 |
| 2 | 聚合搜索 | 多站并发搜索、过滤、去重、结果排序 |
| 3 | 自动任务中心 | 签到、保号、站点监控、定时同步 |
| 4 | 数据统计 | 上传 / 下载量、分享率、做种、成长历程快照 |
| 5 | 下载器管理 | qBittorrent / Transmission 多实例任务管理 |
| 6 | MoviePilot 集成 | MP V2/V3 适配、搜索增强、下载推送 |
| 7 | PT 监护室 | 站点风险、站庆、维护、异常提醒 |
| 8 | 消息通知 | 企业微信、Telegram、应用通知 |
| 9 | 数据与凭据中心 | PostgreSQL / Redis、加密凭据、备份 |
| 10 | 网络与任务调度 | 内外网访问、代理、任务队列、重试 |

技术形态：PVE Debian VM 内的 Docker Compose（`pt-pocket-api` / `worker` / `scheduler` /
`postgres` / `redis`），媒体与备份落威联通 TS-451D，PostgreSQL 与 Redis 数据目录不放 NFS；
对外只暴露 `/api/v1`，手机经内网 / Lucky 外网反代访问，含设备授权与请求校验。

设计原则：**核心业务逻辑属于自建 NAS 后端**。MoviePilot、CookieCloud、Vaultwarden、下载器都是
外部集成对象（MP 只用其搜索与推送、CookieCloud 只用于导入 Cookie、Vaultwarden 不擅自读取或保存
用户密码、qB / TR 负责实际下载），PT Pocket 统一管理并保存自己的数据与任务状态。

实施顺序（同规格书 §13）：先打通后端通信与站点管理 / 凭据安全，再做首个站点适配、下载器管理、
多站聚合搜索，随后补定时任务与统计，最后扩展监护室、MP 与通知。App 内已有的直连数据源保留为
**后端不可用时的降级通道**，不再作为后续功能的主实现路径。

### 1.6 历史轮次（V1.5）摘要

引入 App 直连数据源：监护室直连公开状态页；我的数据 / 养老进度直连站点用户页 + 本机每日采样 +
内置等级路线；搜索逐站直连站内搜索页；下载器直连 qBittorrent WebUI；「连接与服务」内外网两个按钮
合并为一个按色切换的按钮。详见规格书 §22。

#### 1.6.1 历史轮次（V1.5）明细：根因与实现

本轮解决的是**同一个根因**：`backend/` 尚未实现（见第 5 节），而监护室、我的数据、养老进度、
站点统计、聚合搜索与下载器任务此前全部只走 NAS 接口 `/api/v1/*`，于是没有可用后端时它们一起失败，
并在界面上写成同一个结论「内网与外网地址均不可用」——这条结论只描述 NAS 服务地址，
与「被检索的站点」「被访问的下载器」没有关系。本轮把这些数据通道改为 **App 直连、后端可选回退**。

1. **PT 监护室（直连公开状态页）**：新增 `lib/core/direct/savept_monitor_client.dart`，
   直接解析公开状态页（默认 `https://savept.icu`，基址可在偏好里改）：顶部「床位 / 健康 / 抢救 /
   死亡 / 今日站庆」统计、四类公告（病危通知 / 恢复公告 / 站庆预告 / 死亡讣告，逐条保留站点名、
   链接与说明）、按年份分组的站点卡片（状态、内站外站、存活天数、站庆倒计时、已死亡天数、
   开站与关站日期、图标、是否已在本机站点清单），另有「历史事件」查看死亡 / 站庆时间线。
   解析不到站点卡片即报「页面结构无法识别」，不把防护页当成「没有数据」；网络失败回退上次快照并标注「缓存」。
2. **我的数据（直连站点用户页 + 本地采样 + 时间轴）**：新增 `lib/core/direct/nexusphp_client.dart`
   带 Cookie 抓 `index.php`，解析上传 / 下载 / 分享率（含 `∞`）/ 魔力 / 做种 / 下载中 / 邀请 /
   未读邮件 / H&R / 等级 / 注册时间；`lib/core/direct/stats_history_store.dart` 在本机按站点记录每日采样
   （最多 400 条），据此给出**今日增量**（缺基线一律「基线不足」）与**综合时魔估算**
   （近 12 小时两次采样差值，标注为本地估算）；「我的数据」新增**时间轴**视图（参考 PT-depiler）。
   站点页没给出的字段写「数据未提供」，签到状态标「未采集」而不是「未签到」。
3. **养老进度（内置等级路线）**：新增 `lib/core/direct/care_rules.dart`，按 NexusPHP 默认口径
   （注册周数 + 上传量 + 分享率）逐级给出等级路线与「还差 N 天（日期）/ 还差 X 上传 /
   分享率需 ≥ N（当前值）」，并按保号目标（默认 Power User）分「健康 / 需关注 / 有掉级风险 / 数据不足」；
   页面明确标注「默认口径估算」，任选条件按「满足任一项」并标出命中项。
4. **站点正常但搜索失败**：搜索改为 **App 逐站直连站内搜索页**（`torrents.php?search=`，带站点 Cookie，
   并发 3、可中途停止、每站单独回填）；失败原因按站归因（缺少凭据 / 登录态失效 / 被限流 /
   网络不可达 / 页面结构未识别），不再把 NAS 通道状态写成站点失败原因；区分「空结果」与「结构不认识」。
5. **下载器任务（直连 qBittorrent WebUI）**：新增 `lib/core/direct/qbittorrent_client.dart`，
   直连 `/api/v2` 取任务、全局速度、分类 / 标签 / 路径候选，并直接下发暂停、继续、删除（可选删文件）、
   改分类、改标签、改保存路径；状态串全量归一化（`stalledUP` / `pausedUP` / `queuedUP` /
   `checkingResumeData` / `missingFiles` 等不再落到「未知」）；任务页新增顶部速度条，
   状态筛选带各状态数量；失败给出可执行原因（含 qBittorrent Host header 校验与封禁提示）。
6. **「连接与服务」按钮合并与布局**：内网 / 外网两个竖排按钮合并为**一个按钮**，
   点一下切换，按钮底色与文字色随当前通道变化（内网＝品牌绿、外网＝信息蓝），
   按钮内仍保留另一条通道的连通标记，底部整体情况始终可见；页面文案、按钮宽度与间距一并重排。
7. **数据模型补齐**：`SiteStats` 新增 `signInKnown` / `levelSteps` / `promotionNote`，
   `PtDataSnapshot` 的签到口径改为只统计真的采集到的站点，`ratioLabel` 支持 `∞`；
   新增监护室模型（`MonitorDashboard` 等）与站点用户页模型（`SiteUserSnapshot`）。
8. **工程与依赖**：新增目录 `lib/core/direct/`（直连数据源与 provider）；
   `pubspec.yaml` 新增 `html: ^0.15.4` 并升级版本到 `0.8.0+14`；
   新增偏好键 `ptp.direct.monitor.baseUrl`、`ptp.direct.monitor.cache`、`ptp.direct.stats.history`（非敏感项）。
9. **校验**：`flutter analyze` 无任何问题；`flutter test` 239 个用例全部通过
   （本轮新增 5 个测试文件覆盖监护室解析、NexusPHP 用户页与搜索解析、等级规则与本地历史、
   qBittorrent 直连、数据组装与下载器通道）。

### 1.7 历史轮次（V1.4：交互改造、实时展示与模块对齐）

1. **地址录入统一**：所有 http/https 地址（连接与服务的服务地址、下载器、MoviePilot、CookieCloud）
   一律「协议点选 + 主机 + 端口 + 可选子路径」，主机与端口分开填、端口有默认值且可改；
   直接粘贴整条 URL 会被自动拆成这几部分。端口留空回落协议默认端口，填错则明确提示，
   绝不悄悄替换成默认值。
2. **连通性实时化**：内网与外网**分别**检测（各自超时档）；地址后直接显示勾 / 叉 / 「地址通、服务未就绪」，
   「服务地址」框底部还会列出两条通道的整体情况与当前优先链路；探测结论落盘，
   重新进入页面按已存地址实测，不再一律显示「未检测」。
3. **内外网改为同一地址区 + 左侧切换**：连接与服务、MoviePilot 不再把内网、外网两栏并排，
   改为左侧「内网 / 外网」按钮切换，一次只渲染一条通道；左侧标签上保留另一条的连通标记，
   底部整体情况始终可见。下载器只有一个地址（由 NAS 后端在同一内网直连），不设内外网切换。
4. **下载器列表交互**：卡片支持**左滑**露出「编辑 / 删除 / 默认」三个动作（右上角三点菜单保留）；
   新增**默认下载器**标记（互斥，推送未指定目标时走它），并为此递增配置版本到 5、
   登记 v4→v5 迁移（旧数据补齐标记，恰好一条为默认）。
5. **下载器任务中心**：进入某个已添加下载器后不再重复展示连接信息与操作框
   （连接是否正常由外层状态圆点表达），改为任务本身：状态筛选、排序（加入时间 / 名称 / 大小 /
   进度 / 速度 / 剩余时间）、多选批量操作，以及暂停、继续、删除（可选同时删文件）、
   分类、标签（追加 / 覆盖 / 移除）、保存路径与服务器筛选。
6. **站点数据面板**：站点页支持按「已刷新 / 未刷新 / 失败 / 未登录」筛选；每站展示图标、
   上传、下载、分享率、做种数、综合时魔、签到情况、连接数、HR 情况、邮件数、邀请数；
   顶部提供数值打码、扩展展示、逐个刷新与「更多」入口（PT 历程 / 监护室 / 一键签到 / 导入）。
   打码直接替换字符，而不是只做视觉模糊（模糊后读屏与文本选择仍会暴露原值）。
7. **搜索实时展示**：一次全量搜索改为**逐站请求**（并发 3、可取消），每站返回即去重并入并整体重排；
   顶部常驻进度「已完成 x/y 站 · 已收到 N 条」，可**中途停止**（保留已收到结果，未完成站点标已取消），
   并可打开「搜索状态」查看每站结论。
8. **签到与数据 / 监护模块对齐参考插件**：签到区分「签到站点」与「仅模拟登录站点」两种下发方式，
   结果标注本次动作与时间，并提示「程序登录不一定被站点计为用户活跃」；「我的数据」新增今日上传 / 下载
   （当日累计 − 前一自然日累计，**缺基线显示「基线不足」而不是 0**）；养老进度补充等级路线与
   任选条件（满足任一项，并标出已命中的那项）、保种契约（H&R）达成情况。
9. **接口契约与边界文档同步**：`docs/api-contract.md` 补齐站点面板字段、刷新接口、
   下载器任务扩展接口与签到 `mode / action`；新增 `docs/app-backend-boundary.md` 记录
   「参考插件能力 → App 侧职责 / NAS 侧职责」的逐条划分。
10. **卡片内的列表项修复**：卡片容器（`SectionCard`）内垫一层透明 Material，
    避免卡片底色盖住开关 / 列表项的点击水波纹（调试模式下会直接抛断言）。

#### 1.7.1 历史轮次（V1.2）摘要

1. **Android release 包网络权限**：`main/AndroidManifest.xml` 补 `INTERNET`、`ACCESS_NETWORK_STATE`
   与 `usesCleartextTraffic`。此前 release 包只合并 `main` 清单，缺权限导致所有出网请求失败，
   表现为“不可达 / 异常 / Failed host lookup”，这是上一轮多项“连不上”问题的共同根因。
2. **地址归一化**：无协议时内网主机补 `http`、公网主机补 `https`；保留显式端口与反代子路径；
   拼接 API 路径不再用 `Uri.resolve`（它会把反代子路径丢掉）；带空白的非法地址直接拒绝。
3. **链路诊断分三档**：可用（2xx 且为 JSON 健康响应）/ 地址可达但后端未就绪 / 不可达，
   并显示实际请求地址与失败类型（超时、证书、域名解析等）。
4. **PTD 备份导入支持 zip**：直接选 PTD 插件导出的 zip，App 自行逐个成员识别并按站点合并
   （名称/地址、Cookie、API Key、Passkey 分属不同成员），无关成员标注「已忽略」与原因。
   选文件入口走 app 模块自带的平台通道 `ptpocket/file_picker`（Android 可用；桌面端暂不支持选择器，
   页面会提示改用粘贴 JSON）——不引第三方选择器插件，原因见 `docs/需求规格书.md` §20.3。
5. **MoviePilot 内外网双地址**：实例由单一地址升级为内网 + 外网，旧数据按内网/公网自动归位；
   复用与 NAS 服务相同的选路策略（内网优先 2 秒、失败回退外网 10 秒、回网切回、缓存 5 分钟）。
6. **测试后自动保存**：连接与服务、站点、下载器、MoviePilot、推送通道、网络代理在点击
   「测试连接 / 发送测试消息 / 测试代理」后自动落盘已填内容，成功与失败都保存。
7. **CookieCloud 拉取修复**：地址支持反代端口与子路径、协议与 `?uuid=` 形态自动兜底、
   响应体按纯文本兼容多种形态；失败提示带上实际请求地址与失败原因。
8. **规格书入库**：`docs/需求规格书.md`（V1.3）与配套的 `docs/需求规格书.docx`，
   加上第 0 节的两条硬性规则。
9. **发布与推送规则**：每次项目更新后，README、需求规格书的 md 与 Word 两个版本、
   以及整个项目必须一起重新推送到 GitHub（见第 0 节第 2 条）。

## 2. 仓库结构

```text
.
├── AGENTS.md                 # 协作与工程约定（提交、适配器、迁移、部署）
├── README.md
├── docs/
│   ├── 需求规格书.md          # 需求与验收基线（V1.8，构建前必读）
│   ├── 需求规格书.docx        # 同一份规格书的 Word 版本（随 md 同步更新推送）
│   ├── architecture.md       # 架构决策
│   ├── api-contract.md       # /api/v1 接口契约
│   └── app-backend-boundary.md  # 参考插件能力与 App / NAS 职责边界
├── mobile/flutter_app/       # Flutter 移动端（android / ios / windows）
│   └── lib/core/direct/      # App 直连数据源（监护室公开状态页 / 站点用户页与搜索页 / qBittorrent WebUI / Transmission RPC / 本地采样）
├── backend/                  # NAS 后端服务（FastAPI + PostgreSQL + Redis）
│   └── README.md             # 目前只有目录与接口约定，尚未实现
├── deploy/                   # docker-compose 与部署约定、.env.example
└── .github/workflows/
    └── build-apk.yml         # 推送 v0.7.0 分支或手动触发即产出 release APK
```

## 3. 移动端（Flutter）

```bash
cd mobile/flutter_app
flutter pub get
flutter analyze
flutter test
flutter run          # 需连接设备或模拟器
flutter build apk    # 需安装 Android SDK + JDK 17
```

约定：

- 状态管理 `flutter_riverpod`，分层为 data provider / service provider / ui provider；
- 路由 `go_router` + `StatefulShellRoute.indexedStack`，五个底部主入口状态互不丢失；
- 所有间距、圆角、动效时长取自 `lib/core/theme/design_tokens.dart`，不在页面内硬编码；
- 非敏感配置走 `SharedPreferences`，凭据与令牌走 `flutter_secure_storage`；
- 配置结构变更必须递增 `AppConfig.configSchemaVersion` 并注册迁移，保证升级后用户已填配置自动继承
  （当前版本 5：新增下载器的「默认下载器」标记）；
- 地址录入一律走 `lib/shared/widgets/address_field.dart` 的 `AddressInput`（协议点选 + 主机 + 端口 + 子路径），
  内外网双通道用 `lib/shared/widgets/channel_switch.dart` 的 `ChannelSwitch` 切换，不要在页面里另写一套；
- 站点的数据统计、刷新与监护事件**优先由 `lib/core/direct/` 直连**（监护室公开状态页、站点用户页、
  qBittorrent WebUI），NAS 后端可用时对本地取不到的站点回退后端；「今日增量」「综合时魔」「保种契约」
  这类可能缺数据的指标必须区分「0」与「未提供 / 基线不足」，不填 0 冒充；时魔为本地估算时必须标注；
- 站点的认证方式：默认项由 `SiteAdapterRegistry.recommendedAuthType()` 给出（Unit3D / Gazelle 推荐 API Key），
  表单里标注「推荐」但用户可以改；是否允许 Cookie 抓取由 `SiteCookiePolicy` 给默认值 + 站点级开关覆盖，
  拿不准时以站点规则为准；新增架构时必须同时补 `SiteAdapterDescriptor`（含推荐认证方式与推荐理由）；
- 站点模块结构：列表 `features/sites/sites_page.dart`（打码 / 详细概述 / 左滑 / 卡片菜单）、
  「站点资源」`features/sites/site_resources_page.dart`（账号数据 + 等级路线 + 站点资源列表）、
  编辑 `features/sites/site_detail_page.dart`（站点信息 / 连接测试 / 凭据 / 参与范围）；
  凭据标记以安全存储为准，列表加载与 PTD 导入前都会先做一次校正；
- 地址一律先过 `lib/core/network/url_utils.dart` 归一化，不要在页面里手写协议拼接；
- 页面上的「测试连接」按钮同时承担“保存”职责：测试后自动落盘已填内容，成功与失败都保存；
- 下载器模块结构：列表 `features/downloaders/downloaders_page.dart`（列表图 / 网格图切换、卡片数据与图表、左滑）、
  任务中心 `features/downloaders/downloader_detail_page.dart`（左滑 / 长按多选 / 三横线筛选 / 三点操作 / 右上角「＋」添加任务）、
  面板 `features/downloaders/widgets/task_filter_sheet.dart` 与 `features/downloaders/widgets/add_task_sheet.dart`；
- 下载器直连：qBittorrent 见 `lib/core/direct/qbittorrent_client.dart`、Transmission 见 `lib/core/direct/transmission_client.dart`，
  统一由 `lib/core/direct/downloader_gateway.dart` 按引擎分发，直连失败且后端可用时回退 `/api/v1`；
  引擎不支持的能力必须报「该下载器不支持」并写明原因，**不得静默改写或用别的字段冒充**（例如把标签当分类）；
- 统计项 / 筛选项 / 胶囊类排版一律用 `lib/shared/widgets/stat_grid.dart` 的 `StatGrid` 与
  `lib/shared/widgets/equal_chip_grid.dart` 的 `EqualChipGrid`（等宽 + 行行铺满），不要在页面里用裸 `Wrap` 拼出半行。

## 4. Android 构建与发版

- 清单必须声明 `INTERNET` 与 `ACCESS_NETWORK_STATE`，并允许内网明文 http（`usesCleartextTraffic`）；
  改动清单后，要拆开构建产物核验权限，而不是只看源码。
- `minSdk 24`、`compileSdk / targetSdk 36`、JDK 17；release 目前使用 debug 签名（个人自用直装可用），
  换正式 keystore 后旧包需先卸载再装。
- CI：`.github/workflows/build-apk.yml`，推送 `v0.7.0` 分支或手动 Run workflow 触发；
  产物为 Actions 运行页底部的 `pt-pocket-*-apk` artifact。
- **发版前先回到第 0 节第 1 条：重读 `docs/需求规格书.md`。**

## 5. 服务端（NAS 后端）

- 部署目录固定为 `/data/docker-compose/pt_pocket` 或其子目录。
- 站点访问、搜索并发、定时任务与通知统一在后端调度，移动端不直连数据库与 Redis。
- PostgreSQL 与 Redis 的数据目录不放在 NFS 上。
- 对外只暴露 `/api/v1` 版本化接口；错误码规范见规格书 §9.5。
- 凭据与认证方式的差别（Cookie / Passkey / API Key / 账号）由站点配置驱动；后端适配器按
  `auth_type` 选择对应取数方式，App 直连只覆盖 Cookie + 页面解析这一条路径，其余由后端承担。
- 后端模块划分（10 个）：PT 站点管理、聚合搜索、自动任务中心、数据统计、下载器管理、MoviePilot 集成、
  PT 监护室、消息通知、数据与凭据中心、网络与任务调度；落到组件的映射见规格书 §7.3.1，摘要见 §1.2。
- 实施顺序：后端通信 + 站点管理 / 凭据安全 → 首个站点适配 → 下载器管理 → 多站聚合搜索 →
  定时任务与统计 → 监护室 / MP / 通知扩展。
- 现状：`backend/` 仅有目录与接口约定，尚未实现，因此 `deploy/docker-compose.yml` 目前跑不起来。
  这期间监护室 / 我的数据 / 养老进度 / 站点统计 / 搜索 / 下载器任务由 App 直连数据源承担
  （见 §1、§6 与 `docs/app-backend-boundary.md`），后端落地后同一套模型可直接切回后端；
  该直连通道保留为降级路径，后续新功能一律先落后端与 `/api/v1` 契约。

## 6. 网络与链路

访问自建服务时始终提供内网与外网（lucky 反代）两条通道：

- 自动模式：内网优先（2 秒探测），失败回退外网（10 秒探测）；
- 已使用外网时仍会先探测内网，回到家庭网络后自动切回内网；
- 选路结果缓存 5 分钟，网络切换事件与请求失败会立即失效缓存；
- 可用性以 API 健康状态（返回 JSON 的 2xx）为准，不以 TCP 可连接为准；
  地址可达但后端未就绪会单独标注，而不是笼统显示“不可用”；
- MoviePilot 实例使用同一套双通道策略。
- 两条通道的地址在界面上填完即自动探测、结果会持久化：重新进入页面显示的是上次真实结论，
  不是「未检测」；「地址可达但后端未就绪」与「网络不可达」分开呈现。
- 搜索按站点逐个下发请求（并发上限 3），因此进度与结果可以同时看到，也支持中途停止。
- V1.5 起这些数据通道为「**直连优先、后端可选回退**」：监护室读公开状态页；我的数据 / 养老进度 /
  站点统计读站点用户页（带该站 Cookie）并在本机记录每日采样；搜索读站内搜索页；下载器任务读
  qBittorrent WebUI（`/api/v2`）。已配置 NAS 后端时，本地直连取不到的条目才会回退后端接口，
  失败原因按「本站自己的原因」呈现，不再统一显示成 NAS 服务地址的问题。
- 直连所用的凭据全部来自本机安全存储（站点 Cookie / Passkey、下载器 WebUI 账号密码），
  不与 NAS 令牌混用；偏好里新增的数据源设置（`ptp.direct.monitor.baseUrl` 等）为非敏感项。

## 7. 文档

`docs/` 下维护需求规格书（md 与 Word 两个版本）、架构决策、接口契约与部署说明；
`docs/app-backend-boundary.md` 记录「每块能力的数据从哪来、App 直连做什么、NAS 后端做什么」。
任何行为变更都要同时更新 `docs/需求规格书.md`、与 md 同口径的 `docs/需求规格书.docx` 以及本 README，
并按第 0 节第 2 条把三者连同整个项目一起推送。