# MT4/MT5 自用跟单软件

一个发射端 EA + 一个 Python 中转服务 + 一个接收端 EA，MT4/MT5 互相跟单都行，还带**浮亏跟单**功能。

## 特点

- **MT4 / MT5 互相跟单**：同一套代码，MT4 上编译走 MQL4 分支，MT5 上改扩展名为 `.mq5` 编译走 MQL5 分支
- **不经过第三方服务器**：订单信号只走你自己电脑上的中转服务（localhost）
- **浮亏跟单**：信号浮亏到一定金额、或信号开到第 N 单之后才开始跟（适合马丁策略）
- **手数灵活**：按倍数跟（0.5=半仓）或固定手数；品种名不一样可做映射
- **不用 DLL**：纯 WebRequest 实现

## 文件

```
Sender.mq4            发射端（挂信号端 MT4/MT5）
Receiver.mq4          接收端（挂跟单端；MT5 用改扩展名为 .mq5）
relay/server.py       Python 中转服务（FastAPI）
relay/requirements.txt
relay/start.bat       Windows 一键启动
relay/test-inject.bat 休市时注入模拟信号，测试链路用
docs/部署指南.md      详细部署文档
```

## 快速上手

1. 装 Python 3.8+，`pip install -r relay/requirements.txt`，运行 `relay/start.bat`
2. 把 `Sender.mq4` / `Receiver.mq4` 放进 MT4 的 `MQL4\Experts`（MT5 放 `MQL5\Experts` 并改扩展名为 `.mq5`），F7 编译
3. MT4：工具 → 选项 → EA交易 → 允许 WebRequest，添加 `http://127.0.0.1:8787`
4. 信号端图表挂 Sender，跟单端图表挂 Receiver，`InpMasterId` 两边填一致
5. 点亮工具栏「算法交易」，先拿模拟盘测试

注意：MT5 跟单端请用 **hedging（对冲）账户**。中转服务无鉴权，仅限本机使用。

## 免责声明

本软件按现状免费分享，仅供学习交流。跟单不保证盈利，请先用模拟盘充分测试。实盘只用多少充多少，作者不做任何背书。
