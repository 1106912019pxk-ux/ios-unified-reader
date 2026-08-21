# iOS Unified Reader 项目说明

更新时间：2026-08-21

## 项目定位

这是一个全新的 iOS 阅读器二次开发项目，目标是基于合适的开源项目，形成可由用户自行签名安装的 IPA。

本项目与以下既有项目完全分离：

- `Tachimanga_Custom_Extensions`：只维护 Tachimanga 的 E-Hentai、Picacomic 等扩展；
- `kazumi-stremio-addon`：只处理在线动画与 Stremio Add-on；
- `loon-scripts`、`Afuze_Extension`：继续保持各自边界。

当前目录已成为独立仓库 `ios-unified-reader`。Aidoku 官方完整 Git 历史已导入，本项目以提交 `45fe8231a8da58f70f5f2e152a039fcb49eab4cb` 为首个固定基线；`upstream` 指向 `Aidoku/Aidoku`，`origin` 指向用户的私有仓库 `1106912019pxk-ux/ios-unified-reader`。

## 当前结论

根据用户在 2026-08-21 的确认，当前选择 **Aidoku 作为 V0/V1 主底座**：

- APK/JAR 不是硬要求，只要 Komiic、Picacomic、E-Hentai 三个重点来源可用；
- 允许把现有 Kotlin/JAR 功能迁移到 Aidoku 的 Rust/WASM `.aix` 来源；
- SwiftUI/UIKit 或 Flutter 都可以，重点是界面不过时、阅读体验好；
- 用户设备使用最新 iOS 26，系统版本不是候选限制；
- Aidoku 已有三个来源的 Apache-2.0 社区实现，漫画和下载基础成熟，迁移风险低于在 Yuedu 中从头实现三个复杂来源；
- Aidoku 的 EPUB、浏览器和局域网能力可以分阶段增强，必要时再引入 Readium。

Yuedu 保留为 EPUB、CoreText、WebDAV、OPDS 和网页导入的产品/架构参考；Mangayomi 不再作为主底座，但其 iOS JAR 运行桥保留为技术资料。

完整材料：

- [需求整理](REQUIREMENTS.md)
- [候选项目调研](CANDIDATE_RESEARCH.md)
- [源码与许可证记录](SOURCE_LICENSES.md)
- [开发与交付方案](PLAN.md)
- [任务清单](TASKS.md)
- [本项目协作边界](AGENTS.md)

## 当前边界

- 已进入 V0 仓库初始化阶段，可以导入上游源码、建立来源目录和云端构建；尚未开始大规模功能改造。
- 本阶段不建立本地 iOS/Xcode 验证环境。
- GitHub 私有仓库已创建，默认分支为 `main`；代码开发后通过云端构建 IPA。
- 用户最新提出“原生 Aidoku + APK 扩展”的首版口径。开始实现运行时前，需确认其中的 APK 是指 Android APK 直跑，还是 Aidoku 的 `.aix` 来源包；此前已确认 APK/JAR 直跑不是硬要求。
