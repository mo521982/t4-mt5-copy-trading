//+------------------------------------------------------------------+
//| Sender.mq4                                                       |
//| Master 端发射 EA（跨平台统一版）：监控本终端订单变化，推送到中转服务 |
//|                                                                  |
//| 同一份源码，双平台编译：                                          |
//|  - MT4：保存为 Sender.mq4 编译 → 走 MQL4 分支（OnTimer 1 秒轮询）  |
//|  - MT5：复制一份改扩展名为 Sender.mq5 编译 → 走 __MQL5__ 分支      |
//|          （OnTradeTransaction 实时捕获，毫秒级）                   |
//+------------------------------------------------------------------+
#property copyright "自用跟单系统"
#property version   "2.00"
#ifdef __MQL5__
// MQL5 默认即严格模式，此处无需 strict 声明
#else
#property strict
#endif

//--- 输入参数（双平台共用）
input string InpMasterId    = "master1";               // Master 账号标识（follower 端填同一个）
input string InpRelayUrl     = "http://127.0.0.1:8787"; // 中转服务地址
input int    InpTimeoutMs    = 5000;                   // HTTP 超时（毫秒）
input int    InpMagicFilter  = -1;                     // 只推送该 Magic 的订单（-1=全部订单）

//+------------------------------------------------------------------+
//| JSON 转义（双平台共用）                                           |
//+------------------------------------------------------------------+
string JsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", "\\r");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\t", "\\t");
   return s;
}

//+------------------------------------------------------------------+
//| HTTP POST JSON 到中转服务（双平台共用，WebRequest 签名相同）       |
//+------------------------------------------------------------------+
bool HttpPostJson(string url, string body, string &responseOut)
{
   char post[];
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";

   // 字符串转 UTF-8 字节数组（去掉末尾终止符，兼容 7 参数重载）
   int dataSize = StringToCharArray(body, post, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   if(dataSize < 0) dataSize = 0;
   ArrayResize(post, dataSize);

   ResetLastError();
   int res = WebRequest("POST", url, headers, InpTimeoutMs, post, result, resultHeaders);
   if(res == -1)
   {
      int err = GetLastError();
      Print("WebRequest 失败，错误码=", err,
            "（4060 表示 URL 没加白名单：工具→选项→EA交易→允许WebRequest→添加 ", InpRelayUrl, "）");
      return false;
   }
   responseOut = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return true;
}

//+------------------------------------------------------------------+
//| 推送一条订单事件（双平台共用）                                     |
//| JSON 字段与 relay/server.py 的 TradeEvent 对应：                  |
//| master_id/event/ticket/symbol/order_type/lots/price/sl/tp/        |
//| magic/comment/time                                               |
//+------------------------------------------------------------------+
void PushEvent(string eventType, long ticket, string symbol, int orderType,
               double lots, double price, double sl, double tp,
               long magic, string comment)
{
   string json = "{"
      + "\"master_id\":\"" + JsonEscape(InpMasterId) + "\","
      + "\"event\":\"" + eventType + "\","
      + "\"ticket\":" + IntegerToString(ticket) + ","
      + "\"symbol\":\"" + JsonEscape(symbol) + "\","
      + "\"order_type\":" + IntegerToString(orderType) + ","
      + "\"lots\":" + DoubleToString(lots, 8) + ","
      + "\"price\":" + DoubleToString(price, 8) + ","
      + "\"sl\":" + DoubleToString(sl, 8) + ","
      + "\"tp\":" + DoubleToString(tp, 8) + ","
      + "\"magic\":" + IntegerToString(magic) + ","
      + "\"comment\":\"" + JsonEscape(comment) + "\","
      + "\"time\":\"" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\""
      + "}";

   string resp = "";
   if(HttpPostJson(InpRelayUrl + "/events", json, resp))
      Print("已推送 ", eventType, " 事件：", symbol, " #", ticket, " -> ", resp);
}

//+------------------------------------------------------------------+
//| 推送一条账户快照事件（双平台共用；浮亏跟单用）                     |
//| event="snapshot"，ticket=0，symbol 为空；                          |
//| JSON 字段与 relay/server.py 的 TradeEvent 新增字段对应：          |
//| floating_pl / open_count / balance / equity                        |
//| 注意：快照取的是整个账户的值（未按 InpMagicFilter 过滤）           |
//+------------------------------------------------------------------+
void PushSnapshot(double floatingPl, int openCount, double balance, double equity)
{
   string json = "{"
      + "\"master_id\":\"" + JsonEscape(InpMasterId) + "\","
      + "\"event\":\"snapshot\","
      + "\"ticket\":0,"
      + "\"symbol\":\"\","
      + "\"order_type\":0,"
      + "\"lots\":" + DoubleToString(0.0, 8) + ","
      + "\"price\":" + DoubleToString(0.0, 8) + ","
      + "\"sl\":" + DoubleToString(0.0, 8) + ","
      + "\"tp\":" + DoubleToString(0.0, 8) + ","
      + "\"magic\":0,"
      + "\"comment\":\"\","
      + "\"time\":\"" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\","
      + "\"floating_pl\":" + DoubleToString(floatingPl, 2) + ","
      + "\"open_count\":" + IntegerToString(openCount) + ","
      + "\"balance\":" + DoubleToString(balance, 2) + ","
      + "\"equity\":" + DoubleToString(equity, 2)
      + "}";

   string resp = "";
   if(HttpPostJson(InpRelayUrl + "/events", json, resp))
      Print("已推送账户快照：浮动盈亏=", DoubleToString(floatingPl, 2),
            " 持仓订单数=", openCount, " -> ", resp);
}

//+------------------------------------------------------------------+
//| Magic 过滤（双平台共用）                                          |
//+------------------------------------------------------------------+
bool PassMagic(long magic)
{
   return (InpMagicFilter < 0 || magic == (long)InpMagicFilter);
}

#ifdef __MQL5__
//====================================================================
// MT5 分支：OnTradeTransaction 实时捕获（毫秒级）
//====================================================================

//+------------------------------------------------------------------+
//| MT5 订单类型映射到统一编码 0-5                                    |
//| 0=buy 1=sell 2=buylimit 3=selllimit 4=buystop 5=sellstop           |
//+------------------------------------------------------------------+
int MapOrderType(ENUM_ORDER_TYPE t)
{
   switch(t)
   {
      case ORDER_TYPE_BUY:             return 0;
      case ORDER_TYPE_SELL:            return 1;
      case ORDER_TYPE_BUY_LIMIT:       return 2;
      case ORDER_TYPE_SELL_LIMIT:      return 3;
      case ORDER_TYPE_BUY_STOP:        return 4;
      case ORDER_TYPE_SELL_STOP:       return 5;
      case ORDER_TYPE_BUY_STOP_LIMIT:  return 4; // 近似为 buy stop
      case ORDER_TYPE_SELL_STOP_LIMIT: return 5; // 近似为 sell stop
   }
   return -1;
}

//+------------------------------------------------------------------+
//| 处理成交（deal）：开仓 / 平仓 / 反转                              |
//+------------------------------------------------------------------+
void OnDealAdd(ulong dealTicket)
{
   if(!HistoryDealSelect(dealTicket)) return;

   long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   if(!PassMagic(magic)) return;

   long   entry   = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   long   dtype   = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) return; // 忽略出入金等

   string symbol  = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   double volume  = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double price   = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double sl      = HistoryDealGetDouble(dealTicket, DEAL_SL);
   double tp      = HistoryDealGetDouble(dealTicket, DEAL_TP);
   string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
   long   posId   = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   int    otype   = (dtype == DEAL_TYPE_BUY) ? 0 : 1;

   if(entry == DEAL_ENTRY_IN)
   {
      PushEvent("open", posId, symbol, otype, volume, price, sl, tp, magic, comment);
   }
   else if(entry == DEAL_ENTRY_OUT)
   {
      PushEvent("close", posId, symbol, otype, volume, price, 0, 0, magic, "");
   }
   else if(entry == DEAL_ENTRY_INOUT)
   {
      // 反手：先平后开
      PushEvent("close", posId, symbol, otype, volume, price, 0, 0, magic, "");
      PushEvent("open", posId, symbol, otype, volume, price, sl, tp, magic, comment);
   }
}

//+------------------------------------------------------------------+
//| 处理挂单新增（挂单还在持仓池，用 OrderSelect）                    |
//+------------------------------------------------------------------+
void OnOrderAdd(ulong orderTicket)
{
   if(!OrderSelect(orderTicket)) return;

   long magic = OrderGetInteger(ORDER_MAGIC);
   if(!PassMagic(magic)) return;

   int otype = MapOrderType((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE));
   if(otype < 0) return;

   string symbol = OrderGetString(ORDER_SYMBOL);
   double vol    = OrderGetDouble(ORDER_VOLUME_INITIAL);
   double price  = OrderGetDouble(ORDER_PRICE_OPEN);
   double sl     = OrderGetDouble(ORDER_SL);
   double tp     = OrderGetDouble(ORDER_TP);
   string comment= OrderGetString(ORDER_COMMENT);

   PushEvent("open", (long)orderTicket, symbol, otype, vol, price, sl, tp, magic, comment);
}

//+------------------------------------------------------------------+
//| 处理挂单删除                                                     |
//+------------------------------------------------------------------+
void OnOrderDelete(ulong orderTicket)
{
   string symbol = "";
   int otype = 2;
   double vol = 0;
   if(HistoryOrderSelect(orderTicket))
   {
      long magic = HistoryOrderGetInteger(orderTicket, ORDER_MAGIC);
      if(!PassMagic(magic)) return;
      symbol = HistoryOrderGetString(orderTicket, ORDER_SYMBOL);
      otype  = MapOrderType((ENUM_ORDER_TYPE)HistoryOrderGetInteger(orderTicket, ORDER_TYPE));
      vol    = HistoryOrderGetDouble(orderTicket, ORDER_VOLUME_INITIAL);
      if(otype < 0) otype = 2;
   }
   PushEvent("close", (long)orderTicket, symbol, otype, vol, 0, 0, 0, 0, "");
}

//+------------------------------------------------------------------+
//| 处理挂单修改（挂单还在持仓池，用 OrderSelect）                    |
//+------------------------------------------------------------------+
void OnOrderUpdate(ulong orderTicket)
{
   if(!OrderSelect(orderTicket)) return;

   long magic = OrderGetInteger(ORDER_MAGIC);
   if(!PassMagic(magic)) return;

   int otype = MapOrderType((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE));
   if(otype < 0) return;

   string symbol = OrderGetString(ORDER_SYMBOL);
   double vol    = OrderGetDouble(ORDER_VOLUME_INITIAL);
   double price  = OrderGetDouble(ORDER_PRICE_OPEN);
   double sl     = OrderGetDouble(ORDER_SL);
   double tp     = OrderGetDouble(ORDER_TP);

   PushEvent("modify", (long)orderTicket, symbol, otype, vol, price, sl, tp, magic, "");
}

//+------------------------------------------------------------------+
//| 处理持仓变更（如下单改 SL/TP，不经过 deal）                       |
//+------------------------------------------------------------------+
void OnPositionChange(ulong posTicket)
{
   if(!PositionSelectByTicket(posTicket)) return;

   long magic = PositionGetInteger(POSITION_MAGIC);
   if(!PassMagic(magic)) return;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long ptype = PositionGetInteger(POSITION_TYPE);
   int otype = (ptype == POSITION_TYPE_BUY) ? 0 : 1;
   double vol   = PositionGetDouble(POSITION_VOLUME);
   double price = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);

   PushEvent("modify", (long)posTicket, symbol, otype, vol, price, sl, tp, magic, "");
}

//+------------------------------------------------------------------+
//| 交易事务回调（MT5 实时触发）                                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      OnDealAdd(trans.deal);
   else if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
      OnOrderAdd(trans.order);
   else if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
      OnOrderDelete(trans.order);
   else if(trans.type == TRADE_TRANSACTION_ORDER_UPDATE)
      OnOrderUpdate(trans.order);
   else if(trans.type == TRADE_TRANSACTION_POSITION)
      OnPositionChange(trans.position);
}

//+------------------------------------------------------------------+
//| EA 初始化（MT5）                                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   // 预加载历史，保证 HistoryDealSelect / HistoryOrderSelect 可用
   HistorySelect(0, TimeCurrent() + 60);
   EventSetTimer(5); // 每 5 秒推送一次账户快照（浮亏跟单用）
   Print("Sender 已启动（MT5 实时模式），MasterId=", InpMasterId, "，中转服务=", InpRelayUrl);
   Print("请确认：工具→选项→EA交易→已勾选“允许 WebRequest”并添加 ", InpRelayUrl);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA 卸载（MT5）                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("Sender 已停止");
}

//+------------------------------------------------------------------+
//| 定时器：每 5 秒推送账户快照（MT5，浮亏跟单用）                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   // 未连接时不推送，避免断线期间的 0 值快照误触发门的关闭
   if(TerminalInfoInteger(TERMINAL_CONNECTED) == 0) return;
   PushSnapshot(AccountInfoDouble(ACCOUNT_PROFIT),
                PositionsTotal(),
                AccountInfoDouble(ACCOUNT_BALANCE),
                AccountInfoDouble(ACCOUNT_EQUITY));
}

#else
//====================================================================
// MQL4 分支：OnTimer(1 秒) 轮询，对比持仓/挂单快照的 ticket 集合，
// 检测 open / modify / close 事件
//====================================================================

//--- 上次快照（平行数组）
string g_tickets[];   // ticket 字符串
string g_feats[];     // 特征串 "symbol|type|lots|price|sl|tp|magic"，用于检测 modify
string g_symbols[];
int    g_types[];
double g_lots[];
double g_prices[];
double g_sls[];
double g_tps[];
int    g_magics[];
string g_comments[];
int    g_count = 0;

//+------------------------------------------------------------------+
//| 在 ticket 数组里查找，返回下标，找不到返回 -1                     |
//+------------------------------------------------------------------+
int FindTicket(const string &tickets[], int count, string ticket)
{
   for(int i = 0; i < count; i++)
      if(tickets[i] == ticket) return i;
   return -1;
}

//+------------------------------------------------------------------+
//| 把快照数组整体拷贝                                               |
//+------------------------------------------------------------------+
void CopySnapshot(const string &sTickets[], const string &sFeats[],
                  const string &sSymbols[], const int &sTypes[],
                  const double &sLots[], const double &sPrices[],
                  const double &sSls[], const double &sTps[],
                  const int &sMagics[], const string &sComments[], int count)
{
   g_count = count;
   ArrayResize(g_tickets, count);
   ArrayResize(g_feats, count);
   ArrayResize(g_symbols, count);
   ArrayResize(g_types, count);
   ArrayResize(g_lots, count);
   ArrayResize(g_prices, count);
   ArrayResize(g_sls, count);
   ArrayResize(g_tps, count);
   ArrayResize(g_magics, count);
   ArrayResize(g_comments, count);
   for(int i = 0; i < count; i++)
   {
      g_tickets[i] = sTickets[i];
      g_feats[i] = sFeats[i];
      g_symbols[i] = sSymbols[i];
      g_types[i] = sTypes[i];
      g_lots[i] = sLots[i];
      g_prices[i] = sPrices[i];
      g_sls[i] = sSls[i];
      g_tps[i] = sTps[i];
      g_magics[i] = sMagics[i];
      g_comments[i] = sComments[i];
   }
}

//+------------------------------------------------------------------+
//| 采集当前持仓+挂单快照                                             |
//+------------------------------------------------------------------+
void BuildSnapshot(string &tickets[], string &feats[], string &symbols[],
                   int &types[], double &lots[], double &prices[],
                   double &sls[], double &tps[], int &magics[],
                   string &comments[], int &count)
{
   count = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int magic = OrderMagicNumber();
      if(InpMagicFilter >= 0 && magic != InpMagicFilter) continue; // Magic 过滤

      ArrayResize(tickets, count + 1);
      ArrayResize(feats, count + 1);
      ArrayResize(symbols, count + 1);
      ArrayResize(types, count + 1);
      ArrayResize(lots, count + 1);
      ArrayResize(prices, count + 1);
      ArrayResize(sls, count + 1);
      ArrayResize(tps, count + 1);
      ArrayResize(magics, count + 1);
      ArrayResize(comments, count + 1);

      tickets[count] = IntegerToString(OrderTicket());
      symbols[count] = OrderSymbol();
      types[count] = OrderType();
      lots[count] = OrderLots();
      prices[count] = OrderOpenPrice();
      sls[count] = OrderStopLoss();
      tps[count] = OrderTakeProfit();
      magics[count] = magic;
      comments[count] = OrderComment();
      feats[count] = symbols[count] + "|"
                   + IntegerToString(types[count]) + "|"
                   + DoubleToString(lots[count], 8) + "|"
                   + DoubleToString(prices[count], 8) + "|"
                   + DoubleToString(sls[count], 8) + "|"
                   + DoubleToString(tps[count], 8) + "|"
                   + IntegerToString(magic);
      count++;
   }
}

//+------------------------------------------------------------------+
//| 对比快照，推送 open / modify / close 事件                         |
//+------------------------------------------------------------------+
void DetectChanges()
{
   string tickets[];
   string feats[];
   string symbols[];
   int types[];
   double lots[];
   double prices[];
   double sls[];
   double tps[];
   int magics[];
   string comments[];
   int count = 0;
   BuildSnapshot(tickets, feats, symbols, types, lots, prices,
                 sls, tps, magics, comments, count);

   // 1) 新增或变化的订单
   for(int i = 0; i < count; i++)
   {
      int idx = FindTicket(g_tickets, g_count, tickets[i]);
      if(idx < 0)
      {
         // 新订单（开仓或新挂单）
         PushEvent("open", StringToInteger(tickets[i]), symbols[i], types[i],
                   lots[i], prices[i], sls[i], tps[i], magics[i], comments[i]);
      }
      else if(g_feats[idx] != feats[i])
      {
         // SL/TP/价格/手数变化
         PushEvent("modify", StringToInteger(tickets[i]), symbols[i], types[i],
                   lots[i], prices[i], sls[i], tps[i], magics[i], comments[i]);
      }
   }

   // 2) 消失的订单：去历史里查平仓价
   for(int j = 0; j < g_count; j++)
   {
      if(FindTicket(tickets, count, g_tickets[j]) >= 0) continue;

      long ticket = StringToInteger(g_tickets[j]);
      double closePrice = 0;
      string symbol = g_symbols[j];
      int orderType = g_types[j];
      double lot = g_lots[j];
      if(OrderSelect((int)ticket, SELECT_BY_TICKET, MODE_HISTORY))
         closePrice = OrderClosePrice();
      PushEvent("close", ticket, symbol, orderType, lot, closePrice, 0, 0, 0, "");
   }

   // 3) 快照滚动
   CopySnapshot(tickets, feats, symbols, types, lots, prices,
                sls, tps, magics, comments, count);
}

//+------------------------------------------------------------------+
//| EA 初始化（MQL4）                                                |
//+------------------------------------------------------------------+
int OnInit()
{
   // 启动时静默采集一次快照：已存在的持仓不再重复推送为 open
   // 注意：EA 启动前已有的持仓不会被跟单，先启动 EA 再交易
   string tickets[];
   string feats[];
   string symbols[];
   int types[];
   double lots[];
   double prices[];
   double sls[];
   double tps[];
   int magics[];
   string comments[];
   int count = 0;
   BuildSnapshot(tickets, feats, symbols, types, lots, prices,
                 sls, tps, magics, comments, count);
   CopySnapshot(tickets, feats, symbols, types, lots, prices,
                sls, tps, magics, comments, count);

   EventSetTimer(1); // 每秒轮询一次
   Print("Sender 已启动（MT4 轮询模式），MasterId=", InpMasterId, "，中转服务=", InpRelayUrl);
   Print("请确认：工具→选项→EA交易→已勾选“允许 WebRequest”并添加 ", InpRelayUrl);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA 卸载（MQL4）                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("Sender 已停止");
}

//+------------------------------------------------------------------+
//| 定时器：每秒检测一次订单变化（MQL4）                               |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!IsConnected() || !IsTradeAllowed()) return;
   DetectChanges();

   // 每 5 秒推送一次账户快照（浮亏跟单用）
   // 注意：MQL4 的 OrdersTotal() 包含挂单
   static int snapCounter = 0;
   snapCounter++;
   if(snapCounter >= 5)
   {
      snapCounter = 0;
      PushSnapshot(AccountProfit(), OrdersTotal(), AccountBalance(), AccountEquity());
   }
}

#endif
//+------------------------------------------------------------------+
