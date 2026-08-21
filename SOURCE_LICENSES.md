# 源码与许可证记录

更新时间：2026-08-21

本文件记录计划使用或参考的上游代码。它不是法律意见；实施时仍需随固定上游提交保存完整许可证和 NOTICE。

## 主 App

- 项目：[Aidoku/Aidoku](https://github.com/Aidoku/Aidoku)
- 许可证：GPL-3.0
- 首个固定基线：`45fe8231a8da58f70f5f2e152a039fcb49eab4cb`（2026-08-21）
- 使用方式：作为 V0/V1 App 底座，修改名称、Bundle ID、品牌、自签配置、来源操作、浏览器和导入能力。
- 要求：分发修改版 IPA 时，应确保接收者能够取得对应版本源码；保留 GPL 和上游版权说明。

## Aidoku 来源

- 项目：[Aidoku-Community/sources](https://github.com/Aidoku-Community/sources)
- 许可证：Apache-2.0
- 计划使用：`zh.komiic`、`zh.picacomic`、`multi.ehentai`
- 要求：复制许可证和适用 NOTICE，保留归属，修改文件明确标记；每份来源记录固定上游提交。

## 旧 Picacomic JAR 的迁移参考

- 上游：[keiyoushi/extensions-source](https://github.com/keiyoushi/extensions-source)
- 许可证：Apache-2.0
- 本项目已有参考：私人仓库 `Tachimanga_Custom_Extensions` 中的 Picacomic 1.4.14 补丁、构建后源码和功能说明。
- 使用方式：用于核对屏蔽、入口映射、高级搜索、网络收藏、详情信息和作者搜索的行为；新实现写入 Rust/WASM 来源或 Aidoku 宿主，不复制 Android/Tachiyomi UI 依赖。

## 旧 E-Hentai JAR 的迁移参考

- 上游：[yuzono/cursed-manga-extensions](https://github.com/yuzono/cursed-manga-extensions)
- 许可证：Apache-2.0
- 本项目已有参考：私人仓库 `Tachimanga_Custom_Extensions` 中的 E-Hentai 1.4.1029 补丁、构建后源码和功能说明。
- 使用方式：迁移全局标签屏蔽规则、设置语义和默认值；保留上游归属与修改说明。

## 可选电子书组件

- 项目：[Readium Swift Toolkit](https://github.com/readium/swift-toolkit)
- 许可证：BSD-3-Clause
- 使用条件：只有 Aidoku 当前 EPUB 阅读经用户样书验收不足时才引入。

## 只作参考、不直接复制

- [Yuedu Reader](https://github.com/CHANG-JUI-LIN/Yuedu-reader)：MPL-2.0；参考 EPUB、CoreText、WebDAV、OPDS 和浏览器交互设计。需要复制代码时必须先单独核对 MPL 文件级要求和品牌规则。
- [Mangayomi](https://github.com/kodjodevf/mangayomi)：Apache-2.0 主项目；只保留其 iOS JAR 路线作为技术资料。当前 `m_extension_server` 许可证不明确，不纳入本项目依赖。

## 实施清单

- [x] 根目录保留 Aidoku GPL-3.0 许可证。
- [ ] `CustomSources/` 保留 Apache-2.0 许可证和来源归属。
- [ ] 建立 `THIRD_PARTY_NOTICES.md`。
- [ ] 每份来源记录上游仓库、固定提交和本项目修改。
- [ ] 不从旧私人仓库直接复制没有来源记录的二进制或代码片段。
