# PT Pocket 架构说明

> 本文件描述当前仓库的实际结构与本轮已实现的能力边界。基线为
> 《PT Pocket 产品需求与设计规格书 v1.1（硬件适配版）》。

## 1. 总体形态

```
┌────────────────────────┐        /api/v1（内外网双通道）        ┌──────────────────────────┐
│  Flutter 移动端         │ ───────────────────────────────▶ │  NAS 后端（自建）          │
│  · 交互与展示           │ ◀─────────────────────────────── │  · 站点 / 下载器 / MP 适配  │
│  · 本地凭据与配置        │                                   │  · 聚合搜索、推送、巡检      │
│  · 内外网自动选路        │                                   │  · 定时签到与推送           │
└────────────────────────┘                                   └──────────────────────────┘
        │ 直连（可达性探测、CookieCloud 拉取、WebView 登录）
        ▼
  PT 站点 / 下载器 / CookieCloud / Vaultwarden
```

职责边界（规格书 §7.1）：

- **移动端只做交互与展示**：站点页面解析、聚合搜索的并发与去重、下载器协议调用、
  定时任务与推送**全部由 NAS 后端完成**；
- 移动端与后端之间只有一套版本化接口 `/api/v1`，不直连数据库与 Redis；
- 移动端允许直接发起的网络行为只有三类：**地址可达性探测**（连接测试）、
  **CookieCloud 端到端加密数据的拉取与本地解密**、**内置 WebView 手动登录**。

## 2. 仓库结构

```
.
├── AGENTS.md                     # 工程协作约定（提交、适配器、迁移、部署）
├── README.md
├── docs/
│   ├── architecture.md           # 本文件
│   └── api-contract.md           # 客户端已实现的 /api/v1 契约
├── mobile/flutter_app/           # Flutter 移动端（Android / iOS）
│   └── lib/
│       ├── app.dart              # MaterialApp.router 装配
│       ├── main.dart             # 启动：配置继承 → 代理运行时 → 链路守护
│       ├── core/
│       │   ├── adapters/         # 站点与 MoviePilot 适配定义（能力声明）
│       │   ├── config/           # 常量、超时、schema 版本、构建环境
│       │   ├── models/           # 站点 / 下载器 / MoviePilot / 状态数据模型
│       │   ├── network/          # Dio 客户端、拦截器、双通道选路、代理、链路守护
│       │   ├── router/           # go_router 路由与路径注册表
│       │   ├── services/         # NAS 接口契约 + CookieCloud / PTD 解析
│       │   ├── storage/          # 偏好存储、安全存储、各模块仓库、配置继承
│       │   ├── theme/            # 设计令牌、色板、主题
│       │   └── utils/            # 展示格式化
│       ├── features/             # 按模块分包的页面与 providers
│       │   ├── home/ search/ sites/ downloaders/ profile/ monitor/ settings/ shell/
│       └── shared/widgets/       # SectionCard / StatusBadge / 状态视图 / 进度矩阵
├── backend/                      # NAS 后端（目录约定见 backend/README.md）
└── deploy/                       # docker-compose 与部署说明
```

## 3. 移动端分层

| 层 | 位置 | 说明 |
| --- | --- | --- |
| 数据模型 | `lib/core/models/*` | 纯 Dart，JSON 往返 + 宽松字段别名解析 |
| 本地仓库 | `lib/core/storage/*` | 非敏感配置进 `PrefsStore`（`ptp.` 前缀），凭据进 `SecureStore`（`ptp_` 前缀） |
| 接口契约 | `lib/core/services/*` | 只描述 `/api/v1` 的请求与解析，不含站点协议逻辑 |
| 状态 | `lib/features/**/*_providers.dart` | Riverpod `Notifier` / `AsyncNotifier` / `FutureProvider` |
| 页面 | `lib/features/**/*_page.dart` | 只做交互与展示，所有间距/圆角/时长取自设计令牌 |
| 共享组件 | `lib/shared/widgets/*` | 卡片、徽标、加载/空/错误/部分成功状态视图 |

## 4. 适配器与能力声明

- **站点适配定义**（`lib/core/adapters/site_adapter_registry.dart`）：内置的是**框架级**适配定义
  （NexusPHP / Unit3D / Gazelle / 自定义），**不内置任何具体站点名单**，站点由用户自行添加；
- **下载器类型**（`lib/core/models/downloader.dart`）：qBittorrent、Transmission、Aria2，
  引擎差异由服务端适配器消解，移动端只提交统一的任务视图与操作；
- **MoviePilot 适配定义**（`lib/core/adapters/moviepilot_adapter_registry.dart`）：
  默认按 **v2 打通**，**v3 适配层已预留**（当前仅登记配置、不允许参与搜索增强），
  v3 正式版发布后由服务端新增适配器实现即可启用，调用方无需改动。

## 5. 双通道链路与代理（需求 13、15）

```
请求 → EndpointResolver.resolve()
        ├─ 自动模式：先探内网（2s）→ 可用即用
        │            失败再探外网（10s）
        ├─ 仅内网 / 仅外网：跳过另一通道（排障用）
        └─ 缓存 5 分钟；网络变化 / 请求失败 / 手动测试 → 立即失效重选
```

- 可用性以 **`GET {基址}/api/v1/health` 返回 2xx 且响应为 JSON（或空体）** 为准，而不是 TCP 可连接；
  基址带反代子路径时必须拼接而不是 `Uri.resolve`（后者会丢掉子路径）；地址可达但后端未就绪
  （拿到 HTTP 却非本服务的健康响应）会单独标注，不笼统显示“不可用”；
- MoviePilot 实例复用同一套双通道策略（每个实例可有内网 / 外网两条地址）；
- `LinkSupervisor` 监听系统网络变化并周期性复检，**回到家网自动切回内网**；
- `ProxyManager` 把 App 代理设置套用到各业务 Dio：仅支持 **HTTP 代理**
  （dart:io 的代理指令只解析 `DIRECT` 与 `PROXY host:port`，不支持 SOCKS5），
  内网 / 本机地址始终直连，认证通过 `addProxyCredentials` 注入。

## 6. 配置继承与迁移（需求 17）

- 每次配置结构变更：`AppConfig.configSchemaVersion` +1（当前为 **4**：MoviePilot 由单一地址升级为内外网双地址），
  并在 `ConfigInheritanceService` 注册一条**只做补充/改名/结构升级**的迁移；
- 迁移**绝不删除或覆盖用户已填写的值**；过程幂等，可安全重复执行；
- 启动顺序：读偏好 → 跑迁移 → 记录 App 版本；
- 已有测试覆盖：全新安装补默认值、旧版本升级保留用户值、重复启动幂等、
  地址档案落盘后重建容器仍保留。

## 7. 存储与安全边界

- **非机密**：链路地址、主题、代理设置（除密码）、站点/下载器/MP 清单、12 大站点槽位、
  推送开关、搜索历史、收藏；统一走 `PrefsStore`，键集中在 `app_keys.dart`；
- **机密**：站点 Cookie / Passkey / API Key / 账号密码、下载器账号密码、MoviePilot 令牌、
  代理密码、企业微信 Webhook Key、Telegram Bot Token、NAS 会话令牌；
  统一走 `SecureStore`（Android `encryptedSharedPreferences`、iOS `first_unlock`）；
- Vaultwarden 主密码只输入在 WebView 内，**不写入本应用存储、不提交给 NAS**；
- 日志拦截器对 token / pass / key / secret / cookie 字段做掩蔽。

## 8. 页面与交互（需求 18 等）

- 主导航 5 入口：首页 / 搜索 / 站点 / 下载器 / 我的（`StatefulShellRoute.indexedStack` 保留状态）；
- 搜索结果为 **单击 → 资源情况页**（选下载器 + 保存目录 → 开始推送）、
  **长按 → 推送下载器弹框**、**向左滑动 → 下载 / 收藏**；
- 所有列表统一处理规格书 §4.3 的全局状态：首次加载、加载中、部分成功、空状态、
  鉴权失败、限流、服务端错误与手动刷新。

## 9. HarmonyOS 双轨策略

- 当前移动端是 **Flutter Android / iOS 工程，产物为 APK / IPA，不是 HAP**；
- 针对 HUAWEI Mate 70 Pro+（HarmonyOS 6.1.0）的验收需分开确认两件事：
  1. APK 能否安装并正常运行（含卓易通等兼容路径）；
  2. 是否具备鸿蒙原生体验（ArkTS + ArkUI Stage 模型）；
- 长期路径：另建 ArkTS/ArkUI 原生工程作为验证轨，与 Flutter 轨共用同一套 `/api/v1` 契约
  （Stage 模型对后台进程有治理，**不能假设常驻 Android Service**，定时能力应落在 NAS 后端）。

## 10. 质量门禁与已知限制

- 移动端门禁：`flutter analyze` 无问题、`flutter test` 全部通过（当前 90 个用例）；
- 已知限制（环境侧）：
  - 本机未安装 Android SDK / JDK，**无法在本环境产出 APK**，交付物为可构建的源码工程；
  - NAS 后端本轮只交付部署结构、接口契约与实现约定，尚未落地 Python 实现；
  - 未接入真实站点 / 下载器 / MoviePilot 实例，端到端联调需在部署后端后进行。