# iOS Unified Reader 任务清单

更新时间：2026-08-21

## 当前状态

- 状态：已进入 V0，Aidoku 上游历史和私有仓库骨架已建立。
- 本地目录：已建立。
- 独立 Git：已初始化，默认分支 `main`。
- GitHub 仓库：已创建，`1106912019pxk-ux/ios-unified-reader`（私有）。
- 上游源码：已导入完整历史，基线 `45fe8231a8da58f70f5f2e152a039fcb49eab4cb`。
- IPA：未构建。

## 已完成

- [x] 从截图还原 P0/P1/P2 需求并标记歧义。
- [x] 明确本项目与 Tachimanga 扩展、动画项目和 Loon 项目分离。
- [x] 调研 Aidoku、Yuedu、Mangayomi、Suwatte、Tachimanga、Paperback、Nyora、KOReader 与 Readium。
- [x] 核对 Aidoku 中 EPUB、本地文件、文字阅读设置和无签名 IPA 工作流。
- [x] 核对 Aidoku Community 中存在 Komiic、Picacomic、E-Hentai 三个来源。
- [x] 核对 Yuedu 的 EPUB/CoreText、WebDAV、OPDS、浏览器网页导入和 Legado 漫画书源能力。
- [x] 核对 Mangayomi 的本地 EPUB、Mihon 仓库和 iOS OpenJDK Zero/JAR 路线。
- [x] 发现并记录 Mangayomi `m_extension_server` 许可证缺失风险。
- [x] 整理 V0、V1、浏览器下载、局域网导入和 IPA 交付方案。
- [x] 用户确认 APK/JAR 不是硬要求，三个来源及既有定制功能可迁移即可。
- [x] 用户确认 UI 技术不限，以视觉和阅读体验为准。
- [x] 用户确认设备使用最新 iOS 26。
- [x] 选择 Aidoku 作为 V0/V1 底座，Yuedu 保留为电子书/局域网参考。
- [x] 核对可用于迁移的 Picacomic、E-Hentai、Aidoku Community Sources 均为 Apache-2.0。
- [x] 确认仓库为 `1106912019pxk-ux/ios-unified-reader`、私有、默认分支 `main`。
- [x] 创建 GitHub 私有仓库，并设置 `origin` 与 `upstream` 分离。
- [x] 导入 Aidoku 完整 Git 历史并固定首个上游基线。

## 等待用户确认

- [ ] 最新表述中的“APK 扩展”是指 Android APK 直接运行，还是 Aidoku `.aix` 来源包。
- [ ] “在线播放”是在线阅读，还是视频/音频播放。
- [ ] 局域网主要协议：WebDAV、OPDS、HTTP、SMB、Komga 或 Kavita。

## 底座确定后

- [x] 确认仓库名、所有者、公开性、默认分支和初始推送范围。
- [x] 初始化独立 Git 并创建独立 GitHub 仓库。
- [x] 固定上游基线并保留许可证/第三方声明。
- [ ] 建立 `CustomSources/`，导入并固定三份 Apache-2.0 Aidoku 来源。
- [ ] 建立旧 JAR 功能到新来源/宿主的逐项迁移清单。
- [ ] 为 Picacomic 实现真正的详情页网络收藏按钮，不再使用特殊章节。
- [ ] 建立无签名 IPA 的 GitHub Actions 工作流。
- [ ] 生成第一个可自签安装的 V0 IPA。
- [ ] 完成三份重点来源与 EPUB/CBZ 的真机验收。
