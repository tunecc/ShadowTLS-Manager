# ShadowTLS-Manager
ShadowTLS管理脚本，支持一键安装、升级和卸载。ShadowTLS需配合SS、Snell、Trojan等协议，无法单独使用，推荐使用SS2022+ShadowTLS

## 使用方法
### 一键部署命令
```bash
wget -O ShadowTLS_Manager.sh --no-check-certificate https://raw.githubusercontent.com/tunecc/ShadowTLS-Manager/refs/heads/main/ShadowTLS_Manager.sh && chmod +x ShadowTLS_Manager.sh && ./ShadowTLS_Manager.sh
```
### 操作菜单
执行命令后，会显示主菜单：
```
Shadow-TLS 管理菜单
1. 安装 Shadow-TLS
2. 升级 Shadow-TLS
3. 卸载 Shadow-TLS
4. 查看 Shadow-TLS 配置信息
5. 修改 Shadow-TLS 配置
0. 退出
请选择操作 [0-5]:
```
安装中会提示输入相关参数：
1、后端服务端口指已部署的SS或Snell等协议的端口
2、外部监听端口指使用ShadowTLS的端口，默认为443

### 脚本提供了修改ShadowTLS参数的功能，主菜单选择“修改 Shadow-TLS 配置”，会显示以下菜单，按需修改参数。
```
你要修改什么？
==================================
 1.  修改 全部配置
 2.  修改 伪装域名
 3.  修改 ShadowTLS 密码
 4.  修改 后端服务端口
 5.  修改 外部监听端口
==================================
(默认：取消):
```
# 参考资料

## [ShadowTLS原仓库](https://github.com/ihciah/shadow-tls)
[ShadowTLS的设计细节-由ihciah大佬撰写](https://www.ihcblog.com/a-better-tls-obfs-proxy/)

## ShadowTLS伪装域名选择
参考[原仓库Wiki](https://github.com/ihciah/shadow-tls/wiki/V3-Protocol)

## ShadowTLS CPU占用率高解决方法
参考[原仓库issues](https://github.com/ihciah/shadow-tls/issues/109)

## 推荐项目

[SS2022一键部署-由翠花大佬撰写](https://github.com/xOS/Shadowsocks-Rust)

[Snell一键部署-由jinqians大佬撰写](https://github.com/jinqians/snell.sh)
