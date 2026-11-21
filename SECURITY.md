# 安全说明

## 报告漏洞

如发现安全问题，请通过 [GitHub Issues](https://github.com/XUNRANA/LNU-LibSeat-Automation/issues) 反馈。
若涉及敏感信息（如可泄露他人凭据的问题），请在标题注明「安全」并**避免在正文公开复现细节**，等作者回应后再私下提供。

## 使用者须知（敏感数据与隐私保护）

- **纯本地直连，无中转服务器**：无论是 Windows / macOS 桌面端，还是 Android / iOS 手机独立版，所有请求均从你的设备直连 `libseat.lnu.edu.cn`，不存在任何第三方中转服务器。
- **桌面端（`config.py`）**：`config.py` 含明文学号 / 密码，已被 `.gitignore` 忽略，**绝不要提交到 git、不要随截图或日志外发**（模板见 `config.example.py`）。
- **手机端（Android & iOS）**：校园卡学号与密码加密存储在系统级安全凭据库（Android Keystore / iOS Keychain）中，切勿将设备截图中的个人学号原图直接公开发布。
- **排障日志与脱敏机制**：v6 每次会话生成的 `http_trace.jsonl` 已内置递归脱敏（自动抹除密码、AES 密文头、48 位 Token 与 Cookie），但在公开发布 `session.log` 或界面截图前，仍建议自行复核是否包含学号或邮箱地址。
- **邮件与 Webhook 凭据**：桌面端与手机端默认内置公共 126 发件箱以便零配置使用；若从源码运行或有更高隐私要求，可在 `config.py`（`SMTP_USER` / `SMTP_PASS`）中填入**你自己的**发件邮箱授权码，Webhook URL 在日志中会自动隐藏路径密钥与 query token。

## 已知限制

- 源码中保留的公共发件邮箱 SMTP 凭据属免配置便利设计；自行构建或对邮件通道有独立要求的用户应使用自有凭据覆盖。
- 本项目仅供技术学习与交流，请遵守辽宁大学图书馆的预约规则；所有使用后果由使用者自行承担（详见 [README 免责声明](README.md#-免责声明)）。

## 支持范围

仅对最新发布版本（见 [Releases](https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest) 与 [CHANGELOG](CHANGELOG.md)）提供安全修复。
