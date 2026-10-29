# NAT Node — hy2 一键脚本

在 **Alpine** 系统的 **NAT VPS**(低内存小鸡)上一键部署 [Hysteria2](https://github.com/apernet/hysteria) 节点的 shell 脚本。

- 单文件 POSIX sh,**不依赖 bash**,Alpine 自带 busybox ash 即可运行
- 官方 Go 静态二进制,空闲内存占用约 10~20MB,128M 小鸡可跑
- 专为 NAT VPS 设计:单端口 / 端口段映射、内部监听端口可自定义、可选 iptables 端口跳跃
- OpenRC + supervise-daemon 守护,进程崩溃自动拉起,开机自启
- 自签证书零依赖,安装完直接给你分享链接

## 快速开始

SSH 到 VPS 上以 root 执行:

```sh
wget -qO- https://raw.githubusercontent.com/<你的用户名>/NAT_Node/main/install.sh | sh
```

或者下载后运行:

```sh
wget -O install.sh https://raw.githubusercontent.com/<你的用户名>/NAT_Node/main/install.sh
sh install.sh
```

> 换成你的仓库地址后使用。GitHub 直连不畅时,可给命令前面加代理前缀下载,或参考下面 `GH_PROXY`。

安装过程会依次询问(每项有默认值,一路回车也能装):

| 询问项 | 说明 |
|---|---|
| 公网 IP 或域名 | 自动探测(NAT 机探测到的是出口共享 IP),手动填商家分配给你的公网 IP/域名 |
| 公网端口 | 单个如 `20000`,或商家给的一段如 `20000-20050` |
| 内部监听端口 | 多数 NAT 商家是 1:1 映射,回车即可;商家映射规则不同时改成内网实际端口 |
| 端口跳跃 | 给了一段端口时询问,开启后 iptables 把整段 UDP 转发到主端口,客户端可换端口抗封锁 |
| obfs 混淆 | 默认关;运营商对 UDP QoS 严重时开启(salamander) |
| 连接密码 | 回车自动生成随机强密码 |

装完会输出分享链接,直接导入 NekoBox / sing-box / v2rayN 等客户端:

```
hy2://密码@公网IP:端口/?insecure=1&sni=bing.com
```

## 批量部署(环境变量免交互)

多台机器时可以跳过向导,一条命令装完:

```sh
HY2_PORT=20000 sh install.sh
```

| 环境变量 | 说明 | 默认 |
|---|---|---|
| `HY2_PORT` | 公网端口,支持 `20000` 或 `20000-20050`;设置了即进入批量模式 | - |
| `HY2_IP` | 公网 IP/域名 | 自动探测 |
| `HY2_LISTEN` | 内部监听端口 | = 公网主端口 |
| `HY2_PASSWORD` | 连接密码 | 随机生成 |
| `HY2_OBFUS` | `on` 开启 obfs | off |
| `HY2_OBFUS_PASSWORD` | obfs 密码 | 随机生成 |
| `HY2_DNAT` | `off` 关闭端口跳跃(给了端口段时默认开启) | on |
| `HY2_BIN` | 使用本地 hysteria 二进制(离线安装) | - |
| `GH_PROXY` | GitHub 下载加速前缀,如 `https://gh-proxy.com/` | 内置多个镜像自动尝试 |

批量模式下密码与分享链接输出在安装结果里,自行保存。

## 管理菜单

已安装的机器上再次运行脚本,进入管理菜单:

```
1. 重新配置(端口/密码/obfs)
2. 查看节点信息与分享链接
3. 重启服务
4. 服务状态
5. 查看日志(最近 30 行)
6. 升级 hysteria(保留配置)
7. 卸载
0. 退出
```

也可以直接用 OpenRC 命令:

```sh
rc-service hysteria start|stop|restart|status
tail -f /var/log/hysteria.log
```

## 文件布局

```
/usr/local/bin/hysteria          # 二进制
/etc/hysteria/config.yaml        # 配置(600)
/etc/hysteria/server.crt|key     # 自签证书(600)
/etc/init.d/hysteria             # OpenRC 服务
/etc/conf.d/hysteria             # GOMEMLIMIT / 端口跳跃参数
/etc/hysteria/.env               # 脚本状态(600,菜单读取用)
/var/log/hysteria.log            # 日志
```

## 常见问题

**NAT 机探测到的 IP 是什么?**
脚本探测的是出口公网 IP。NAT VPS 一般是多个用户共享一个出口 IP,端口映射到你这台机器——这正是商家分配给你的那组端口能通的原因。所以 IP 一项通常无需改动,除非商家单独给了你独立 IP 或域名。

**端口跳跃规则没生效?**
部分受限 LXC 容器没有 NET_ADMIN 权限,加不了 iptables NAT 规则,脚本会自动降级为单端口并提示。此时客户端直接连主端口即可,功能不受影响,只是不能利用端口段换端口。

**为什么用自签证书?**
NAT VPS 一般没有独立公网 IP,无法做 HTTP 验证签真证书;自签零依赖最稳。传输层加密不受影响,客户端用 `insecure=1` 跳过校验,认证靠强密码。以后需要可自行换成 ACME 证书,改 `config.yaml` 里 `tls` 段即可。

**商家只映射了 TCP 没映射 UDP?**
hy2 依赖 UDP(QUIC),商家面板里确认端口映射包含 UDP,否则连不上。

**客户端不支持 `mport` 参数?**
去掉链接里 `&mport=...` 即可,不影响基本连接。

## 系统要求

- Alpine 3.17+(x86_64 / arm64,LXC 或 KVM 均可)
- root 权限
- 可用内存 ≥ 60MB(脚本已设 `GOMEMLIMIT=64MiB` 压制 Go 运行时内存)
- 端口映射需包含 UDP

## 许可

MIT
