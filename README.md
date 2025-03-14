# 使用
通用（最新版会自动根据系统架构来判断是否添加 ExecStartPre=/bin/sh -c "ulimit -n 51200" ）

```bash
wget -O stls.sh --no-check-certificate https://raw.githubusercontent.com/tunecc/ShadowTLS-Manager/refs/heads/main/stls.sh && chmod +x lstls.sh && ./stls.sh
```



~~LXC系统~~

```bash
wget -O lstls.sh --no-check-certificate https://raw.githubusercontent.com/tunecc/ShadowTLS-Manager/refs/heads/main/lstls.sh && chmod +x lstls.sh && ./lstls.sh
```

~~KVM高内核~~

```bash
wget -O hstls.sh --no-check-certificate https://raw.githubusercontent.com/tunecc/ShadowTLS-Manager/refs/heads/main/hstls.sh && chmod +x hstls.sh && ./hstls.sh
```

# 修改了什么

新脚本会自动根据系统架构来判断是否添加 ` ExecStartPre=/bin/sh -c "ulimit -n 51200"`

`Environment=MONOIO_FORCE_LEGACY_DRIVER=1` ，这个判断还未添加，在还未搞清楚内核要多低才不会导致 CPU 占用 100% 时，不会添加

我在LXC的服务器上面使用的时候会出错，在看了[Snell一键部署-由jinqians大佬撰写](https://github.com/jinqians/snell.sh)的脚本后发现是

```
ExecStartPre=/bin/sh -c "ulimit -n 51200"
```

的问题，下面是GPT的回答

```txt
ExecStartPre=/bin/sh -c "ulimit -n 51200"
这是在正式启动服务前执行的一个预处理命令。它调用 shell 命令 ulimit 来将当前 shell 的最大文件描述符限制设置为 51200。
注意：这个设置仅对 ExecStartPre 执行的 shell 及其子进程有效，且如果服务本身并没有继承这个调整的话，实际生效的还是 systemd 的 LimitNOFILE 指定的数值。

我不设置这个可以吗？

如果不设置 ExecStartPre 来调整 ulimit，同样可能导致服务继承默认的文件打开数限制，从而在实际运行中遇到 "too many open files" 的错误。

总结来说，如果你的服务并不会创建大量并发连接或者文件操作，且系统默认的文件描述符数足够使用，那么可以不设置。但如果预期负载较高，建议适当提高限制，以避免潜在的资源不足问题。
```

按照[这个issue](https://github.com/ihciah/shadow-tls/issues/109)把内核版本高导致的cpu占用100%的代码添加到脚本里面
`Environment=MONOIO_FORCE_LEGACY_DRIVER=1`

```bash
/etc/systemd/system/shadow-tls.service

Environment=MONOIO_FORCE_LEGACY_DRIVER=1

systemctl daemon-reload

systemctl restart shadow-tls.service
```



加入了定时重启

还做了一些小修改

