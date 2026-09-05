<p align="center">
  <img src="docs/images/icon.png" width="120" alt="Mnemo">
</p>

<h1 align="center">Mnemo</h1>

<p align="center">
  什么东西都能往 MacBook 的刘海里扔。想找的时候，用自然语言提要求就行。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/系统-macOS%2026+-black" alt="macOS">
  <img src="https://img.shields.io/badge/语言-Swift-orange" alt="Swift">
  <img src="https://img.shields.io/badge/许可-MIT-green" alt="License">
  <img src="https://img.shields.io/badge/下载-v3.4.0-blue" alt="Version">
</p>

<p align="center">
  <a href="README_EN.md">English</a> ·
  <a href="#功能亮点">功能亮点</a> ·
  <a href="#使用说明">使用说明</a> ·
  <a href="https://github.com/huaxx-lab/mnemo/releases">下载</a> ·
  <a href="#自己构建">自己构建</a>
</p>

<p align="center">⭐ 觉得好用，就点一个 Star。</p>

---

![链接识别与平台归类](docs/images/links.png)
![收纳轨道](docs/images/stash.png)
![效率模式](docs/images/focus.png)

## 功能亮点

- **一拖就存**：链接、截图、PDF、Word、群消息，往刘海顶部一拖就收好；复制的内容也会自动收进临时轨道
- **iPhone 粘贴自动进 Mac**：手机上复制的文字、截图，自动出现在 Mac 的刘海里，不用任何操作
- **说人话找回来**：「我的阿里云密钥在哪」「那篇 RDMA 论文最新一版」，直接在搜索框问，答案和相关文件一起出来
- **⌘G 问什么答什么**：在任何 App 里选中文字按 ⌘G，它会结合你的库直接给答案；焦点停在输入框时，回答会逐字流式写进去，不用切窗口
- **自动认出待办**：取餐码、快递取件码、群通知里的日程安排，自动建好待办，到点在刘海上提醒你
- **同一篇文件的不同版本自动聚成一摞卡片**，最新版永远在最前，点一下手风琴展开
- **链接认平台**：B站、小红书、知乎自动配图标——装了 App 就跳 App，没装就回到你拖进来时用的那个浏览器
- **隐私空间**：敏感内容指纹进入，退出自动上锁
- **自动更新**：菜单栏点一下版本号就能检查新版本，一键下载、自动装好重启

## 使用说明

| 操作 | 效果 |
|---|---|
| 拖到刘海顶部 | 存进收纳 |
| 悬停或点击刘海 | 展开 / 收起（可在设置里选） |
| `⌃⌘N` | 展开 / 收起 |
| `⌃⌘V` | 收纳当前剪贴板 |
| `⌃⌘C` | 抓取前台选中的内容 |
| `⌘G` | 拿选中的文字直接问，答案落在刘海或流式写进输入框 |
| 双击卡片 | 打开预览（Office 文档直接用系统默认应用打开） |
| 单击卡片 | 复制 |
| 右键卡片 | 重命名、加标签、移入隐私空间等 |

快捷键全部可以在设置里改。

## 安装

从 [Releases](https://github.com/huaxx-lab/mnemo/releases) 下载 `Mnemo-x.x.dmg`，拖进 Applications。首次打开右键 → 打开（自签名包，系统会多问一次）。

## 自己构建

```bash
swift build -c release   # 需要 Xcode 26 beta toolchain
./scripts/build-app.sh   # 产出 build/Mnemo.app
swift test               # 300+ 测试
```

---

<p align="center">有问题和想法欢迎直接开 <a href="https://github.com/huaxx-lab/mnemo/issues">Issue</a>。</p>
