# svideo iOS（个人自用）

从 Android APK（`com.xxx.svideo`，快猫）逆向协议后复刻的 iOS 客户端，TrollStore 安装。

## 协议（从 smali 提取）

- 域名轮换（动态探测）: `api.kkmmapi.com` / `api.ppmapi.com` / `888.apikm.com` / `999.km58888.com`
- 签名: `sig = MD5(按key排序的 "&k=v" 拼接串 + "maomi_pass_xyz")`
- AES: key=`625202f9149maomi` iv=`5efd3f6060emaomi`（协议层已预留）
- API: 登录 `/api/users/login`、视频列表 `/api/videos/listAll`、详情 `/api/videos/detail`、热门 `/api/videos/listHot`

## 功能

- 手机号+密码登录
- 视频列表 + 热门
- **播放即自动缓存**到 `Documents/VideoCache/`，下次离线可看
- TrollStore 装后 Filza 可访问缓存目录 / 文件共享导出

## 编译

GitHub 私密仓库 `298594413/svideo-ios` 的 Actions 会自动编译，Artifacts 下 `svideo-TrollStore` 得 IPA，TrollStore 安装。

## 说明

- 视频详情的播放URL字段名我做了多种兼容（`url`/`playUrl`/`videoUrl`/`path`），如实际不同需调整 `VideoListView.swift`
- 加密细节（AES 用于哪些字段）需真实抓包验证，当前以 MD5 签名为主
- iOS 15.0+

## 状态

初版复刻，登录/列表/缓存播放框架已搭好。字段细节需按真实接口微调。
