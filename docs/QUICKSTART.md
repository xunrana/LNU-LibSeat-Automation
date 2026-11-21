# 快速上手指南

这篇教程面向直接下载安装包的同学。v6 已经彻底去掉了浏览器和驱动依赖，不用装 Python，也不用折腾 Edge / Chrome 版本。

[← 返回首页](../README.md) · [Android 安装与防杀后台](ANDROID_INSTALL_GUIDE.md) · [iOS 免费安装](IOS_INSTALL_GUIDE.md) · [桌面端 config.py 说明](CONFIGURATION.md)

---

## 先选一个适合你的版本

所有安装包都在 **[GitHub Releases](https://github.com/XUNRANA/LNU-LibSeat-Automation/releases/latest)**：

| 平台 | 推荐 | 文件名 | 大小 | 适用情况 |
| :--- | :---: | :--- | :---: | :--- |
| **Android** | **主推** | `LNU-LibSeat-Android-arm64.apk` | 165.9 MB | 有安卓机、不想开电脑、想随时查空座和收签到提醒 |
| **Windows** | **主推** | `LNU-LibSeat-v6.0.0-Windows-x86_64.zip` | 204.6 MB | 习惯宿舍电脑挂机，或者期末求稳不想折腾手机保活 |
| **iPhone / iPad** | 支持 | `LNU-LibSeat-iOS-arm64-unsigned.ipa` | 146.7 MB | 只用苹果手机，可用免费 Apple ID 自签 |
| **macOS** | 支持 | `LNU-LibSeat-v6.0.0-macOS-arm64.zip` | 193.6 MB | Apple Silicon Mac 电脑挂机 |

---

## 一、Android 手机版（主推）

详细分品牌保活图解见 [docs/ANDROID_INSTALL_GUIDE.md](ANDROID_INSTALL_GUIDE.md)，核心就四步：

1. **下载安装**：去 Releases 下 `LNU-LibSeat-Android-arm64.apk` 直接安装。如果通过微信传到手机文件名后面多了 `.1`，把 `.1` 删掉再装；遇国产系统提示“未知来源 / 未备案”点继续安装就行。
2. **填账号和目标**：打开 App，到 **我的 → 校园卡账号** 填学号密码（初始密码一般为 `000000`）；回 **晨约** 点 **速改** 选校区、自习室和时段，首选座号可以留空。
3. **一次性给后台权限**（准备睡前设 06:30 必做）：
   - 进 **我的 → 晨约守夜与后台保活**，把 4 项体检开关全部点绿（电池优化白名单、精确闹钟、系统通知、Android 14+ 锁屏全屏唤醒）；
   - 点底部的专属入口跳到系统设置，按手机品牌打开 **允许后台高耗电、自启动、后台弹出界面、锁屏显示**，并在最近任务里把 App 加锁。
4. **先测 2 分钟再过夜**：定时模式设成“当前时间 + 2 分钟”点开始，直接锁屏放桌上，确认能准点唤醒再改回 `06:30`。重要日子（如期末周）也可以点首页 **夜守** 切到纯黑时钟插电不锁屏。

---

## 二、Windows 电脑版（主推）

1. **下载解压**：去 Releases 下 `LNU-LibSeat-v6.0.0-Windows-x86_64.zip`，解压到任意文件夹。
2. **直接双击运行**：打开目录双击 `LNU-LibSeat.exe`（v5 老用户把旧 `config.py` 直接复制过来就行）。
3. **填表点开始**：
   - **目标设置**：选校区和自习室；首选座位最多填 10 个，**全部留空也没问题**，会自动抢实时空座。
   - **账号设置**：填学号、密码和时段；想全天自习可以勾“启用更多账号”配副号（比如 `09:00-15:00` + `15:00-21:00`）。
   - **通知邮箱 & 手机推送**：填邮箱即可收战报（内置发件箱免配置）；“手机推送”框可直接贴 Bark / PushPlus / Server酱 / 企微 / 飞书 / 钉钉 Webhook。
   - **立即 / 定时**：马上捡漏选立即，次日 6:30 选定时（默认 `06:30`）。
4. **看右侧日志**：点“开始抢座”后不会弹浏览器窗口，状态会实时打在右侧黑色日志框里。运行期间自动阻止电脑休眠，结束后自动还原。

<p align="center">
  <img src="screenshots/01_folder_structure.png" width="46%" alt="解压目录结构">
  &nbsp;
  <img src="screenshots/02_gui_main.png" width="46%" alt="桌面端主界面">
</p>

### 附：Windows 每天 06:25 自动唤醒运行（可选）

如果不想电脑整晚亮着，可以用系统自带的任务计划程序定时唤醒：
1. 先把桌面版配置成定时 `06:30` 保存好 `config.py`；
2. 按 `Win + R` 输入 `taskschd.msc` → 右侧点「创建基本任务」；
3. 触发器选每天 **`06:25`**，操作选启动 `LNU-LibSeat.exe`；
4. 在任务属性「条件」里勾选 **「唤醒计算机以运行此任务」**。

---

## 三、iPhone 与 Mac 用户

- **iPhone / iPad**：去 Releases 下 `LNU-LibSeat-iOS-arm64-unsigned.ipa`，用 Sideloadly、爱思助手、SideStore 或巨魔免费安装。首次打开前需在 iPhone 设置里开启「开发者模式」并信任证书。详细步骤见 [docs/IOS_INSTALL_GUIDE.md](IOS_INSTALL_GUIDE.md)。
- **macOS (Apple Silicon)**：去 Releases 下 `LNU-LibSeat-v6.0.0-macOS-arm64.zip`，解压后首次**右键**点击 `首次运行请先双击我.command` → 打开 → 再点打开（解除未公证拦截），之后直接双击 `LNU-LibSeat.app` 即可。挂机期间自动通过系统 `caffeinate` 防休眠，双账号直接并行。

---

## 四、常见问题

<details>
<summary><b>时段怎么填？双账号怎么配合？</b></summary>

- 开始时间填整点（如 `09:00`）或“现在”；结束时间**必须是整点**（如 `15:00`、`21:00`），单次最长 6 小时（学校规定）。
- 两个账号时段不重叠时（如主号 `09:00-15:00` + 副号 `15:00-21:00`），程序会放行双号抢同一个座位，全天不用换座；时段重叠则自动错开，避免互相抢。
</details>

<details>
<summary><b>现在白天错峰也能自动识别点选验证码吗？</b></summary>

可以。v5 时代限制的 `06:30–06:35` 时间窗口在 v6 已经取消，现在按图书馆接口返回的字数（1 字或 3 字）全天自动识别，不需要改代码。
</details>

<details>
<summary><b>抢失败了怎么排查？</b></summary>

- **电脑端**打开 `logs/sessions/<时间>_<学号>/`，里面有 `session.log`、`抢座顺序.txt`、已脱敏的 `http_trace.jsonl` 和验证码识别叠加图（`*_captcha_*.png`）。
- **手机端**进 **我的 → 运行记录与识图回放** 可直接看图复盘并导出日志。
</details>

<details>
<summary><b>想从源码运行或自己打包怎么办？</b></summary>

```powershell
git clone https://github.com/XUNRANA/LNU-LibSeat-Automation
cd LNU-LibSeat-Automation
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
python gui_qt.py    # 桌面界面（或 python main.py 跑命令行）
```

打包命令：`python build_android.py`（Android）、`python build.py`（Windows）、`python3 build_ios.py`（iOS，需 Mac）、`python3 build_mac.py`（macOS，需 Mac）。
</details>
