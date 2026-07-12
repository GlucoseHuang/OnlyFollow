# OnlyFollow

> **反推荐视频聚合客户端** —— 只看自己关注的人，没有算法，没有信息流。

---

## ⚠️ 使用范围

这是一个**纯自用项目**，仅供作者个人在自有设备上运行：

- ❌ 不签名、不上架、不分发
- ❌ 不面向终端用户，无客服、无 SLA
- ✅ 源码公开仅作技术参考 / 学习交流
- ⚠️ 抖音 / B 站的接口均为非官方逆向，随时可能因签名算法更新而失效
- ⚠️ 视频、评论、弹幕版权归原作者与平台所有
- ⚠️ 因使用本项目产生的任何账号风控、法律问题由使用者自行承担

> 实现参考了 [Simple Live](https://github.com/xiaoyaocz/dart_simple_live) 的协议层思路。

---

## 核心理念

**不是另一个视频 App，是"反推荐"工具。**

- 任何功能决策都必须回答一个问题：**会不会让用户无意识地进入算法信息流？**
- 如果会，**不做**或**用最显眼的确认动作保护用户**
- 明确不做：热门 / 猜你喜欢 / 好友也在关注 / 关注分组 / 视频下载

---

## 支持的内容源

| 平台 | 状态 | 说明 |
|------|------|------|
| 抖音 | ✅ | 网页端逆向接口 + 内嵌 WKWebView 取签名（X-Bogus / A-Bogus） |
| 哔哩哔哩 | ✅ | WBI 签名 + WebSocket 直播弹幕 |

---

## 功能一览

### 内容浏览
- ✅ 关注列表（按平台 tab 区分）
- ✅ 正在直播置顶 + 实时观看人数
- ✅ 新视频缩略图墙（按更新时间倒序）
- ✅ 视频内播放（AVPlayer，支持横竖屏、进度条）
- ✅ 直播间播放（FLV / HLS，实时弹幕）
- ✅ 历史弹幕叠加 / 历史评论抽屉

### 管理
- ✅ UID / 主页链接添加关注
- ✅ 长按 / 左滑移除关注
- ✅ 本地搜索（标题 / UP 主名）

### 后台与同步
- ✅ `BGTaskScheduler` 后台增量刷新
- ✅ 多设备数据同步（基于 GitHub 私有 repo Contents API，后端可自建）
- ✅ Schema 版本管理 + 自动 wipe 旧 store

### AI 增强（可选）
- ✅ 本地向量推荐：调用阿里云百炼 DashScope `text-embedding-v4`（默认 1024 维），本地余弦相似度排序
- ✅ LLM 智能推荐：调用 DeepSeek `deepseek-v4-flash`（用户主动触发，默认链路不调用）
- ✅ 离线 cosine 检索可用；LLM 失败时降级到本地

---

## 技术栈

| 类别 | 选型 |
|------|------|
| 最低系统 | iOS 17.0 / iPadOS 17.0 |
| UI | SwiftUI |
| 数据 | SwiftData（`@Model`，Schema 自动迁移） |
| 网络 | `URLSession` + WebSocket via [Starscream](https://github.com/daltoniam/Starscream) |
| 图片 | [Kingfisher](https://github.com/onevcat/Kingfisher) |
| 抖音协议 | 内嵌 WKWebView 取签名 + [SwiftProtobuf](https://github.com/apple/swift-protobuf) 解码直播间帧 |
| 后台 | `BGAppRefreshTask` |
| 同步 | GitHub Contents API（私有 repo） |
| 工程化 | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml`) |

源码规模：约 **25,000 行 Swift**。

---

## 构建

### 1. 准备工具

```bash
# macOS, 已装 Xcode 16+
brew install xcodegen
```

### 2. 生成 Xcode 工程

```bash
cd OnlyFollow
xcodegen generate
open OnlyFollow.xcodeproj
```

> `project.yml` 中的 `DEVELOPMENT_TEAM` 是占位符 `YOUR_TEAM_ID`，在 Xcode → Signing & Capabilities 里改成你自己的 Apple Developer Team 即可。

### 3. 配置个人信息（运行后，在 App 的"设置"页填写）

| 项 | 必填 | 说明 |
|----|------|------|
| Apple Developer Team | ✅ | 仅构建 / 签名需要 |
| B 站 Cookie | 可选 | 不填只能看公开内容 |
| 抖音 Cookie | 可选 | 不填只能看公开内容 |
| 百炼 Embedding API Key | 可选 | 不填则本地推荐不可用 |
| DeepSeek API Key | 可选 | 不填则 LLM 推荐不可用 |
| GitHub PAT + 同步 repo | 可选 | 不填则多设备同步关闭 |

所有密钥都只存在 iOS 沙盒的 `UserDefaults`，**不在源码、也不在任何同步快照里**。

---

## 多设备同步

> 实现思路详见 [`需求文档-v0.1.md`](./需求文档-v0.1.md) 与 `OnlyFollow/Services/Common/SyncStorage.swift` 顶部注释。

简版：

1. 准备一个空的 GitHub 私有 repo（Student Developer Pack 送的 Pro 够用）
2. 在 App 设置页填入 PAT（`repo` scope）和 `owner/repo` 路径
3. App 会用 GitHub Contents API 把 Gzip 压缩的 JSON 快照写到 `snapshot.json`
4. 5 秒 debounce + 后台强制 flush + 回前台自动 pull
5. 用 `deviceID` + 422-SHA-retry 处理并发写

> 为什么不直接用 iCloud Drive？沙盒同步是事件式的，"merge 完成"语义拿不到，自己 pull/push 写出来更可控。

---

## 项目结构

```
OnlyFollow/
├── OnlyFollowApp.swift          # @main, ModelContainer, BGTask 注册
├── Info.plist                   # ATS 例外（CDN 多为 HTTP FLV）
├── Models/                      # @Model: FollowedCreator / FavoriteVideo / ...
├── Views/                       # SwiftUI 视图
├── Components/                  # 复用 UI（播放器、弹幕、浮动评论）
├── Services/
│   ├── Bilibili/                # B 站 API、登录、弹幕
│   ├── Douyin/                  # 抖音 API、签名、登录、protobuf 协议
│   ├── Common/                  # 同步 / 推荐 / 嵌入 / 后台 等通用服务
│   └── PlayerPresenter.swift
├── SyncRecord.swift             # 同步快照的 DTO（与 SwiftData 解耦）
├── Resources/                   # 资源
└── Assets.xcassets/             # 启动图、AppIcon
```

---

## 已知限制

- 抖音签名算法失效后需更新 `DouyinSignJS.swift`（或等 WKWebView 自动重新加载）
- 非官方客户端可能被平台限速到 720p（自用接受此限制）
- 不发送弹幕 / 评论（v0.1 设计为只读）
- 多设备同步是 last-write-wins，不做字段级 CRDT

---

## License

源码仅供学习参考，不构成任何形式的授权。

如果你 fork 后想商用 —— **请不要**。协议随时会变，作者不保证兼容性。
