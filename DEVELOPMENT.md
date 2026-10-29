# 维护文档(给以后的自己)

> 本文档面向**修改/优化脚本的人**,与面向使用者的 [README.md](README.md) 互补。
> 记录了脚本的设计决策、结构地图、常见修改的操作路径、已知限制与测试清单。
> 改脚本前建议先通读「设计决策」一节,避免破坏当初特意保留的行为。

---

## 1. 项目结构

```
NAT_Node/
├── install.sh       # 唯一的脚本,单文件自包含,~620 行 POSIX sh
├── README.md        # 面向使用者(安装方法/环境变量/FAQ)
├── DEVELOPMENT.md   # 本文档
├── LICENSE          # MIT
└── .gitattributes   # 强制 *.sh 为 LF(Windows 上开发,Alpine 上运行,必须)
```

依赖关系:脚本运行时**只依赖目标机器上的** `curl`/`openssl`/`ca-certificates`(启用端口跳跃时追加 `iptables`),全部由 `apk add` 自动安装。脚本自身零外部依赖(不用 bash、不用 jq、不用 python)。

## 2. 执行流程地图

```
main "$@"
 ├─ root 检查 / 架构识别(amd64|arm64,其余 die)
 ├─ 已安装(STATE_FILE + BIN_PATH 存在)? ──是──> menu() 管理菜单循环
 └─ 未安装:
     ├─ Alpine 检查(/etc/alpine-release)
     ├─ apply_config()
     │   ├─ ensure_deps()        apk 装基础依赖
     │   ├─ wizard()             三岔口:
     │   │   ├─ 设置了 HY2_PORT  -> wizard_batch()    免交互
     │   │   ├─ 有 /dev/tty      -> wizard_interactive() 问答向导
     │   │   └─ 都没有           -> die(提示下载后运行)
     │   ├─ prepare_dnat()       iptables 能力探测,不行则 DNAT=0 降级
     │   ├─ confirm_or_abort()   仅交互模式;取消返回 1
     │   ├─ rc-service stop      ★必须先停旧服务(见设计决策 #4)
     │   ├─ place_binary()       HY2_BIN 本地复制 或 多源下载
     │   ├─ gen_cert()           自签证书(已存在则复用)
     │   ├─ write_config()       config.yaml
     │   ├─ write_init()         /etc/init.d/hysteria(内嵌 heredoc)
     │   ├─ write_confd()        /etc/conf.d/hysteria(DNAT 参数/GOMEMLIMIT)
     │   ├─ save_state()         /etc/hysteria/.env(菜单复用的状态)
     │   ├─ restart_and_verify() start + 状态 + UDP 监听探测
     │   └─ show_info()          打印 hy2:// 分享链接
     └─ exit 0
```

## 3. 函数职责速查

| 函数 | 职责 | 备注 |
|---|---|---|
| `ask` | 交互读取,答案放全局 `ANSWER` | **始终从 `/dev/tty` 读**,这是管道安装能交互的关键 |
| `parse_ports` | `20000` 或 `20000-20050` → `P_A`/`P_B` | 校验范围与大小关系 |
| `detect_ip` | 4 个公网 API 轮询探测 IPv4 | 非 IPv4 返回失败 |
| `detect_if` | 默认路由网卡名 | 供 DNAT 规则 `-i` 限定
`urlencode` | URL 编码(awk 实现,按字节) | 节点名称拼 `#fragment` 用;`LC_ALL=C` 保证中文/emoji 按字节逐个编码,纯 busybox 环境可用 |
| `download_binary` | 按序尝试: GH_PROXY → 直连 → MIRRORS | 下载后跑 `version` 验证可执行 |
| `place_binary` | HY2_BIN 离线复制 或 download_binary | mktemp 中转再 mv |
| `gen_cert` | EC P-256 自签,CN+SAN=bing.com,10 年 | 已存在直接复用 |
| `write_config` | 生成 hysteria config.yaml | obfs 段按需输出 |
| `write_init` | OpenRC 服务定义 | heredoc 单引号 `<<'ICEOF'`,内容见下节 |
| `write_confd` | 服务环境变量 | DNAT 范围用 **iptables 冒号语法** `a:b` |
| `save_state` | 写 `/etc/hysteria/.env` | 菜单默认值 + show_info 数据源 |
| `prepare_dnat` | 预演一条规则判断能力 | 失败自动 DNAT=0,安装不中断 |
| `apply_config` | 编排上述全部 | 安装与"菜单1重新配置"共用 |
| `show_info` | 读 .env 拼分享链接 | mport/obfs 参数按需追加 |
| `upgrade` | 下载新二进制覆盖+重启 | 配置不动 |
| `uninstall` | 停服务+删全部文件 | 删 `/etc/hysteria` 整个目录 |

## 4. 设计决策(为什么这么写)

改动前先看这里,每条都是为了特定场景:

1. **纯 POSIX sh,不依赖 bash** —— Alpine 默认没有 bash,小内存机器也不想为装 bash 引入 ~15 个依赖包。代价:不能用数组、`[[ ]]`、`local`(故用 `_xxx` 下划线前缀约定局部变量)。

2. **`ask` 从 `/dev/tty` 读而非 stdin** —— 支持 `wget -qO- url | sh` 管道安装。stdin 被 wget 的输出占用了,交互必须绕开。`[ -c /dev/tty ]` 判断不可用时静默返回默认值,批量模式(无 tty)不至于卡死。

3. **DNAT 规则写在 OpenRC 的 `start_pre`/`stop_post` 里,而不是脚本里** —— 规则跟随服务生命周期:开机自启自动恢复、`rc-service stop` 自动清除。脚本只在安装时做**能力预演**(加一条→立删),决定要不要启用。

4. **重新配置时必须先 `stop` 再写新文件** —— `stop_post` 按**旧 conf.d** 的参数删内核里的 iptables 规则。若先覆盖 conf.d 再 restart,旧规则(旧端口段)会永久残留内核。`apply_config` 里的 stop 调用顺序不能动。

5. **下载源顺序: 用户 GH_PROXY → GitHub 直连 → 内置镜像** —— 用户显式设置的代理最优先(确定性强);直连优先于镜像是因为镜像可能返回 HTML 错误页(下载后用 `binary version` 验证会失败,自动落到下一源)。

6. **证书自签 + `insecure=1`** —— NAT 机无独立公网 IP,HTTP-01 验证不可行;自签零依赖。证书带了 SAN(部分客户端只校验 SAN 不看 CN)。将来要支持 ACME,切入点在 `gen_cert()`(见第 6 节)。

7. **iptables 按需安装** —— 不开端口跳跃就不装 iptables 包,给 128M 小鸡省空间(`ensure_iptables` 仅在 `prepare_dnat` 决定启用时调用)。

8. **`set -u` 但不用 `set -e`** —— 一键脚本宁可自己检查每步成败(die/warn),也不要被 `grep -q` 这类"非零即真失败"的命令误杀。

9. **状态存 `/etc/hysteria/.env`** —— 简单 `KEY="VALUE"`,直接 `.` source 进来当默认值,不需要解析 YAML。代价:密码明文存盘,故 chmod 600。

## 5. 生成的文件与格式约定

| 路径 | 内容 | 权限 |
|---|---|---|
| `/usr/local/bin/hysteria` | 官方静态二进制 | 755 |
| `/etc/hysteria/config.yaml` | hysteria 服务端配置 | 600 |
| `/etc/hysteria/server.crt` / `.key` | 自签证书 EC P-256 | 600 |
| `/etc/hysteria/.env` | 脚本状态(见下) | 600 |
| `/etc/init.d/hysteria` | OpenRC 服务 | 755 |
| `/etc/conf.d/hysteria` | 服务环境变量 | 644 |

`.env` 字段:`PUBLIC_IP`(客户端连接地址,与出口 IP 可以不同)、`PUBLIC_PORT`(主端口)、`PORT_RANGE`(空=单端口,`a-b`=有段)、`LISTEN_PORT`、`NODE_NAME`(节点备注名,链接 `#fragment`,默认 `IP:端口`)、`PASSWORD`、`SNI`、`OBFUS`(on/off)、`OBFUS_PASSWORD`。

**conf.d 与 .env 的端口语法不同,勿混用**:conf.d 里 `HY2_DNAT_PORTS` 是 iptables 范围语法(冒号 `20000:20050`),.env 里 `PORT_RANGE` 是给人看的连字符 `20000-20050`。转换在 `write_confd()`。

init 脚本(`write_init` 的 heredoc)要点:单引号 heredoc(`<<'ICEOF'`)保证 `$HY2_DNAT_PORTS` 等在**服务启动时**才展开(读 conf.d),而非生成时;`dnat_add` 失败只 `ewarn` 不阻塞启动;`supervise-daemon` 托管崩溃自动拉起;日志统一到 `/var/log/hysteria.log`。

## 6. 常见修改任务操作路径

**加/改一个环境变量**(如加 `HY2_SNI`):
1. `wizard_batch()` 里加 `${HY2_SNI:-默认}` 解析;
2. 交互向导若也需要,在 `wizard_interactive()` 加对应 `ask`;
3. README 的环境变量表补一行;
4. 若影响生成的文件 → `write_config`/`write_confd`;若需要跨菜单记忆 → `save_state`/`load_state_defaults` 成对加字段。

**换伪装站**:改顶部常量 `MASQ_URL`。要求:目标站支持 https 且最好不是重型站(每个 TLS 握手都会触发回源)。

**换/加下载镜像**:改顶部 `MIRRORS`(空格分隔,每项须以 `/` 结尾)。加新镜像前先验证 `curl -I <镜像><github下载URL>` 返回 `application/octet-stream` 而非 `text/html`。

**加菜单项**:`menu()` 的 printf 列表 + case 分支。注意每个分支末尾 `pause`(apply_config/uninstall 除外,见现有写法)。

**支持新架构**(如 riscv64):`main()` 的 `case "$(uname -m)"` 加映射即可,文件名规则 `hysteria-linux-<arch>` 与上游 release 一致。

**以后加 ACME 域名证书**:入口放 `wizard_interactive()`(问"有无域名"),证书逻辑在 `gen_cert()` 分流;有域名时 config.yaml 的 `tls` 段改写 acme 段(hysteria 原生支持 `acme` 配置,不需要外部客户端);分享链接去掉 `insecure=1` 的拼接在 `show_info()`。**注意**:DNAT/NAT 环境只能走 DNS-01,需要用户给 DNS API key,复杂度大,值得单独一个版本。

**加多用户(userpass)**:改 `write_config` 的 auth 段为 `type: userpass` + 用户文件;菜单加用户管理。分享链接格式不变(密码处填 `user:pass` 并 URL 编码)。

**加IPv6 支持**:`detect_ip` 现在明确拒绝非 IPv4;要支持需处理 `[::]` 括号链接格式 + 探测优先级,牵扯 `show_info` 链接拼接,非小改动。

## 7. 已知限制(有意不做的)

- **IPv6-only 机器**:探测与链接生成只处理 IPv4(v4 最普及;v6 见上节思路)。
- **单密码单用户**:多用户见上节。
- **nftables**:脚本用 iptables 语法。Alpine 现行版本 iptables 包默认是 iptables-legacy 后端;若未来 Alpine 切 nft 后端导致 DNAT 失效,`prepare_dnat` 的预演会自动降级单端口(不会坏,只是跳跃没了),到时再适配。
- **CPU 限制**:不设 bandwidth/up/down(对商家限速不明时乱设反而劣化),用户可自行在 config.yaml 加。
- **无自检/健康监控**:低内存机器不跑 cron 常驻检查,supervise-daemon 保进程存活已够。

## 8. 历史决策记录(排查问题时查这里)

| 日期 | 事项 |
|---|---|
| 2026-10-29 | 初版。验证过:官方 latest 下载链(当时 v2.13.0)、gh-proxy.com 与 ghfast.top 镜像可用;**ghproxy.net 已失效被弃用**——镜像挂了是常态,报"所有下载源失败"时先查 MIRRORS 存活 |
| 2026-10-29 | 首轮自查修复:①重配置时旧 DNAT 规则残留 → apply_config 先 stop 再写文件;②下载源顺序 GH_PROXY 优先;③证书补 SAN;④iptables 改为按需安装;⑤菜单"重新配置"中途取消会整个退出脚本 → apply_config 改返回值,取消只回菜单 |
| 2026-10-29 | 新增自定义节点名称:交互项+`HY2_NAME` 环境变量,存 `.env` 的 `NODE_NAME`,分享链接追加 `#<urlencode后的名称>`。urlencode 用 awk 按字节实现(已实测中文/emoji/`%`/`#`/空格输出正确,如 `香港-01 NAT` → `%E9%A6%99%E6%B8%AF-01%20NAT`)。改动函数:`urlencode`/`wizard_*`/`save_state`/`load_state_defaults`/`confirm_or_abort`/`show_info` |

## 9. 改完怎么验证

本机(Windows/WSL):

```powershell
# 1. 语法(必须过)
wsl dash -n /mnt/d/code/NAT_Node/install.sh; "exit=$LASTEXITCODE"   # exit=0 即通过
# 2. 换行符(必须 0)
$b=[IO.File]::ReadAllBytes("D:\code\NAT_Node\install.sh"); ($i=1..($b.Length-1)|?{$b[$_]-eq10 -and $b[$_-1]-eq13}).Count
```

真机(每类 NAT 商家至少一台,Alpine):

- [ ] 全新安装:一路回车(全默认)
- [ ] 全新安装:端口填一段 `20000-20050`,确认端口跳跃提示出现
- [ ] 管道安装:`wget -qO- <raw>/install.sh | sh` 交互可用
- [ ] 批量:`HY2_PORT=20000 sh install.sh` 无问答装完
- [ ] 菜单 2 链接能在 NekoBox/sing-box 里导入连通(有条件再测 v2rayN)
- [ ] 菜单 1 改端口段后:`iptables -t nat -S | grep REDIRECT` **旧段规则已消失**,只有新段
- [ ] 菜单 1 中途取消:回菜单,配置未变
- [ ] `reboot` 后:服务自启 + DNAT 规则自动恢复
- [ ] 受限 LXC(若有):端口跳跃自动降级提示、节点单端口可用
- [ ] 菜单 7 卸载:`/etc/hysteria`、init.d、conf.d、二进制、日志全没了,`iptables -t nat -S` 无残留

连通性测试最小法(服务端自测,客户端不通时定位用):

```sh
# 服务端看握手是否到达
tail -f /var/log/hysteria.log
```

## 10. 上游参考

- hysteria 官方文档: https://v2.hysteria.network/ (config.yaml 全部字段)
- 官方仓库: https://github.com/apernet/hysteria (release 文件命名规则)
- OpenRC 语法: https://github.com/OpenRC/openrc (`supervise-daemon`、`start_pre` 等)
