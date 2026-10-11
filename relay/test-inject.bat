@echo off
rem ============================================================
rem  跟单系统 · 模拟事件注入测试（周末休市也能测链路）
rem  用法：先启动 relay（start.bat），再在 Receiver EA 已挂上图表后运行本脚本
rem  注意：Receiver 的 InpMasterId 输入必须和下面的 MASTER_ID 一致（默认 master1）
rem  [5/6][6/6] 测浮亏跟单门：需 Receiver 参数 InpFloatMode=1、InpFloatAmount=100
rem  （先改参数再运行本脚本；门逻辑休市也能完整验证）
rem ============================================================
set RELAY=http://127.0.0.1:8787
set MASTER_ID=master1

echo [1/4] 检查中转服务...
curl -s %RELAY%/health
echo.
echo.

echo [2/4] 注入模拟开仓事件（master 买入 0.10 手 EURUSD）...
curl -s -X POST %RELAY%/events -H "Content-Type: application/json" -d "{\"master_id\":\"%MASTER_ID%\",\"event\":\"open\",\"ticket\":900001,\"symbol\":\"EURUSD\",\"order_type\":0,\"lots\":0.10,\"price\":1.08500,\"sl\":1.08000,\"tp\":1.09000,\"magic\":0,\"comment\":\"test\",\"time\":\"2026-10-11\"}"
echo.
echo      -- 去 MT 终端看「专家」日志：Receiver 应打印收到 open 事件、映射手数、尝试下单
echo      -- 休市会被拒单（正常），关键看日志里有没有收到和解析事件
echo.
timeout /t 5 >nul

echo [3/4] 注入模拟修改事件（改 SL/TP）...
curl -s -X POST %RELAY%/events -H "Content-Type: application/json" -d "{\"master_id\":\"%MASTER_ID%\",\"event\":\"modify\",\"ticket\":900001,\"symbol\":\"EURUSD\",\"order_type\":0,\"lots\":0.10,\"price\":1.08500,\"sl\":1.08200,\"tp\":1.09200,\"magic\":0,\"comment\":\"test\",\"time\":\"2026-10-11\"}"
echo.
echo      -- Receiver 应打印收到 modify 事件（休市改单也会被拒，看日志即可）
echo.
timeout /t 5 >nul

echo [4/4] 注入模拟平仓事件...
curl -s -X POST %RELAY%/events -H "Content-Type: application/json" -d "{\"master_id\":\"%MASTER_ID%\",\"event\":\"close\",\"ticket\":900001,\"symbol\":\"EURUSD\",\"order_type\":0,\"lots\":0.10,\"price\":1.08600,\"sl\":0,\"tp\":0,\"magic\":0,\"comment\":\"test\",\"time\":\"2026-10-11\"}"
echo.
echo      -- Receiver 应打印收到 close 事件并尝试平掉映射的跟单
echo.
echo [5/6] 注入账户快照（模拟 master 浮亏 -150，触发浮亏跟单门）...
echo      -- 前提：Receiver 参数已设为 InpFloatMode=1、InpFloatAmount=100
curl -s -X POST %RELAY%/events -H "Content-Type: application/json" -d "{\"master_id\":\"%MASTER_ID%\",\"event\":\"snapshot\",\"ticket\":0,\"symbol\":\"\",\"order_type\":0,\"lots\":0,\"price\":0,\"sl\":0,\"tp\":0,\"magic\":0,\"comment\":\"\",\"time\":\"2026-10-11\",\"floating_pl\":-150.00,\"open_count\":2,\"balance\":1000.00,\"equity\":850.00}"
echo.
echo      -- Receiver 日志应打印"浮亏跟单已触发（模式=1..."，门打开
echo.
timeout /t 5 >nul

echo [5/6]b 注入模拟开仓事件（门已开，应跟单）...
curl -s -X POST %RELAY%/events -H "Content-Type: application/json" -d "{\"master_id\":\"%MASTER_ID%\",\"event\":\"open\",\"ticket\":900002,\"symbol\":\"EURUSD\",\"order_type\":0,\"lots\":0.10,\"price\":1.08500,\"sl\":1.08000,\"tp\":1.09000,\"magic\":0,\"comment\":\"test\",\"time\":\"2026-10-11\"}"
echo.
echo      -- Receiver 应尝试跟单开仓（休市拒单正常，关键看有没有"跟单开仓"日志而不是"浮亏跟单未触发，跳过"）
echo.
timeout /t 5 >nul

echo [6/6] 注入账户快照（模拟 master 持仓清零，门重新关闭）...
curl -s -X POST %RELAY%/events -H "Content-Type: application/json" -d "{\"master_id\":\"%MASTER_ID%\",\"event\":\"snapshot\",\"ticket\":0,\"symbol\":\"\",\"order_type\":0,\"lots\":0,\"price\":0,\"sl\":0,\"tp\":0,\"magic\":0,\"comment\":\"\",\"time\":\"2026-10-11\",\"floating_pl\":0.00,\"open_count\":0,\"balance\":1000.00,\"equity\":1000.00}"
echo.
echo      -- Receiver 日志应打印"浮亏跟单重置：master 持仓已清零，门重新关闭"
echo      --（休市时跟单未真实成交、映射为空，门才会重置；开盘实测时门要等跟单也平完才重置）
echo.
timeout /t 5 >nul

echo [6/6]b 注入模拟开仓事件（门已关，应跳过不跟）...
curl -s -X POST %RELAY%/events -H "Content-Type: application/json" -d "{\"master_id\":\"%MASTER_ID%\",\"event\":\"open\",\"ticket\":900003,\"symbol\":\"EURUSD\",\"order_type\":0,\"lots\":0.10,\"price\":1.08500,\"sl\":1.08000,\"tp\":1.09000,\"magic\":0,\"comment\":\"test\",\"time\":\"2026-10-11\"}"
echo.
echo      -- Receiver 应打印"浮亏跟单未触发，跳过 master 订单 #900003"，且不下单
echo.
echo 完成。如 [1/4]-[4/4] 日志都对，说明 发射链路（HTTP）+ 接收解析 + 映射逻辑 全通；
echo 如 [5/6]-[6/6] 日志都对，说明 浮亏跟单门（触发→跟新单→重置→跳过）全通。
echo 开盘后（周一早 6 点北京时间）再用 0.01 手模拟盘做一次真实跟单验证即可。
echo 注意：开盘时间运行本脚本 Receiver 会真实下单，建议先把 Receiver 设为固定手数 0.01（InpLotMode=1、InpFixedLots=0.01）。
pause
