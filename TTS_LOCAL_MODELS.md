# 本地 TTS 模型导入说明

Aidoku 的语音读书支持两种可切换引擎：

- 微软 Azure 在线语音：不占用模型空间，需要网络、区域和密钥。
- sherpa-onnx 本地语音：模型首次导入后可离线使用，模型文件不打进 IPA。

## 推荐模型

按当前 iPhone 使用场景，建议依次尝试：

1. `matcha-icefall-zh-baker`：中文女声，速度和自然度平衡较好；模型约 73 MB，另需约 51 MB vocoder。
2. `vits-icefall-zh-aishell3`：中文、174 个说话人，模型约 30 MB，速度最快、占用最小。
3. `vits-melo-tts-zh_en`：中英混读更好，单说话人，模型约 163 MB，但合成速度较慢。
4. `kokoro-multi-lang-v1_1`：中英双语、103 个说话人，自然度优先；模型约 311 MB，速度和内存成本最高。

每个模型的许可证不同，下载和分发前需要查看模型目录中的 `LICENSE`。

## 导入方法

官方模型通常以 `.tar.bz2` 发布。先解压，再将完整模型文件夹压缩为 ZIP，或直接通过 iOS“文件”选择模型文件夹。不要只选择单个 `.onnx` 文件。

在阅读器中点击耳机按钮：

1. 将 TTS 切换为“本地离线模型”。
2. 点击“导入本地模型包”。
3. 选择 ZIP 或完整模型目录。
4. 导入完成后选择模型；多说话人模型还可以切换说话人编号。

程序会自动识别常见 VITS、Matcha、Kokoro 官方目录。模型保存在应用的 Application Support 目录；覆盖安装 IPA 不会删除模型，卸载应用会删除。

## 自定义模型清单

自动识别失败时，可在模型根目录放置 `aidoku-tts-model.json`。路径必须相对于模型根目录，不能包含 `..` 或绝对路径。

```json
{
  "schemaVersion": 1,
  "id": "imported-model",
  "name": "My Chinese Voice",
  "family": "vits",
  "language": "zh-CN",
  "model": "model.onnx",
  "tokens": "tokens.txt",
  "lexicons": ["lexicon.txt"],
  "dictionaryDirectory": "dict",
  "ruleFsts": ["date.fst", "phone.fst", "number.fst"],
  "speakerCount": 1
}
```

Matcha 使用 `acousticModel` 与 `vocoder`；Kokoro 使用 `model`、`voices` 与 `tokens`。模型 ID 在导入时会由应用重新生成，避免同名模型覆盖。
