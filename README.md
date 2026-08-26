# LXD

[![Hits](https://hits.spiritlhl.net/lxd.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%230eecf8&edge_flat=false)](https://hits.spiritlhl.net)

## 维护状态

本项目已进入有限维护模式，仅继续修复安装、卸载、IPv6、端口映射和无交互参数等核心问题。Ubuntu 宿主机仍可按现有脚本使用；非 Ubuntu 宿主机、需要 Incus 新特性或长期维护能力的环境，建议迁移到 [oneclickvirt/incus](https://github.com/oneclickvirt/incus)。

## 前言

缘由: https://t.me/spiritlhl/176

所以更推荐：https://github.com/oneclickvirt/incus

本项目于2024.03.01后仅提供有限的维护，非Ubuntu的宿主机建议搭建使用新项目 [incus](https://github.com/oneclickvirt/incus)

## 更新

2026.08.27

- IPv6 转发仅在实际上联网卡启用 NDP 代理，避免全局 `proxy_ndp` 改变无关桥接和既有 IPv6 配置；保留 SLAAC RA 默认路由与委派前缀分配

## 无交互用法

```shell
export noninteractive=true
export DISK_NUMS=40
bash lxdinstall.sh
```

如需自定义存储路径：

```shell
export noninteractive=true
export DISK_NUMS=40
export STORAGE_PATH=/data/lxd-storage
bash lxdinstall.sh
```

[更新日志](CHANGELOG.md)

## 说明文档

国内(China)：

[https://virt.spiritlhl.net/](https://virt.spiritlhl.net/)

国际(Global)：

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

说明文档中 LXD 分区内容

自修补的容器镜像源

https://github.com/oneclickvirt/lxd_images

## 友链

VPS融合怪测评项目

https://github.com/oneclickvirt/ecs

https://github.com/spiritLHLS/ecs

## Sponsor

[![Powered by DartNode](https://dartnode.com/branding/DN-Open-Source-sm.png)](https://dartnode.com?aff=bonus "Powered by DartNode - Free VPS for Open Source")

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/lxd.svg)](https://starchart.cc/oneclickvirt/lxd)
