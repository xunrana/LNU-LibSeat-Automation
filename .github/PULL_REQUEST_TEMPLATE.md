<!-- 感谢提交 PR！请填写以下内容，便于 review。 -->

## 改动说明

<!-- 这个 PR 做了什么、为什么 -->

## 改动类型

- [ ] 🐛 Bug 修复
- [ ] ✨ 新功能
- [ ] ♻️ 重构（行为不变）
- [ ] 📝 文档
- [ ] 🔧 构建 / CI

## 自测清单

- [ ] `pytest tests/ -q` 全绿（94 项 Python 离线单测）
- [ ] `ruff check .` 0 告警通过
- [ ] 若改动 `mobile/` 或跨语言协议/预处理逻辑，`cd mobile && flutter test`（23 项单测）与 `flutter analyze` 通过
- [ ] 若改动抢座核心流程（`core/libseat_client.py`、`logic/booker.py`、`logic/orchestrator.py`、`mobile/lib/core/`），已做（或计划做）非整点真机端到端验证
- [ ] 未提交 `config.py`、真实学号/密码/Token 等敏感数据
- [ ] 提交为 forward commit（未 rebase / force-push 改写历史）

## 备注

<!-- 截图、相关 Issue 链接、需要 reviewer 注意的点 -->
