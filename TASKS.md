# iOS Unified Reader 任务清单

更新时间：2026-08-23

## 当前状态

- 状态：已进入 V0，Aidoku 上游历史和私有仓库骨架已建立。
- 本地目录：已建立。
- 独立 Git：已初始化，默认分支 `main`。
- GitHub 仓库：已创建，`1106912019pxk-ux/ios-unified-reader`（私有）。
- 上游源码：已导入完整历史，基线 `45fe8231a8da58f70f5f2e152a039fcb49eab4cb`。
- IPA：首个可安装基线已完成真机验证；当前包含已确认的 PICA 宿主网络与详情交互适配。该适配只编入 IPA，不构建或内置 PICA AIX。

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
- [x] 建立独立私有来源仓库 `1106912019pxk-ux/ios-unified-reader-sources`，保留 Aidoku Community Sources 完整历史。
- [x] 确认三个来源以独立 `.aix` 文件交付，由用户按需手动导入，不内置进 IPA。
- [ ] 真机对比 Pica 系统 DNS 与专用线路的首页、详情和阅读首图耗时；专用线路必须保持原域名 TLS 校验并与网页浏览隔离。

## 等待用户确认

- [ ] “在线播放”是在线阅读，还是视频/音频播放。
- [ ] 局域网主要协议：WebDAV、OPDS、HTTP、SMB、Komga 或 Kavita。

## 电子书稳定版之后的 TODO

- [x] 重新设计自动阅读；独立会话模式已通过真机验证。
  - 启动时从当前位置临时切换为连续文本/条漫滚动，停止后恢复原阅读模式和等价位置。
  - 运行时锁定手动翻页、拖动、章节切换和进度条；点击屏幕仅呼出速度/停止控件。
  - 速度范围为 0.5–8 倍；低速细调、高速按 0.5/1 倍递增，兼顾文字和漫画。
  - 文本 EPUB 的行内图片随内容自然滚过；本地 EPUB 纯图片 spine 会跳过并继续寻找后续文本。
  - 本轮重点验证：分页/滚动切换的位置恢复、纯图片 spine 跳过、跨 spine 连续性和控制条始终可唤出。
  - 约束：不得仅凭图片比例或缺失的 EPUB 排版元数据，自动判断整本书是漫画还是小说。
  - 后续方向：抽取漫画自动滚动的滚动引擎，但不把 EPUB 强制转换为漫画或 Markdown；由 Aidoku 阅读宿主统一保存进度、控制启停和在阅读器切换时保持会话。
  - 后续验收：当前位置恢复、正文内嵌图片、纯图片封面、跨 spine、暂停/关闭入口、横屏和 iPad。
- [~] 系统 TTS：已加入无需账号、无需网络的苹果中文系统语音保底选项，待本轮真机验证；不替代微软/本地模型。
- [x] 可切换 TTS 前台听书（已通过真机验证）：
  - 微软免费在线朗读：晓晓、晓伊、晓辰、晓涵、云希、云健、云扬、云野；无需账号或密钥。
  - 本地离线引擎：sherpa-onnx；可从“文件”导入、选择和删除 VITS、Matcha、Kokoro 模型 ZIP/目录，模型不写入 IPA。
  - 统一支持语速、播放/暂停/停止、从当前位置开始和正文进度跟随。
  - 连续页面统一断句，跨页未完语句不会按显示页硬切；同时预取后续 3 个语音单元以减少播放间隙。
  - EPUB 正文内嵌图片不朗读；纯图片页/封面自动跳过；按需读取下一段文字 spine，避免启动时解析整本书；阅读器跨章节后仍保留停止入口。
- [~] 后台听书：已改为 iOS 独占长音频媒体会话，补齐锁屏/控制中心播放状态、耳机播放/暂停/停止、耳机断开暂停及系统中断恢复；本次仅提交代码、不打包，待后续真机验证。

## 底座确定后

- [x] 确认仓库名、所有者、公开性、默认分支和初始推送范围。
- [x] 初始化独立 Git 并创建独立 GitHub 仓库。
- [x] 固定上游基线并保留许可证/第三方声明。
- [x] 建立独立来源仓库，导入并固定三份 Apache-2.0 Aidoku 来源。
- [x] 建立旧 JAR 功能到新来源/宿主的逐项迁移清单。
- [ ] 为 Picacomic 实现真正的详情页网络收藏按钮，不再使用特殊章节。
- [ ] 建立无签名 IPA 的 GitHub Actions 工作流。
- [ ] 生成第一个可自签安装的 V0 IPA。
- [ ] 完成三份重点来源与 EPUB/CBZ 的真机验收。

