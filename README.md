# ARvideo

虚拟摄像头 Tweak —— 在 iOS 上用本地视频替换摄像头画面。

> Fork 自 [trizau/iPhone-VCAM](https://github.com/trizau/iPhone-VCAM)，适配 iOS 16 roothide / rootless，并新增 QQ 视频通话适配。

## 功能

- 替换系统摄像头画面，支持绝大多数 App
- **三指长按屏幕 0.6 秒**呼出 / 关闭控制菜单
- 选择本地/在线视频、旋转、镜像、分辨率微调
- **QQ 视频通话适配**：点视频通话时弹出菜单
  - `直接拨打`：正常发起视频电话
  - `选择视频素材`：从相册选好替换视频后自动继续拨打
- 包名 `com.arvideo.yiyu`，arm64，rootless / ElleKit

## 支持环境

- iOS 16.x（roothide / rootless 越狱）
- 基于 ElleKit 注入
- Theos 编译

## 编译

依赖 [Theos](https://theos.dev)，在项目根目录执行：

```bash
export THEOS=$HOME/theos
export PATH=$THEOS/bin:$PATH
make package FINALPACKAGE=1
```

产物在 `packages/` 目录。

## 使用

1. 安装 deb（Sileo / Zebra），确认 `Depends: ellekit` 已满足
2. 重启 SpringBoard / 重启手机
3. 在任意注入的 App 里，**三指长按屏幕**呼出菜单，选择要替换的视频
4. 在 QQ 里点视频通话，会先弹操作菜单（直接拨打 / 选择视频素材 / 取消）

## 常见问题

**Q：视频方向不对？**
呼出菜单后用 `+` `-` 查看摄像头宽高，替换视频的宽高需要与之一致；方向不对就预先把视频旋转/镜像。

**Q：QQ 点语音通话也弹菜单？**
当前版本语音通话同样会弹出菜单，点「直接拨打」即可正常通话。

## 目录说明

- `Tweak.x` —— 主实现（摄像头 hook + 三指菜单 + QQ 拨号适配）
- `TTtest.plist` —— Filter，当前注入 `com.tencent.mobileqq`
- `control` —— deb 元数据

## 致谢

- 原项目 [trizau/iPhone-VCAM](https://github.com/trizau/iPhone-VCAM)
- ElleKit / Theos

## 交流

客服QQ：204325164
