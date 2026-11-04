# PT Pocket

面向个人 PT 用户的自托管移动管理中枢：站点凭据与状态、多下载器任务、多站聚合搜索与推送、
个人数据与养老进度、站点监护与签到，统一由自有 NAS 后端调度，App 只负责交互与展示。

## 0. 第一条规则：构建前必读规格书

1. **构建 / 打包 / 发版前，必须重新通读一遍《PT Pocket 产品需求与 App 设计规格书》**
   —— 仓库内路径 [`docs/需求规格书.md`](docs/需求规格书.md)。该文件是需求基线与验收基线，
   改代码前先读它，改完之后把行为变更同步回写进它。
2. 规格书里区分「当前源码事实」与「目标产品要求」，验收以规格书为准，不以“代码里已经有”为准。

- 规格基线：《PT Pocket 产品需求与 App 设计规格书 V1.2（硬件适配版 + 首轮实现落地）》
- 目标设备：HUAWEI Mate 70 Pro+（HarmonyOS 6.1.0）
- 服务端宿主：威联通 TS-451D、自组设备（PVE）

## 1. 本轮更新（V1.2）

1. **Android release 包网络权限**：`main/AndroidManifest.xml` 补 `INTERNET`、`ACCESS_NETWORK_STATE`
   与 `usesCleartextTraffic`。此前 release 包只合并 `main` 清单，缺权限导致所有出网请求失败，
   表现为“不可达 / 异常 / Failed host lookup”，这是上一轮多项“连不上”问题的共同根因。
2. **地址归一化**：无协议时内网主机补 `http`、公网主机补 `https`；保留显式端口与反代子路径；
   拼接 API 路径不再用 `Uri.resolve`（它会把反代子路径丢掉）；带空白的非法地址直接拒绝。
3. **链路诊断分三档**：可用（2xx 且为 JSON 健康响应）/ 地址可达但后端未就绪 / 不可达，
   并显示实际请求地址与失败类型（超时、证书、域名解析等）。
4. **PTD 备份导入支持 zip**：直接选 PTD 插件导出的 zip，App 自行逐个成员识别并按站点合并
   （名称/地址、Cookie、API Key、Passkey 分属不同成员），无关成员标注「已忽略」与原因。
5. **MoviePilot 内外网双地址**：实例由单一地址升级为内网 + 外网，旧数据按内网/公网自动归位；
   复用与 NAS 服务相同的选路策略（内网优先 2 秒、失败回退外网 10 秒、回网切回、缓存 5 分钟）。
6. **测试后自动保存**：连接与服务、站点、下载器、MoviePilot、推送通道、网络代理在点击
   「测试连接 / 发送测试消息 / 测试代理」后自动落盘已填内容，成功与失败都保存。
7. **CookieCloud 拉取修复**：地址支持反代端口与子路径、协议与 `?uuid=` 形态自动兜底、
   响应体按纯文本兼容多种形态；失败提示带上实际请求地址与失败原因。
8. **规格书入库**：`docs/需求规格书.md`（V1.2）+ 本 README 第一条「构建前必读」规则。

## 2. 仓库结构

```text
.
├── AGENTS.md                 # 协作与工程约定（提交、适配器、迁移、部署）
├── README.md
├── docs/
│   ├── 需求规格书.md          # 需求与验收基线（V1.2，构建前必读）
│   ├── architecture.md       # 架构决策
│   └── api-contract.md       # /api/v1 接口契约
├── mobile/flutter_app/       # Flutter 移动端（android / ios / windows）
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
  （当前版本 4：MoviePilot 由单一地址升级为内外网双地址）；
- 地址一律先过 `lib/core/network/url_utils.dart` 归一化，不要在页面里手写协议拼接；
- 页面上的「测试连接」按钮同时承担“保存”职责：测试后自动落盘已填内容，成功与失败都保存。

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
- 现状：`backend/` 仅有目录与接口约定，尚未实现，因此 `deploy/docker-compose.yml` 目前跑不起来。

## 6. 网络与链路

访问自建服务时始终提供内网与外网（lucky 反代）两条通道：

- 自动模式：内网优先（2 秒探测），失败回退外网（10 秒探测）；
- 已使用外网时仍会先探测内网，回到家庭网络后自动切回内网；
- 选路结果缓存 5 分钟，网络切换事件与请求失败会立即失效缓存；
- 可用性以 API 健康状态（返回 JSON 的 2xx）为准，不以 TCP 可连接为准；
  地址可达但后端未就绪会单独标注，而不是笼统显示“不可用”；
- MoviePilot 实例使用同一套双通道策略。

## 7. 文档

`docs/` 下维护需求规格书、架构决策、接口契约与部署说明。
任何行为变更都要同时更新 `docs/需求规格书.md` 与本 README。