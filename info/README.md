# info/ — 自习室座位索引

每个 `.txt` 对应一间自习室，文件名即自习室名称，内容是该室的座位号清单。
双校区（崇山 + 蒲河）共 21 间，覆盖书库、走廊、自习室与智慧空间等。

- 桌面端打包时随产物一起分发，置于 app 同级，便于查看 / 校对座位号；
- 移动端构建脚本（`scripts/prepare_mobile_assets.py`）会自动将其打包为 `mobile/assets/rooms/room_catalog.json`，供 Android & iOS 离线展示座号清单；
- `智慧空间.txt`、`三楼智慧研修空间.txt` 为 v5 新增；
- v6 纯 API 模式下，首选座位留空时程序会直接拉取 `/layoutByDate` 实时空座列表（不再盲扫全房）。

> 校区与自习室的下拉数据见 [`ui_qt/services/config_io.py`](../ui_qt/services/config_io.py)。
> 文件名含中文，git 默认会转义显示，可用 `git -c core.quotepath=false ls-files info` 查看原名。
