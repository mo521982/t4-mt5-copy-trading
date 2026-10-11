//+------------------------------------------------------------------+
//| Receiver.mq4                                                     |
//| Follower 端接收 EA（跨平台统一版）：轮询中转服务，镜像执行 master   |
//| 的订单动作                                                       |
//|                                                                  |
//| 同一份源码，双平台编译：                                          |
//|  - MT4：保存为 Receiver.mq4 编译 → 走 MQL4 分支                   |
//|         （OrderSend / OrderClose / OrderModify）                  |
//|  - MT5：复制一份改扩展名为 Receiver.mq5 编译 → 走 __MQL5__ 分支    |
//|         （CTrade 下单；建议用 Hedging 对冲账户，Netting 账户下     |
//|          同品种多笔持仓会合并成一笔，跟单映射会失真）              |
//|                                                                  |
//| 原理：OnTimer(1 秒) GET /events?master_id=xxx&since=N 拉取新事件，  |
//| 按 master_ticket -> follower_ticket 映射执行开/改/平               |
//+------------------------------------------------------------------+
#property copyright "自用跟单系统"
#property version   "2.00"
#ifdef __MQL5__
#include <Trade\Trade.mqh>
#else
#property strict
#endif

//--- 手数模式枚举（双平台共用）
enum ENUM_LOT_MODE
{
   LOT_MULTIPLIER = 0, // 按倍数跟随
   LOT_FIXED      = 1  // 固定手数
};

//--- 输入参数（双平台共用）
input string        InpMasterId      = "master1";               // Master 账号标识（与发送端一致）
input string        InpRelayUrl      = "http://127.0.0.1:8787"; // 中转服务地址
input int           InpTimeoutMs     = 5000;                    // HTTP 超时（毫秒）
input ENUM_LOT_MODE InpLotMode       = LOT_MULTIPLIER;          // 手数模式
input double        InpLotMultiplier = 1.0;                     // 手数倍数（按倍数模式时）
input double        InpFixedLots     = 0.01;                    // 固定手数（固定手数模式时）
input string        InpSymbolMap     = "";                      // 品种映射，如 "EURUSD=EURUSD,GBPUSD=GBPUSD.pro"（空=同名）
input string        InpSymbolFilter  = "";                      // 只跟随这些品种，逗号分隔（空=全部跟随）
input int           InpSlippage      = 30;                      // 滑点（点）
input long          InpMagicNumber   = 20261011;                // 跟单订单的 MagicNumber
//--- 浮亏跟单（对标 OKCOPY）：门控开仓，门开后只跟新开仓，门开前的持仓不补
input int           InpFloatMode     = 0;                       // 浮亏跟单模式：0=关闭（默认，原行为） 1=按浮亏金额 2=按订单序号
input double        InpFloatAmount   = 100.0;                   // 模式1：信号浮亏达到该金额（账户货币，取绝对值比较）才开始跟单
input int           InpFloatOrderNum = 3;                       // 模式2：信号开到第几单才开始跟单（适合马丁策略）

//--- 运行状态（双平台共用；ticket 统一用 ulong 存，MQL4 调用时转 int）
#ifdef __MQL5__
CTrade g_trade;
#endif
ulong g_lastSeq = 0;      // 已处理的最新 seq（存文件，EA 重启后续传）
ulong g_mTickets[];       // master ticket
ulong g_fTickets[];       // follower ticket
int   g_mapCount = 0;
//--- 浮亏跟单状态
bool   g_gateOpen    = false; // 门：false=未触发（跳过新开仓），true=已触发（跟随新开仓）
double g_masterFloat = 0.0;   // master 最新浮动盈亏（账户货币）
int    g_masterOpens = 0;     // master 最新持仓订单数

//+------------------------------------------------------------------+
//| 状态持久化（双平台共用）：文本方式存文件，格式 "seq,gate"         |
//| 避开 MQL4 没有 FileWriteLong/FileReadLong 的坑                    |
//| 注意：老版本 .dat 只有 seq 数字（无逗号），读到时 gate 默认为     |
//| false，兼容；升级后首次启动会从 seq=0 重读，属于一次性行为        |
//| （open 事件有映射去重，close/modify 对未知单忽略）                |
//+------------------------------------------------------------------+
string SeqFileName()
{
   return "mtcopy_" + InpMasterId + ".dat";
}

void LoadState()
{
   g_lastSeq = 0;
   g_gateOpen = false;
   int h = FileOpen(SeqFileName(), FILE_READ | FILE_BIN);
   if(h != INVALID_HANDLE)
   {
      string s = FileReadString(h); // 读到文件尾；空文件返回 ""
      FileClose(h);
      if(s != "")
      {
         string parts[];
         int n = StringSplit(s, ',', parts);
         if(n >= 1) g_lastSeq = (ulong)StringToInteger(parts[0]);
         if(n >= 2) g_gateOpen = (StringToInteger(parts[1]) != 0);
         // n==1 为老格式（纯 seq），gate 保持 false
      }
   }
}

void SaveState()
{
   int h = FileOpen(SeqFileName(), FILE_WRITE | FILE_BIN);
   if(h != INVALID_HANDLE)
   {
      FileWriteString(h, IntegerToString(g_lastSeq) + "," + (g_gateOpen ? "1" : "0"));
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| 浮亏跟单门评估（双平台共用）：收到 snapshot 事件后调用             |
//| 门行为：                                                         |
//|  - 门未开：达到触发条件 → 开门（只跟门开之后的新开仓，不补旧单）   |
//|  - 门已开：master 持仓清零 且 本地无镜像持仓 → 关门（重新武装）    |
//+------------------------------------------------------------------+
void EvalGate()
{
   if(InpFloatMode == 0) return; // 功能关闭，原行为

   if(!g_gateOpen)
   {
      bool trigger = false;
      if(InpFloatMode == 1 && g_masterFloat <= -InpFloatAmount)
         trigger = true; // 模式1：信号浮亏金额达到阈值（取绝对值比较）
      else if(InpFloatMode == 2 && g_masterOpens >= InpFloatOrderNum)
         trigger = true; // 模式2：信号开到第 N 单（适合马丁策略）

      if(trigger)
      {
         g_gateOpen = true;
         SaveState();
         Print("浮亏跟单已触发（模式=", InpFloatMode,
               "，master 浮动盈亏=", DoubleToString(g_masterFloat, 2),
               "，持仓数=", g_masterOpens,
               "）：开始跟随新开仓，门开前的持仓不补");
      }
   }
   else
   {
      // 门已开：master 持仓清零且本地无镜像持仓 → 关门，等待下次触发
      if(g_masterOpens == 0 && g_mapCount == 0)
      {
         g_gateOpen = false;
         SaveState();
         Print("浮亏跟单重置：master 持仓已清零，门重新关闭，等待下次触发");
      }
   }
}

//+------------------------------------------------------------------+
//| 极简 JSON 解析（双平台共用，只解析本系统约定的事件结构）           |
//| 限制：字符串值里不要出现大括号 {}                                 |
//+------------------------------------------------------------------+
string JsonGetStr(string obj, string key)
{
   string pat = "\"" + key + "\":";
   int p = StringFind(obj, pat);
   if(p < 0) return "";
   p += StringLen(pat);
   int n = StringLen(obj);
   while(p < n && StringGetCharacter(obj, p) == ' ') p++;
   if(p >= n || StringGetCharacter(obj, p) != '"') return "";
   p++;
   string out = "";
   while(p < n)
   {
      ushort c = StringGetCharacter(obj, p);
      if(c == '\\' && p + 1 < n)
      {
         // 转义字符：直接取下一个字符（\" \\ \/ 等）
         out += ShortToString(StringGetCharacter(obj, p + 1));
         p += 2;
         continue;
      }
      if(c == '"') break;
      out += ShortToString(c);
      p++;
   }
   return out;
}

double JsonGetNum(string obj, string key)
{
   string pat = "\"" + key + "\":";
   int p = StringFind(obj, pat);
   if(p < 0) return 0;
   p += StringLen(pat);
   int n = StringLen(obj);
   while(p < n && StringGetCharacter(obj, p) == ' ') p++;
   int q = p;
   while(q < n)
   {
      ushort c = StringGetCharacter(obj, q);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E') q++;
      else break;
   }
   if(q <= p) return 0;
   return StringToDouble(StringSubstr(obj, p, q - p));
}

ulong JsonGetUlong(string obj, string key)
{
   string pat = "\"" + key + "\":";
   int p = StringFind(obj, pat);
   if(p < 0) return 0;
   p += StringLen(pat);
   int n = StringLen(obj);
   while(p < n && StringGetCharacter(obj, p) == ' ') p++;
   int q = p;
   while(q < n)
   {
      ushort c = StringGetCharacter(obj, q);
      if(c >= '0' && c <= '9') q++;
      else break;
   }
   if(q <= p) return 0;
   return (ulong)StringToInteger(StringSubstr(obj, p, q - p));
}

int JsonGetInt(string obj, string key) { return (int)JsonGetNum(obj, key); }

// 把 "events":[{...},{...}] 拆成对象字符串数组
int ParseEvents(string body, string &items[])
{
   int cnt = 0;
   int p = StringFind(body, "\"events\":");
   if(p < 0) return 0;
   p = StringFind(body, "[", p);
   if(p < 0) return 0;
   p++;
   int n = StringLen(body);
   int depth = 0;
   int start = -1;
   for(int i = p; i < n; i++)
   {
      ushort c = StringGetCharacter(body, i);
      if(c == '{')
      {
         if(depth == 0) start = i;
         depth++;
      }
      else if(c == '}')
      {
         depth--;
         if(depth == 0 && start >= 0)
         {
            ArrayResize(items, cnt + 1);
            items[cnt] = StringSubstr(body, start, i - start + 1);
            cnt++;
            start = -1;
         }
      }
      else if(c == ']' && depth == 0) break;
   }
   return cnt;
}

//+------------------------------------------------------------------+
//| HTTP GET（双平台共用）                                            |
//+------------------------------------------------------------------+
bool HttpGet(string url, string &bodyOut)
{
   char req[];
   ArrayResize(req, 0);
   char result[];
   string resultHeaders;
   ResetLastError();
   int res = WebRequest("GET", url, "", InpTimeoutMs, req, result, resultHeaders);
   if(res == -1)
   {
      Print("WebRequest GET 失败，错误码=", GetLastError(),
            "（4060 表示 URL 没加白名单：工具→选项→EA交易→允许WebRequest→添加 ", InpRelayUrl, "）");
      return false;
   }
   bodyOut = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return true;
}

//+------------------------------------------------------------------+
//| 映射表操作：master_ticket -> follower_ticket（双平台共用）         |
//+------------------------------------------------------------------+
int FindMap(ulong mTicket)
{
   for(int i = 0; i < g_mapCount; i++)
      if(g_mTickets[i] == mTicket) return i;
   return -1;
}

void AddMap(ulong mTicket, ulong fTicket)
{
   if(FindMap(mTicket) >= 0) return;
   ArrayResize(g_mTickets, g_mapCount + 1);
   ArrayResize(g_fTickets, g_mapCount + 1);
   g_mTickets[g_mapCount] = mTicket;
   g_fTickets[g_mapCount] = fTicket;
   g_mapCount++;
}

void DelMap(ulong mTicket)
{
   int idx = FindMap(mTicket);
   if(idx < 0) return;
   for(int i = idx; i < g_mapCount - 1; i++)
   {
      g_mTickets[i] = g_mTickets[i + 1];
      g_fTickets[i] = g_fTickets[i + 1];
   }
   g_mapCount--;
   ArrayResize(g_mTickets, g_mapCount);
   ArrayResize(g_fTickets, g_mapCount);
}

//+------------------------------------------------------------------+
//| 品种映射：master 品种名 -> 本地品种名（双平台共用）                |
//+------------------------------------------------------------------+
string MapSymbol(string masterSym)
{
   if(InpSymbolMap == "") return masterSym;
   string pairs[];
   int n = StringSplit(InpSymbolMap, ',', pairs);
   for(int i = 0; i < n; i++)
   {
      string kv[];
      if(StringSplit(pairs[i], '=', kv) == 2)
      {
         string k = kv[0]; StringTrimLeft(k); StringTrimRight(k);
         string v = kv[1]; StringTrimLeft(v); StringTrimRight(v);
         if(k == masterSym) return v;
      }
   }
   return masterSym; // 没配映射就用同名
}

//+------------------------------------------------------------------+
//| 品种过滤（双平台共用）                                            |
//+------------------------------------------------------------------+
bool PassFilter(string masterSym)
{
   if(InpSymbolFilter == "") return true;
   string arr[];
   int n = StringSplit(InpSymbolFilter, ',', arr);
   for(int i = 0; i < n; i++)
   {
      string s = arr[i]; StringTrimLeft(s); StringTrimRight(s);
      if(s == masterSym) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 确保品种在市场报价里可用（双平台共用）                             |
//+------------------------------------------------------------------+
bool EnsureSymbol(string sym)
{
   if(!SymbolSelect(sym, true))
   {
      Print("品种不可用，已跳过：", sym, "（检查品种名映射是否正确）");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 手数归一化到券商允许的 min/max/step                              |
//+------------------------------------------------------------------+
#ifdef __MQL5__
double NormalizeLots(string sym, double lots)
{
   double minV = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lots = MathMax(minV, MathMin(maxV, lots));
   lots = MathFloor(lots / step + 1e-8) * step;
   return NormalizeDouble(lots, 8);
}
#else
double NormalizeLots(string sym, double lots)
{
   double minLot = MarketInfo(sym, MODE_MINLOT);
   double maxLot = MarketInfo(sym, MODE_MAXLOT);
   double step   = MarketInfo(sym, MODE_LOTSTEP);
   if(step <= 0) step = 0.01;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step) * step;
   return NormalizeDouble(lots, 2);
}
#endif

//+------------------------------------------------------------------+
//| 手数计算（双平台共用）                                            |
//+------------------------------------------------------------------+
double CalcLots(double masterLots)
{
   if(InpLotMode == LOT_FIXED) return InpFixedLots;
   return masterLots * InpLotMultiplier;
}

#ifdef __MQL5__
//+------------------------------------------------------------------+
//| 按品种设置成交模式（MT5：券商要求不同，自动适配）                  |
//+------------------------------------------------------------------+
void SetupFilling(string sym)
{
   long fm = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fm & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| 处理 open 事件（MT5：CTrade）                                     |
//+------------------------------------------------------------------+
void ProcOpen(string symbol, int orderType, double masterLots, double price,
              double sl, double tp, ulong mTicket)
{
   if(symbol == "") return;
   if(orderType < 0 || orderType > 5) return;
   if(!PassFilter(symbol)) return;
   if(FindMap(mTicket) >= 0) return; // 已经跟过，防止重复
   // 浮亏跟单门控：门未开时跳过新开仓（门开后只跟新开仓，门开前的持仓不补）
   if(InpFloatMode != 0 && !g_gateOpen)
   {
      Print("浮亏跟单未触发，跳过 master 订单 #", IntegerToString((long)mTicket));
      return;
   }

   string sym = MapSymbol(symbol);
   if(!EnsureSymbol(sym)) return;

   double lots = NormalizeLots(sym, CalcLots(masterLots));
   if(lots <= 0) { Print("手数计算异常，跳过：", symbol); return; }

   SetupFilling(sym);
   string cmt = "copy#" + IntegerToString(mTicket);
   bool ok = false;
   if(orderType == 0)      ok = g_trade.Buy(lots, sym, 0, sl, tp, cmt);
   else if(orderType == 1) ok = g_trade.Sell(lots, sym, 0, sl, tp, cmt);
   else if(orderType == 2) ok = g_trade.BuyLimit(lots, price, sym, sl, tp, ORDER_TIME_GTC, 0, cmt);
   else if(orderType == 3) ok = g_trade.SellLimit(lots, price, sym, sl, tp, ORDER_TIME_GTC, 0, cmt);
   else if(orderType == 4) ok = g_trade.BuyStop(lots, price, sym, sl, tp, ORDER_TIME_GTC, 0, cmt);
   else if(orderType == 5) ok = g_trade.SellStop(lots, price, sym, sl, tp, ORDER_TIME_GTC, 0, cmt);

   if(!ok)
   {
      Print("跟单开仓失败：", sym, " retcode=", g_trade.ResultRetcode(),
            " ", g_trade.ResultRetcodeDescription());
      return;
   }

   ulong fTicket = 0;
   if(orderType <= 1)
   {
      // 市价单：从成交 deal 反查 position id
      ulong deal = g_trade.ResultDeal();
      if(deal > 0 && HistoryDealSelect(deal))
         fTicket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(fTicket == 0)
         Print("警告：市价单已成交但未取到持仓 ticket，close 事件将无法镜像");
   }
   else
   {
      fTicket = g_trade.ResultOrder();
   }

   if(fTicket > 0)
   {
      AddMap(mTicket, fTicket);
      Print("跟单开仓：", sym, " #", fTicket, " 手数=", DoubleToString(lots, 2),
            "（master #", mTicket, "）");
   }
}

//+------------------------------------------------------------------+
//| 处理 close 事件（MT5）                                            |
//+------------------------------------------------------------------+
void ProcClose(ulong mTicket)
{
   int idx = FindMap(mTicket);
   if(idx < 0) return; // 没跟过这单
   ulong ft = g_fTickets[idx];
   bool ok = false;
   if(PositionSelectByTicket(ft))
      ok = g_trade.PositionClose(ft);
   else if(OrderSelect(ft))
      ok = g_trade.OrderDelete(ft); // 挂单直接删除
   else
   {
      DelMap(mTicket); // 本地单已不在，清理映射
      return;
   }
   if(ok)
   {
      Print("跟单平仓：#", ft, "（master #", mTicket, "）");
      DelMap(mTicket);
   }
   else
      Print("跟单平仓失败：#", ft, " retcode=", g_trade.ResultRetcode());
}

//+------------------------------------------------------------------+
//| 处理 modify 事件（MT5：改 SL/TP，挂单改价）                        |
//+------------------------------------------------------------------+
void ProcModify(ulong mTicket, double price, double sl, double tp)
{
   int idx = FindMap(mTicket);
   if(idx < 0) return;
   ulong ft = g_fTickets[idx];
   if(PositionSelectByTicket(ft))
   {
      int dg = (int)SymbolInfoInteger(PositionGetString(POSITION_SYMBOL), SYMBOL_DIGITS);
      if(!g_trade.PositionModify(ft, sl, tp))
         Print("跟单改单失败：#", ft, " retcode=", g_trade.ResultRetcode());
      else
         Print("跟单改单：#", ft, " SL=", DoubleToString(sl, dg), " TP=", DoubleToString(tp, dg));
   }
   else if(OrderSelect(ft))
   {
      if(!g_trade.OrderModify(ft, price, sl, tp, ORDER_TIME_GTC, 0))
         Print("跟单改挂单失败：#", ft, " retcode=", g_trade.ResultRetcode());
   }
   else
      DelMap(mTicket);
}

#else
//+------------------------------------------------------------------+
//| 处理 open 事件（MQL4：OrderSend）                                 |
//| orderType 0-5 恰好对应 MQL4 的 OP_BUY..OP_SELLSTOP                |
//+------------------------------------------------------------------+
void ProcOpen(string symbol, int orderType, double masterLots, double price,
              double sl, double tp, ulong mTicket)
{
   if(symbol == "") return;
   if(orderType < 0 || orderType > 5) return;
   if(!PassFilter(symbol)) return;
   if(FindMap(mTicket) >= 0) return; // 已经跟过，防止重复
   // 浮亏跟单门控：门未开时跳过新开仓（门开后只跟新开仓，门开前的持仓不补）
   if(InpFloatMode != 0 && !g_gateOpen)
   {
      Print("浮亏跟单未触发，跳过 master 订单 #", IntegerToString((long)mTicket));
      return;
   }

   string sym = MapSymbol(symbol);
   if(!EnsureSymbol(sym)) return;

   double lots = NormalizeLots(sym, CalcLots(masterLots));
   if(lots <= 0) { Print("手数计算异常，跳过：", symbol); return; }

   RefreshRates();
   double execPrice = price;
   if(orderType == OP_BUY) execPrice = MarketInfo(sym, MODE_ASK);
   else if(orderType == OP_SELL) execPrice = MarketInfo(sym, MODE_BID);

   string cmt = "copy#" + IntegerToString(mTicket);
   ResetLastError();
   int ticket = OrderSend(sym, orderType, lots, execPrice, InpSlippage,
                          sl, tp, cmt, (int)InpMagicNumber, 0, clrNONE);
   if(ticket < 0)
      Print("跟单开仓失败：", sym, " 类型=", orderType, " 错误=", GetLastError());
   else
   {
      AddMap(mTicket, (ulong)ticket);
      Print("跟单开仓：", sym, " #", ticket, " 手数=", DoubleToString(lots, 2),
            "（master #", mTicket, "）");
   }
}

//+------------------------------------------------------------------+
//| 处理 close 事件（MQL4）                                           |
//+------------------------------------------------------------------+
void ProcClose(ulong mTicket)
{
   int idx = FindMap(mTicket);
   if(idx < 0) return; // 没跟过这单，无需处理
   int ft = (int)g_fTickets[idx];
   if(!OrderSelect(ft, SELECT_BY_TICKET))
   {
      DelMap(mTicket); // 本地单已不在，清理映射
      return;
   }
   int type = OrderType();
   bool ok = false;
   if(type == OP_BUY || type == OP_SELL)
   {
      RefreshRates();
      double px = (type == OP_BUY) ? MarketInfo(OrderSymbol(), MODE_BID)
                                  : MarketInfo(OrderSymbol(), MODE_ASK);
      ok = OrderClose(ft, OrderLots(), px, InpSlippage, clrNONE);
   }
   else
   {
      ok = OrderDelete(ft); // 挂单直接删除
   }
   if(ok)
   {
      Print("跟单平仓：#", ft, "（master #", mTicket, "）");
      DelMap(mTicket);
   }
   else
      Print("跟单平仓失败：#", ft, " 错误=", GetLastError());
}

//+------------------------------------------------------------------+
//| 处理 modify 事件（MQL4：改 SL/TP，挂单改价）                        |
//+------------------------------------------------------------------+
void ProcModify(ulong mTicket, double price, double sl, double tp)
{
   int idx = FindMap(mTicket);
   if(idx < 0) return;
   int ft = (int)g_fTickets[idx];
   if(!OrderSelect(ft, SELECT_BY_TICKET))
   {
      DelMap(mTicket);
      return;
   }
   int type = OrderType();
   double px = (type == OP_BUY || type == OP_SELL) ? OrderOpenPrice() : price;
   ResetLastError();
   if(!OrderModify(ft, px, sl, tp, 0, clrNONE))
      Print("跟单改单失败：#", ft, " 错误=", GetLastError());
   else
      Print("跟单改单：#", ft, " SL=", DoubleToString(sl, (int)MarketInfo(OrderSymbol(), MODE_DIGITS)),
            " TP=", DoubleToString(tp, (int)MarketInfo(OrderSymbol(), MODE_DIGITS)));
}

#endif

//+------------------------------------------------------------------+
//| EA 初始化                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
#ifdef __MQL5__
   // 预加载历史，保证 HistoryDealSelect 可用
   HistorySelect(0, TimeCurrent() + 60);
   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   // 同步模式（默认）：下单返回时已知结果，逻辑更简单可靠
#endif

   LoadState(); // 恢复 seq 和浮亏跟单门状态（"seq,gate" 格式，兼容老格式）
   EventSetTimer(1); // 每秒轮询一次
   Print("Receiver 已启动，MasterId=", InpMasterId, "，从 seq=", g_lastSeq, " 开始拉取",
         "，浮亏跟单门=", (g_gateOpen ? "开" : "关"));
#ifdef __MQL5__
   Print("注意：Netting 账户下同品种持仓会合并，建议用 Hedging 账户");
#else
   Print("手数模式=", (InpLotMode == LOT_MULTIPLIER ? "按倍数" : "固定手数"),
         " Magic=", InpMagicNumber);
#endif
   Print("请确认：工具→选项→EA交易→已勾选“允许 WebRequest”并添加 ", InpRelayUrl);
   if(InpFloatMode == 0)
      Print("浮亏跟单：关闭（所有信号订单都跟）");
   else if(InpFloatMode == 1)
      Print("浮亏跟单：模式1 按浮亏金额，阈值=", DoubleToString(InpFloatAmount, 2));
   else
      Print("浮亏跟单：模式2 按订单序号，第 ", InpFloatOrderNum, " 单起跟");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA 卸载                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   SaveState();
   Print("Receiver 已停止，已保存 seq=", g_lastSeq, "，浮亏跟单门=", (g_gateOpen ? "开" : "关"));
}

//+------------------------------------------------------------------+
//| 定时器：轮询拉取并执行事件                                        |
//+------------------------------------------------------------------+
void OnTimer()
{
#ifdef __MQL5__
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
#else
   if(!IsConnected() || !IsTradeAllowed()) return;
#endif

   string url = InpRelayUrl + "/events?master_id=" + InpMasterId
              + "&since=" + IntegerToString(g_lastSeq);
   string body = "";
   if(!HttpGet(url, body)) return;

   string items[];
   int n = ParseEvents(body, items);
   for(int i = 0; i < n; i++)
   {
      ulong seq = JsonGetUlong(items[i], "seq");
      if(seq <= g_lastSeq) continue; // seq 去重

      string ev     = JsonGetStr(items[i], "event");
      ulong ticket  = JsonGetUlong(items[i], "ticket");
      string symbol = JsonGetStr(items[i], "symbol");
      int otype     = JsonGetInt(items[i], "order_type");
      double lots   = JsonGetNum(items[i], "lots");
      double price  = JsonGetNum(items[i], "price");
      double sl     = JsonGetNum(items[i], "sl");
      double tp     = JsonGetNum(items[i], "tp");

      if(ev == "open")
         ProcOpen(symbol, otype, lots, price, sl, tp, ticket);
      else if(ev == "close")
         ProcClose(ticket);
      else if(ev == "modify")
         ProcModify(ticket, price, sl, tp);
      else if(ev == "snapshot")
      {
         // 账户快照：只更新 master 状态、评估浮亏跟单门，不做交易动作
         g_masterFloat = JsonGetNum(items[i], "floating_pl");
         g_masterOpens = JsonGetInt(items[i], "open_count");
         EvalGate();
      }

      g_lastSeq = seq;
   }
   if(n > 0) SaveState();
}
//+------------------------------------------------------------------+
