# 安全自查报告（2.0.6）

范围：`patch/ztncui/`（控制器界面、认证、双因素、通行密钥）、`patch/http_server.js`（planet 下载服务）、
`patch/entrypoint.sh`（容器启动）、`patch/stats-collector.js`（新增的运行时统计采集器）、`scripts/*.sh`。

方法：逐文件人工审阅（认证/授权、输入处理、文件与路径、会话、密钥与日志）、依赖审计
（`npm audit --omit=dev`）、以及对关键路径的本地运行验证（`tests/*.test.js`）。

## 结论

没有发现可远程利用的严重漏洞（无未认证的命令执行、任意文件读写、SQL/模板注入或认证绕过）。
本轮修复了 4 个问题：两个影响可用性并会误导用户（保存失败无提示、保存按钮失效），
一个真实的拒绝服务风险（登录限流可按 IP 打满），一个日志注入。

| # | 级别 | 问题 | 状态 |
|---|------|------|------|
| 1 | 高（可用性） | 12 个表单页把控制器传入的 `error` 当成 `errors` 渲染，**任何保存失败都不显示任何提示**，用户只会看到页面刷新。 | 2.0.6 已修复 |
| 2 | 高（功能） | IPv4/IPv6 分配模式页的「保存」按钮位于 `<form>` 之外，点击不提交；IPv6 页又没有自动提交，等于**完全无法保存**。 | 2.0.6 已修复 |
| 3 | 中（DoS） | 登录失败限流按来源 IP 记账。容器默认跑在反向代理后面且未设 `TRUST_PROXY` 时，`req.ip` 全是 `127.0.0.1`，攻击者失败 10 次即可**锁死所有账号** 15 分钟。 | 2.0.6 已修复 |
| 4 | 低 | 来源校验失败时把 `Origin`/`Referer` 原样拼进日志（攻击者可控），可伪造日志行或注入控制字符。 | 2.0.6 已修复 |
| 5 | 提示 | 裸 IP 无法使用通行密钥（WebAuthn 要求域名）+ 自签证书，页面会提示但按钮仍可点，由浏览器报错。 | 已知限制，文档说明 |
| 6 | 提示 | ztncui 没有角色模型：**任何已登录账号都是控制器管理员**；新建账号在首次设置密码前（`pass_set=false`），其初始密码可由任一已登录账号设置（上游设计，用于管理员代设初始密码）。 | 已知限制，文档说明 |
| 7 | 提示 | 会话保存在内存里，容器重启后需要重新登录；单实例面板，不做多租户。 | 设计如此 |

## 修复细节

1. **错误提示**：`patch/ztncui/views/*.pug` 统一改为 `if error` / `p= error`，与控制器
   `res.render(..., { error: msg(...) })` 对齐。
2. **保存按钮**：`v4AssignMode.pug`、`v6AssignMode.pug` 把 `.form-actions` 移入 `form.form-stack`。
3. **登录限流**：`patch/ztncui/routes-index.js` 改为「来源地址 + 账号」分桶（密码 / TOTP / 通行密钥各自独立），
   单个账号 15 分钟 10 次失败即停；同一来源地址总计 50 次失败也会被拦，避免攻击者用随机用户名刷爆内存或绕过限制。
   账号名比较前统一小写并截断到 64 字符，桶数量上限 5000。
4. **日志注入**：`app.js` 增加 `logSafe()`，去掉控制字符并截断 200 字节后再写 `console.warn`。

## 复核通过的防护（本轮未改动，确认有效）

- **planet 下载服务**：文件名白名单（`planet`、`*.moon`）、`realpath` 后必须仍等于 `DIST_DIR/name`（防符号链接逃逸）、
  `sha256` + `timingSafeEqual` 常量时间比较、默认只接受 `Authorization: Bearer` / `X-Api-Key`、
  `?key=` 需显式开启 `ALLOW_QUERY_KEY=1`、TLS 1.2+、20 次/15 分钟失败上限、`nosniff` + `no-store`。
- **认证**：Argon2id 哈希；未知用户也跑一次假哈希（时间对齐）；用户名白名单
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` 且保留 `__proto__`/`prototype`/`constructor`（阻断原型污染）；
  登录成功 `session.regenerate()`（防固定会话）；cookie `HttpOnly` + `SameSite=Lax` + TLS 下 `Secure`。
- **CSRF**：所有状态变更都是 POST；同源校验（`origin.js`）比对规范化主机名，`Origin` 缺失时回退 `Referer`，
  并配合 `SameSite=Lax`；跨站 POST 不携带会话。
- **开放重定向**：登录后的 `redirect` 只接受以单个 `/` 开头的本地路径。
- **TOTP**：HMAC-SHA1 + 动态截断，窗口 ±1，记录 `lastStep` 防重放，备用码存 SHA-256 且一次性。
- **通行密钥**：校验 `type`、`clientData` 的 `type`/`challenge`/`origin`/`crossOrigin`、`rpIdHash`、`UP`（及注册时的 `AT`）、
  签名（ES256/RS256/RS384/RS512/EdDSA）、签名计数器递增；挑战存会话、5 分钟过期、一次性。
- **渲染**：Pug 默认 HTML 转义；CSP `default-src 'self'`、无内联脚本/样式，交互全部走 `/js/*.js`；
  `helmet` 提供 HSTS（TLS 时）、`X-Frame-Options`/`frame-ancestors 'none'`、`no-referrer`。
- **其他**：`x-powered-by` 关闭；错误处理器在 `NODE_ENV=production` 下不返回堆栈；请求体上限 256 KB；
  未使用 `eval`/`new Function`；唯一的 `child_process` 调用是统计采集器里的 `execFile`，参数固定且不来自请求；
  运行时统计文件只含计数与用量，不含密钥。

## 依赖

`patch/ztncui` 的运行时依赖为 express 5.3.0、pug 3.0.3、helmet 8.1.0、express-session 1.19.0、
body-parser 2.4.0、cookie-parser 1.4.7、morgan 1.12.1、hash-wasm 4.12.0、node-persist 2.1.0；
`npm audit --omit=dev` 报告 **0 个漏洞**。ZeroTier 内核固定在 1.16.2（commit 校验），ztncui 固定到 commit。

## 报告问题

发现漏洞请勿公开提交 issue，按 [SECURITY.md](../SECURITY.md) 里的方式私下联系。
