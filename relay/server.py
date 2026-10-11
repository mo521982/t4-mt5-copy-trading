#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MT4/MT5 自用跟单中转服务（relay）

架构：
    Master 终端(Sender EA) --HTTP POST /events--> 本服务
    Follower 终端(Receiver EA) <--HTTP GET /events-- 本服务

设计要点：
- 只监听 127.0.0.1（本机），所有终端跑在同一台 Windows VPS 上，localhost 通信，
  延迟最低，且不需要做鉴权（自用场景）。
- 事件按 master_id 分流，内存保存最近 5000 条，seq 全局自增，follower 用
  since 参数做增量轮询，天然去重。
- 无数据库、无外部依赖，挂了重启即可（follower 的 last_seq 存在 EA 本地文件里，
  服务重启后继续从上次位置拉取，不会漏单也不会重单）。

启动：
    python server.py
或：
    uvicorn server:app --host 127.0.0.1 --port 8787
"""

from collections import defaultdict, deque
from threading import Lock

from fastapi import FastAPI, Query
from pydantic import BaseModel, Field

app = FastAPI(title="MT Copy Relay", version="1.0.0")

MAX_EVENTS = 5000          # 每个 master_id 最多保留的事件数
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8787


class TradeEvent(BaseModel):
    """Sender EA 推送的订单事件。seq 由服务端分配，发送端不用填。"""
    master_id: str = Field(..., max_length=64, description="Master 账号标识")
    event: str = Field(..., description="open | modify | close")
    ticket: int = Field(..., description="Master 端订单 ticket（MT5 用 position/order id）")
    symbol: str = Field(default="", max_length=32)
    order_type: int = Field(default=0, description="0=buy 1=sell 2=buylimit 3=selllimit 4=buystop 5=sellstop")
    lots: float = 0.0
    price: float = 0.0     # 开仓价 / 挂单价；close 事件里是平仓价
    sl: float = 0.0
    tp: float = 0.0
    magic: int = 0
    comment: str = Field(default="", max_length=128)
    time: str = Field(default="", max_length=32)
    # --- 浮亏跟单用快照字段（全部可选，老 EA 不发也不报错）---
    floating_pl: float = Field(default=0.0, description="Master 浮动盈亏（账户货币，负数=浮亏），snapshot 事件用")
    open_count: int = Field(default=0, description="Master 当前持仓订单数，snapshot 事件用")
    balance: float = Field(default=0.0, description="Master 账户余额，snapshot 事件用")
    equity: float = Field(default=0.0, description="Master 账户净值，snapshot 事件用")


_lock = Lock()
_seq = 0  # 全局自增序号
# master_id -> 最近 MAX_EVENTS 条事件（每条已带上 seq）
_events: dict = defaultdict(lambda: deque(maxlen=MAX_EVENTS))


@app.get("/health")
def health():
    """健康检查，EA 和监控脚本用它确认服务活着。"""
    return {"ok": True, "service": "mt-copy-relay", "latest_seq": _seq}


@app.post("/events")
def post_event(ev: TradeEvent):
    """接收 Sender EA 推送的订单事件，返回分配的 seq。"""
    global _seq
    with _lock:
        _seq += 1
        rec = ev.model_dump()
        rec["seq"] = _seq
        _events[ev.master_id].append(rec)
        return {"ok": True, "seq": _seq}


@app.get("/events")
def get_events(
    master_id: str = Query(..., max_length=64),
    since: int = Query(0, ge=0, description="只返回 seq 大于该值的事件"),
):
    """Receiver EA 轮询拉取新事件。"""
    with _lock:
        buf = _events.get(master_id, ())
        out = [e for e in buf if e["seq"] > since]
        return {"ok": True, "events": out, "latest_seq": _seq}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=DEFAULT_HOST, port=DEFAULT_PORT, log_level="info")
