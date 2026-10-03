Lightpanda Browser - Windows 原生版 (lightpanda-portable-windows-x64)
=====================================================================

这是 lightpanda-io/browser 开源项目 (https://github.com/lightpanda-io/browser)
的 Windows x64 原生移植版。上游官方仅支持 Linux/macOS，本移植版由社区补丁构建。

版本: 1.1.0-dev.3 (对应上游 main 2026-10-02 快照, V8 15.5.35.13)
协议: AGPL-3.0（源码补丁见同仓库 win-port/ 目录与 git 历史）

快速上手
--------
  lightpanda.exe version                          查看版本
  lightpanda.exe fetch <URL> --dump markdown      抓取网页并转 Markdown
  lightpanda.exe fetch <URL> --dump html|png|pdf  其他导出格式
  lightpanda.exe serve --port 9222                启动 CDP 服务（Puppeteer/Playwright 可连）
  lightpanda.exe fetch --help                     完整参数

  访问外网需代理时: 先设置环境变量 HTTP_PROXY / HTTPS_PROXY 再运行。
  实测: fetch https://www.baidu.com --dump markdown 可直接出内容。

运行时依赖
----------
  Windows 10/11 x64。VC 运行库 DLL 已随包捆绑（VCRUNTIME140*.dll）。
  无需安装任何其他组件。

注意事项
--------
  1. 本构建基于 AGPL-3.0，商用分发请遵守协议开源义务。
  2. serve 模式的事件循环为 select() 实现（FD 上限 1024），高并发场景建议
     控制连接数或等待上游官方 Windows 版。
  3. 上游迭代极快（日均 10+ commit），本移植基于 2026-10-02 快照，
     后续同步请按 win-port/patches/ 的补丁序列 rebase。
