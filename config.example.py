# ===================================================================
# LNU-LibSeat-Automation v6 配置模板（纯 API 引擎，无需浏览器）
# -------------------------------------------------------------------
# 用法：复制本文件为 config.py 后填写；或直接打开 GUI，由它自动生成 config.py。
# ⚠️ 安全：config.py 含学号 / 密码等敏感信息，已被 .gitignore 忽略，请勿提交到 git。
# ===================================================================

USERS = {
    # "你的学号": {
    #     "password": "你的密码",
    #     "time": {"start": "08:00", "end": "12:00"},
    # },
    "": {
        "password": "",
        "time": {"start": "", "end": ""},
    },
}

TARGET_CAMPUS = "崇山校区图书馆"     # 主校区，可选值见 ui_qt/services/config_io.py: ROOM_DATA
TARGET_ROOM = "三楼智慧研修空间"     # 主自习室名称
# 可选：备选自习室列表（主自习室无可用空座时按序切换），格式: [("崇山校区图书馆", "四楼南自习室")]
FALLBACK_ROOMS = []
PREFER_SEATS = []                    # 首选座位号，如 ["1", "2", "10"]；留空 = 实时扫描全部空座

WAIT_FOR_0630 = False                # True = 定时模式（每天定点抢座），False = 立即模式
MAX_ACCOUNTS = 2                     # 最多并发账号数

# 纯 API 引擎高级参数（通常保持默认即可）
API_BASE_URL = "http://libseat.lnu.edu.cn"
API_FIRE_OFFSET_MS = 200             # 定时模式下在准点后顺延的毫秒数（避免踩服务端切状态瞬间）

RECEIVER_EMAIL = ""                  # 抢座成功通知的收件邮箱
WEBHOOK_URL = ""                     # 可选：手机端即时推送（支持 Bark / PushPlus / Server酱 / 企微 / 飞书 / 钉钉 / 通用 JSON）
SMTP_USER = ""                       # 可选：自定义发件邮箱（留空使用内置发件箱）
SMTP_PASS = ""                       # 可选：自定义发件邮箱的 SMTP 授权码

LOG_LEVEL = "INFO"                   # 日志级别：DEBUG / INFO / WARNING / ERROR
LOG_DIR = "logs"                     # 日志输出目录

# 仅在定时模式（WAIT_FOR_0630 = True）下生效：每天的准点提交时刻
SCHEDULE_HOUR = 6
SCHEDULE_MINUTE = 30
