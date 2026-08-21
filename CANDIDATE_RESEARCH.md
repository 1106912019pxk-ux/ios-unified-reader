# 候选开源项目调研

调研日期：2026-08-21

## 1. 结论摘要

不存在无改造即可满足全部需求的开源 iOS 阅读器。用户已确认 JAR 不是硬要求、UI 技术不限且设备为最新 iOS，因此 **V0/V1 选定 Aidoku**。

- **漫画与三个重点来源优先**：Aidoku 风险最低。
- **APK/JAR 直接兼容优先**：Mangayomi 是当前唯一值得做真机验证的候选，但其 UI 和许可证链需要接受或解决。
- **原生电子书体验与局域网书库优先**：Yuedu 最接近目标，但漫画来源要重新适配，而且要求 iOS 18+。

Aidoku 胜出的原因不是它单项功能最多，而是三个重点漫画来源已经存在、来源可以独立更新、许可证清晰；其缺失的 EPUB 深度、浏览器下载和局域网导入可以在宿主中逐步补齐。相比之下，在 Yuedu 中从头实现三个复杂账号来源，或在 Mangayomi 中承担 Java 运行桥风险，都更容易让第一版失控。

## 2. 核心候选对比

| 候选 | 已具备的关键能力 | 主要缺口或风险 | 当前定位 |
|---|---|---|---|
| Aidoku | Swift iOS App；成熟漫画书架、下载、WASM `.aix` 来源；社区已有 Komiic、Picacomic、E-Hentai；本地 CBZ/ZIP/EPUB；文字阅读器已有字体、字号和行距等设置；上游已有无签名 IPA 工作流 | EPUB 解析器明确是 Minimal EPUB 2/3，会损失复杂 CSS/版式；没有通用浏览器下载到书库；没有 WebDAV/OPDS 通用导入；不能直接运行 APK/JAR；GPLv3 要求分发修改版时提供对应源码 | 最稳的漫画底座与默认回退方案 |
| Yuedu | SwiftUI/CoreText 原生 UI；EPUB3、TXT、CBZ、听书，PDF 开发中；竖排、主题、批注、书签、TTS；WebDAV、OPDS、RSS；内置浏览器可抽取网页正文或章节并导入；支持 Legado 3.0 JSON 书源及漫画类型 | 2026-05 才建立，生态和回归时间较短；要求 iOS 18+；Legado 兼容层有明确缺口；没有现成 Komiic、Picacomic、E-Hentai；不能直接运行 APK/JAR | 最好的原生电子书/局域网底座 |
| Mangayomi | Apache-2.0 主项目；iOS 15；漫画、小说、动画/视频、本地阅读、EPUB、CBZ/ZIP、书架、下载；Dart/JS 扩展；当前代码还支持 Mihon 仓库和 iOS 真机内的 OpenJDK Zero 解释器，可通过本地扩展服务器运行 JAR | Flutter UI，不是真正 Swift 原生；iOS Java 运行只支持真机，后台会暂停；体积、启动、性能和三份现有 JAR 都必须实测；`m_extension_server` 仓库的 LICENSE 目前只是 TODO，二进制再分发权利不明确；通用浏览器下载和局域网书库仍需二开 | 功能命中率最高，但必须先过技术与许可证门槛 |

## 3. Aidoku 细查

### 优势

- 主项目是活跃的 Swift/GPL-3.0 项目，2022 年开始，生态和维护时间长于其他原生候选。
- 来源使用 Rust/WASM 打包为 `.aix`，来源可以独立更新。
- Aidoku Community 当前确实存在：
  - `sources/zh.komiic`
  - `sources/zh.picacomic`
  - `sources/multi.ehentai`
- 因此三个重点来源不依赖 Android APK/JAR 也有可用起点。
- 当前主分支已经加入本地 EPUB 2/3 解析、分页/滚动文字阅读和字体设置。
- 官方 `nightly.yml` 已经用 macOS Runner、`CODE_SIGNING_ALLOWED=NO` 打包 IPA，适合改造成个人仓库的云构建。

### 风险

- EPUB 实现会把 XHTML 转成文字和图片段，不是完整浏览器或 Readium 级排版。复杂 EPUB、竖排、Ruby、脚注、表格和固定版式必须用样书验收。
- `LocalFileManager` 实际明确允许的归档扩展是 `cbz`、`zip`、`epub`。虽然 Info.plist 注册了 CBR 类型，不能据此认定 CBR 已可靠可读。
- 没有发现通用“网页浏览 → 文件下载 → 本地书库导入”路径。
- 不能直接复用现有 JAR。Picacomic/E-Hentai 的自定义功能需要移植到 Aidoku 社区源或项目内维护的 `.aix` 源。
- 当前来源 API 没有现成的“带状态的漫画详情远端操作”抽象。Aidoku App 已能向来源发送动作通知，因此计划在宿主与 `aidoku-rs` 之间增加通用的漫画操作接口，让 Picacomic 收藏/取消收藏成为详情页按钮并返回真实状态，不继续采用特殊章节方案。

### 许可证

Aidoku 为 GPL-3.0。个人修改没有问题；如果把修改后的 IPA交付给他人，应同时确保接收者能够取得对应源码。开发期可以使用私人仓库，但正式分享给其他人时不能只发二进制。

## 4. Yuedu 细查

### 优势

- 真正的 SwiftUI/CoreText 原生阅读器，定位最接近“Apple Books 风格的漫画 + 电子书阅读器”。
- 使用 Readium 处理 EPUB，正文由 CoreText 分页或滚动渲染，电子书能力明显强于 Aidoku 的 Minimal EPUB。
- 已提供 WebDAV、OPDS 和本地书库入口；内置浏览器还能从当前网页提取正文或章节列表并导入为网页书籍。
- Legado 书源支持文字、听书、漫画类型，并有规则调试器、Cookie、Cloudflare 登录页和一部分 `java.*` 兼容层。
- MPL-2.0 比 GPL 更宽松，但重新分发 fork 时仍需遵守源文件公开要求，并使用不同名称、图标和品牌。

### 风险

- iOS 18+ 是硬门槛。
- 项目很新，漫画书源测试文件甚至引用开发者本机的“35个漫画源.json”，说明漫画生态仍处于快速完善期。
- 官方文档明确说明 Legado 兼容层缺少 RSA、gzip、文件 API 等能力，JavaScript、正则、JSONPath 也有差异。复杂 Picacomic/E-Hentai 规则不能假定直接可用。
- 内置浏览器当前重点是网页正文/章节抽取，并不是完整的任意文件下载管理器；仍要补上文件类型识别、断点/失败处理和导入流水线。

## 5. Mangayomi 细查

### 优势

- 主项目覆盖漫画、小说、动画和视频，能处理本地 EPUB 与 CBZ/ZIP，书架、下载和可配置阅读器都已有基础。
- 支持自有 Dart/JavaScript 来源，并能读取 Mihon 扩展仓库索引。
- `m_extension_server` 当前实现说明：
  - Android 使用进程内 Dalvik 桥；
  - iOS 真机使用无 JIT 的 OpenJDK Zero 解释器；
  - iOS App 内启动本地扩展服务，导入 M-Extension-Server JAR 后调用 Mihon 扩展。
- 这是当前候选中唯一实际提供 iOS APK/JAR 路线的开源实现，不能再简单判断“iOS 一定不能运行 JAR”。

### 风险

- 这不是 iOS 原生 UI，而是 Flutter 跨平台界面。可以重做得更接近 iOS，但不能称为 UIKit/SwiftUI 原生。
- OpenJDK Zero 是解释执行，性能和内存占用需在用户真机上测；服务器进入后台会暂停。
- 该路径刚加入不久，三个现有自定义 JAR 是否兼容必须逐个验证，不能用“能启动服务器”代替来源验收。
- 最关键的合规问题：`m_extension_server` 仓库虽然公开，但它的 `LICENSE` 文件内容仍为 `TODO: Add your license here.`。在获得明确授权或上游补充许可证前，不适合作为可公开再分发的最终基础。

## 6. 其他候选为何不优先

- **Suwatte**：原生漫画、本地 CBR/CBZ、OPDS 都不错，但 EPUB/小说仍列为计划功能，不能满足当前电子书要求。
- **Tachimanga**：功能是重要参考，但公开 GitHub 仓库基本只有发布说明，没有可二开的完整 App 源码，也没有清晰开源许可证，不能作为 P0 底座。
- **Paperback**：公开 `app` 仓库用于 Release、Issue 和需求，不是完整 App 源码，不能作为 P0 底座。
- **Nyora**：基于 Aidoku 并尝试 AOT/JVM 来源桥，但项目非常新、生态小且架构复杂，可作技术参考，不宜先 fork。
- **KOReader iOS**：格式和电子书能力强，但 UI 不是原生 iOS，且缺少在线漫画来源生态。
- **Readium Swift Toolkit**：电子书能力强、许可证清晰，但它是底层工具包而不是完整 App。适合作为 Aidoku EPUB 不够用时的替换组件，不适合从零拼出第一版。

## 7. 最终选型与回退条件

### 已选路线：Aidoku

使用 Aidoku App + 项目内维护的三份 `.aix` 来源。App 与来源采用独立构建触发和产物；来源更新不要求重新打包 IPA。

### 迁移要求

- Picacomic：迁移屏蔽、入口映射、高级搜索、网络收藏列表、收藏/取消收藏、详情字段和作者快捷搜索。
- E-Hentai：迁移全局标签屏蔽，并继续研究排除项数量限制。
- Komiic：先沿用社区来源，完成稳定性和下载验收后再决定是否定制。

### 回退条件

- 如果 Aidoku 的普通 EPUB 样书、字体设置和阅读进度无法达到可用标准，优先在 Aidoku 中接入 Readium；不立即更换整个宿主。
- 只有 Readium 集成代价明显超过重做三个来源时，才重新评估 Yuedu。
- 只有未来重新提出“大量现成 APK/JAR 必须直接安装”，才恢复 Mangayomi 真机桥验证。

## 8. 主要资料来源

- [Aidoku 主项目](https://github.com/Aidoku/Aidoku)
- [Aidoku Community Sources](https://github.com/Aidoku-Community/sources)
- [Yuedu Reader](https://github.com/CHANG-JUI-LIN/Yuedu-reader)
- [Yuedu 架构说明](https://github.com/CHANG-JUI-LIN/Yuedu-reader/blob/main/Technotes/Architecture.md)
- [Yuedu 与 Legado 的差异](https://github.com/CHANG-JUI-LIN/Yuedu-reader/blob/main/docs/book-source/legado-differences.zh-Hans.md)
- [Mangayomi](https://github.com/kodjodevf/mangayomi)
- [Mangayomi iOS Java 扩展桥](https://github.com/kodjodevf/m_extension_server)
- [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server)
- [Suwatte](https://github.com/Suwatte/Suwatte)
- [Readium Swift Toolkit](https://github.com/readium/swift-toolkit)

本文件基于上述项目在 2026-08-21 的公开主分支资料；上游功能和许可证状态以后仍需重新核对。
