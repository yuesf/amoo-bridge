# Amoo Bridge for Mac

让电脑上的聊天客户端用上手机里的 Amoo。Mac 本机跑一个 OpenAI 兼容网关，USB 连手机即可。非官方工具。

**用法**：双击 `dist/Amoo Bridge Mac.app`；手机开启 USB 调试、USB 用途切到「传输文件 / MTP」后连线；客户端填三行——

- Base URL：`http://127.0.0.1:8788/v1`
- API Key：`sk-amoo`
- 模型名：`amoo-phone`

端口被占用会自动顺延，以界面显示为准。改动源码后执行 `./build.sh` 重新构建。
