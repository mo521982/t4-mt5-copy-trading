@echo off
REM MT 跟单中转服务启动脚本（Windows）
REM 把本文件放到 relay 目录下，双击运行；或配合 NSSM / 计划任务实现开机自启
cd /d %~dp0
if exist venv\Scripts\python.exe (
    venv\Scripts\python.exe server.py
) else (
    python server.py
)
pause
