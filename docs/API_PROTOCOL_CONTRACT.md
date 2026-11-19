# LibSeat 纯 API 协议契约（Phase 0 实测核验）

> 本契约由真实浏览器 HAR 抓包与公开前端包分析整理，**已移除所有个人学号、密码、Token 与 Cookie**，作为 `core/protocol.py`、`core/api_crypto.py`、`core/libseat_client.py` 的唯一权威参考。

---

## 1. 基础配置与动态引导

页面入口加载的 `baseUrl.js` 暴露全局配置对象 `Global`：

- `BASEURL`: `"http://libseat.lnu.edu.cn"`
- `CODE`: `true`（控制是否附加 HMAC 签名头）
- `NUMCODE`: AES-128-CBC 加密后的 HMAC 密钥密文（客户端启动时可尝试动态拉取 `/libseat/static/baseUrl.js` 或 `/libseat/baseUrl.js`，失败回退内置默认值）

---

## 2. 全局请求头与签名规则

所有 API 请求均携带：

| Header | 规则 |
|---|---|
| `loginType` | 固定 `"PC"` |
| `Authorization` | 登录后携带 48 位登录 `token`（登录前为空） |
| `Referer` | `http://libseat.lnu.edu.cn/libseat/` |
| `X-request-id` | 36 位小写 UUIDv4 |
| `X-request-date` | 13 位毫秒级时间戳字符串 |
| `X-hmac-request-key` | 64 位小写十六进制 `HMAC-SHA256(key=AES_decrypt(NUMCODE), msg="seat::{id}::{date}::{METHOD_UPPER}")` |

- **AES 参数**：`AES-128-CBC` + `PKCS7` 填充，`key = "server_date_time"`，`iv = "client_date_time"`，输出标准 Base64。
- **Token 过期判定**：响应 JSON `code == "12"` 或 HTTP 状态 `12`（需重新登录）。
- **时钟校准**：所有响应头均携带 RFC 7231 `Date` 头，供 `core/clock_sync.py` 计算服务端时间偏移。

---

## 3. 核心端点契约

### 3.1 登录图形验证码
- **`GET /auth/createCaptcha`**
- 响应：`{"captchaId": "<str>", "captchaImage": "data:image/png;base64,..."}`（160×70 PNG，由 `core/captcha.py` `ddddocr` 识别 4 位文本）

### 3.2 账号登录
- **`GET /rest/auth?answer=<4位码>&captchaId=<id>`**
- 额外请求头：
  - `username`: `Base64(AES_CBC_PKCS7(学号)) + "_encrypt"`
  - `password`: `Base64(AES_CBC_PKCS7(密码)) + "_encrypt"`
- 响应：
  - 成功：`{"status": "success", "data": {"token": "<48位token>"}, "code": "0", "message": ""}`
  - 失败：`{"status": "fail", "message": "<原因>", ...}`

### 3.3 用户信息与当前预约
- **`GET /rest/v2/user?token=<48位>`**
  - 成功：`data.id`（整型 `userId`）、`data.username`、`data.status`（`"NORMAL"` 等）、`data.violationCount`、`data.reservationStatus`
- **`GET /rest/v2/user/reservations?token=<48位>`**
  - 无有效预约：`data: null`
  - 有有效预约：`data: [{"id": <int>, "receipt": "<str>", "onDate": "YYYY-MM-DD", "seatId": <int>, "status": "RESERVE", "location": "<str>", "begin": "HH:MM", "end": "HH:MM", "message": "<签到提示>"}]`

### 3.4 校区、自习室空座统计与座位布局
- **`GET /rest/v2/free/filters?token=<48位>`**
  - `data.buildings`: `[[1, "蒲河校区图书馆", ...], [2, "崇山校区图书馆", ...]]`
  - `data.rooms`: `[[roomId, roomName, buildingId, floorNum, ...], ...]`
  - `data.dates`: `["YYYY-MM-DD", ...]`
- **`GET /rest/v2/room/stats2/{buildingId}/{date}?buildingId={buildingId}&date={date}&token=<48位>`**
  - `data`: `[{"roomId": 30, "room": "三楼智慧研修空间", "floor": 3, "maxHour": 6, "totalSeats": 244, "free": 8, "reserved": ..., "inUse": ..., "away": ..., "disableSeat": ...}, ...]`
- **`GET /rest/v2/room/layoutByDate/{roomId}/{date}?id={roomId}&date={date}&token=<48位>`**
  - `data.layout`: 字典，仅处理 `item.type == "seat"` 节点：
    - `id`: 整型 `seat_id`
    - `name`: 字符串座号（如 `"1"`、`"194"`、`"A-06-1"`）
    - `enabled`: 布尔值
    - `status`:
      - `enabled == true` 且 `status in ("FREE", "YESSELECT")` → **空闲可约 (`free`)**
      - `status in ("IN_USE", "BOOKED", "FULL", "AWAY")` → **占用 (`occupied`)**
      - `enabled == false` 或 `status == "NOSELECT"` → **不可用 (`unavailable`)**

### 3.5 单座可用时段（可选预检）
- **`GET /rest/v2/startTimesForSeat/{seatId}/{date}?seatId={seatId}&date={date}&token=<48位>`**
  - `data.startTimes`: `[{"id": "now", "value": "现在"}, {"id": "1020", "value": "17:00"}, ...]`
- **`GET /rest/v2/endTimesForSeat/{seatId}/{date}/{startId}?id={seatId}&date={date}&start={startId}&token=<48位>`**
  - `data.endTimes`: `[{"id": "1080", "value": "18:00"}, ...]`
- 时间编码：除 `"now"` 外，均以**自 00:00 起的分钟整数**表示（如 `09:00` → `"540"`，`17:00` → `"1020"`）；提交 `freeBook` 时 `"now"` 映射为 `"-1"`。

### 3.6 点选验证码（Click1 与 Click3 统一协议）
- **拉取题目**：**`POST /cap/captcha/{login_token_48}?username={account}`**（空 Body）
  - 响应：
    ```json
    {
      "image": "data:image/jpg;base64,... (330x160 JPEG)",
      "wordImage": "data:image/jpg;base64,... (70x36 JPEG)",
      "wordCheckCount": 1,
      "status": "OK",
      "token": "<32位十六进制一次性凭证>"
    }
    ```
  - `wordCheckCount` 明确指示点选字数（非高峰 `1` → Click1，06:30 高峰 `3` → Click3），坐标为原生 `330×160` 图像像素坐标（1:1，无需 CSS 缩放）。
- **校验坐标**：**`GET /cap/checkCaptcha?a={b64}&token={captcha_token_32}&userId={userId}&username={account}`**
  - `a`: `Base64(JSON.stringify([{"x": x1, "y": y1}, ...]))`（无多余空格）
  - 成功响应：`{"status": "OK"}`
  - 失败响应：`status != "OK"`（需刷新重新拉取）

### 3.7 一步下单与取消
- **下单**：**`POST /rest/v2/freeBook?token=<48位>`**（`Content-Type: multipart/form-data`）
  - 表单 7 字段：`startTime`（分钟数或 `"-1"`）、`endTime`（分钟数）、`seat`（`seat_id`）、`date`（`YYYY-MM-DD`）、`userId`、`username`、`authid`（**与 `/cap/captcha` 返回的 32 位 `token` 相同**）
  - 成功响应：`{"status": "success", "data": {"id": <int>, "receipt": "<str>", "onDate": "...", "begin": "HH:MM", "end": "HH:MM", "location": "...", "checkedIn": false}, "message": "", "code": "0"}`
  - 失败响应：`{"status": "fail", "message": "<中文业务原因>", "code": "..."}`
- **取消预约**：**`GET /rest/v2/cancel/{reservationId}?id={reservationId}&token=<48位>`**
  - 成功响应：`{"status": "success", "data": {"totalCancelled": 2, "allowedCancel": 3}, "code": "0"}`

---

## 4. 关键性能发现

原浏览器 Vue 前端存在两处纯客户端人为延时：
1. 验证码弹窗加载后 `setTimeout(..., 1500)` 隐藏确定按钮 **1.5 秒**；
2. 验证码通过后 `setTimeout(..., 2000)` 播放假加载动画 **2.0 秒**才发出 `/rest/v2/freeBook`。

纯 API 直连消除这两处 3.5 秒的人为等待及浏览器启动开销，实测单次网络链路（取码 → 校验 → 下单）往返合计仅 **~0.35 秒**。
