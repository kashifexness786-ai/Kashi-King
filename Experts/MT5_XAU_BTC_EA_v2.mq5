//+------------------------------------------------------------------+
//|                               MT5_XAU_BTC_EA_v2.mq5            |
//|  Robust, compile-clean Expert Advisor for MT5 (XAU & BTC touch)  |
//+------------------------------------------------------------------+
#property copyright "Generated"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

input double  InpLotSize         = 0.01;      // Lot Size
input ulong   InpMagicNumber     = 123456;    // Magic Number
input double  InpTakeProfit      = 0.200;     // Take Profit (price units)
input double  InpMaxSpreadPoints = 500.0;     // Max spread (points)
input int     InpSlippage        = 5;         // Slippage (points)
input bool    InpEnableXAU       = true;      // Enable XAU symbol trading
input bool    InpEnableBTC       = true;      // Enable BTC symbol trading
input int     InpSequenceMinutes = 4;         // Sequence duration (minutes)
input int     InpRetryCount      = 3;         // Order retry attempts
input int     InpRetryDelayMs    = 250;       // Delay between retries (ms)

CTrade trade;

// detected symbols
string SymXAU = "";
string SymBTC = "";

enum SeqState { SEQ_NONE=0, SEQ_SELL, SEQ_BUY };

struct SeqInfo
{
  SeqState state;
  datetime candle_time;
  datetime sequence_end;
  double   candle_open;
  double   last_sl;
  double   last_tp;
  bool     active;
};

SeqInfo infoXAU, infoBTC;

//------------------------------ helpers ----------------------------
bool SafeSymbolSelect(const string name)
{
  bool res = SymbolSelect(name, true);
  long flag = SymbolInfoInteger(name, SYMBOL_SELECT);
  return (res || (flag != 0));
}

bool GetSymbolDouble(const string sym, const int prop, double &out)
{
  return SymbolInfoDouble(sym, prop, out);
}

double Pip(const string sym)
{
  double pt=0.0;
  if(!GetSymbolDouble(sym, SYMBOL_POINT, pt) || pt<=0.0) return 0.0;
  int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
  if(d>3) return pt * 10.0;
  return pt;
}

//------------------------------ init --------------------------------
int OnInit()
{
  Print("MT5_XAU_BTC_EA_v2 initializing...");
  DetectSymbols();

  // init seq structs
  infoXAU.state = SEQ_NONE; infoXAU.candle_time=0; infoXAU.sequence_end=0; infoXAU.candle_open=0; infoXAU.last_sl=0; infoXAU.last_tp=0; infoXAU.active=false;
  infoBTC = infoXAU;

  if(StringLen(SymXAU)>0) PrintFormat("Detected XAU: %s", SymXAU);
  if(StringLen(SymBTC)>0) PrintFormat("Detected BTC: %s", SymBTC);

  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  Print("MT5_XAU_BTC_EA_v2 stopped.");
}

//------------------------------ detect symbols ----------------------
void DetectSymbols()
{
  if(StringLen(SymXAU)>0 && StringLen(SymBTC)>0) return;
  int total = SymbolsTotal(false);
  for(int i=0;i<total;i++)
  {
    string s = SymbolName(i, false);
    string up = StringToUpper(s);
    if(StringLen(SymXAU)==0)
    {
      if(StringFind(up, "XAU")>=0 || StringFind(up, "GOLD")>=0)
      {
        if(SafeSymbolSelect(s)) { SymXAU = s; PrintFormat("Auto-detected XAU: %s", s); }
      }
    }
    if(StringLen(SymBTC)==0)
    {
      if(StringFind(up, "BTC")>=0 || StringFind(up, "XBT")>=0)
      {
        if(SafeSymbolSelect(s)) { SymBTC = s; PrintFormat("Auto-detected BTC: %s", s); }
      }
    }
    if(StringLen(SymXAU)>0 && StringLen(SymBTC)>0) break;
  }
}

//------------------------------ positions ---------------------------
bool HasPosition(const string sym, const ulong magic, ulong &ticket_out, long &type_out)
{
  ticket_out = 0; type_out = -1;
  int total = PositionsTotal();
  for(int i=0;i<total;i++)
  {
    ulong t = PositionGetTicket(i);
    if(t==0) continue;
    if(!PositionSelectByTicket(t)) continue;
    string ps = PositionGetString(POSITION_SYMBOL);
    if(ps != sym) continue;
    long pm = PositionGetInteger(POSITION_MAGIC);
    if((ulong)pm != magic) continue;
    ticket_out = t;
    type_out = (int)PositionGetInteger(POSITION_TYPE);
    return true;
  }
  return false;
}

//------------------------------ trade helpers -----------------------
bool PlaceBuy(const string sym, double lot, double sl, double tp)
{
  trade.SetExpertMagicNumber(InpMagicNumber);
  trade.SetDeviationInPoints(InpSlippage);
  double ask=0.0;
  if(!GetSymbolDouble(sym, SYMBOL_ASK, ask)) return false;
  for(int attempt=1; attempt<=InpRetryCount; attempt++)
  {
    if(trade.Buy(lot, sym, ask, sl, tp))
    {
      PrintFormat("Buy placed %s lot=%.2f price=%.8f SL=%.8f TP=%.8f", sym, lot, ask, sl, tp);
      return true;
    }
    int err = GetLastError(); PrintFormat("Buy attempt %d failed, error=%d", attempt, err); ResetLastError(); Sleep(InpRetryDelayMs);
  }
  return false;
}

bool PlaceSell(const string sym, double lot, double sl, double tp)
{
  trade.SetExpertMagicNumber(InpMagicNumber);
  trade.SetDeviationInPoints(InpSlippage);
  double bid=0.0;
  if(!GetSymbolDouble(sym, SYMBOL_BID, bid)) return false;
  for(int attempt=1; attempt<=InpRetryCount; attempt++)
  {
    if(trade.Sell(lot, sym, bid, sl, tp))
    {
      PrintFormat("Sell placed %s lot=%.2f price=%.8f SL=%.8f TP=%.8f", sym, lot, bid, sl, tp);
      return true;
    }
    int err = GetLastError(); PrintFormat("Sell attempt %d failed, error=%d", attempt, err); ResetLastError(); Sleep(InpRetryDelayMs);
  }
  return false;
}

//------------------------------ main tick ---------------------------
void OnTick()
{
  static uint tick=0; tick++;
  if(tick % 1500 == 0) DetectSymbols();

  if(InpEnableXAU && StringLen(SymXAU)>0) Process(SymXAU, infoXAU);
  if(InpEnableBTC && StringLen(SymBTC)>0) Process(SymBTC, infoBTC);
}

//------------------------------ process per symbol ------------------
void StartSequence(SeqInfo &info, SeqState state, const string sym)
{
  datetime t = (datetime)iTime(sym, PERIOD_M5, 0);
  if(t==0) return;
  info.state = state;
  info.candle_time = t;
  info.sequence_end = t + InpSequenceMinutes*60;
  info.candle_open = iOpen(sym, PERIOD_M5, 0);
  info.active = true;
  PrintFormat("Started sequence %d on %s until %s", state, sym, TimeToString(info.sequence_end, TIME_DATE|TIME_SECONDS));
}

void Process(const string sym, SeqInfo &info)
{
  // ensure selected
  if(SymbolInfoInteger(sym, SYMBOL_SELECT) == 0) SymbolSelect(sym,true);

  // spread check
  double spread_points = 0.0;
  if(!GetSymbolDouble(sym, SYMBOL_SPREAD, spread_points))
  {
    double ask=0.0,bid=0.0,pt=0.0;
    if(!GetSymbolDouble(sym,SYMBOL_ASK,ask) || !GetSymbolDouble(sym,SYMBOL_BID,bid) || !GetSymbolDouble(sym,SYMBOL_POINT,pt)) return;
    if(pt==0.0) return;
    spread_points = (ask-bid)/pt;
  }
  if(spread_points > InpMaxSpreadPoints) return; // skip if too wide

  datetime cur = (datetime)iTime(sym, PERIOD_M5, 0);
  datetime prev = (datetime)iTime(sym, PERIOD_M5, 1);
  if(cur==0 || prev==0) return;

  double open0 = iOpen(sym, PERIOD_M5, 0);
  double low0 = iLow(sym, PERIOD_M5, 0);
  double high0 = iHigh(sym, PERIOD_M5, 0);
  double open1 = iOpen(sym, PERIOD_M5, 1);
  double close1 = iClose(sym, PERIOD_M5, 1);
  double low1 = iLow(sym, PERIOD_M5, 1);

  double bid=0.0, ask=0.0, point=0.0;
  if(!GetSymbolDouble(sym,SYMBOL_BID,bid) || !GetSymbolDouble(sym,SYMBOL_ASK,ask) || !GetSymbolDouble(sym,SYMBOL_POINT,point)) return;

  double pip = Pip(sym); if(pip<=0) return;

  bool prevBull = (close1 > open1);
  bool movedBelowOpen = (bid < open0);
  bool touchedPrevLow = (low0 <= low1 + point*0.5);

  ulong pos_ticket = 0; long pos_type = -1;
  bool hasPos = HasPosition(sym, InpMagicNumber, pos_ticket, pos_type);

  // SELL immediate on touch/break of prev bullish low
  if(prevBull && movedBelowOpen && touchedPrevLow && !hasPos)
  {
    double sl = high0;
    double entry = bid;
    double tp = entry - InpTakeProfit;
    if(PlaceSell(sym, InpLotSize, sl, tp)) StartSequence(info, SEQ_SELL, sym);
  }

  // BUY when price moves 30 pips above open
  double buyTrigger = open0 + pip*30.0;
  if(ask >= buyTrigger && !hasPos)
  {
    double sl = low0;
    double entry = ask;
    double tp = entry + InpTakeProfit;
    if(PlaceBuy(sym, InpLotSize, sl, tp)) StartSequence(info, SEQ_BUY, sym);
  }

  // Continuous reopen while sequence active
  if(info.active)
  {
    if(TimeCurrent() > info.sequence_end || (datetime)iTime(sym, PERIOD_M5, 0) != info.candle_time)
    {
      info.active = false; info.state = SEQ_NONE; return;
    }
    // if last trade closed (no position), reopen same side
    hasPos = HasPosition(sym, InpMagicNumber, pos_ticket, pos_type);
    if(!hasPos)
    {
      if(info.state == SEQ_BUY)
      {
        double sl = iLow(sym, PERIOD_M5, 0);
        double curAsk=0.0; if(!GetSymbolDouble(sym,SYMBOL_ASK,curAsk)) return;
        double tp = curAsk + InpTakeProfit;
        if(PlaceBuy(sym, InpLotSize, sl, tp)) { info.last_sl = sl; info.last_tp = tp; }
      }
      else if(info.state == SEQ_SELL)
      {
        double sl = iHigh(sym, PERIOD_M5, 0);
        double curBid=0.0; if(!GetSymbolDouble(sym,SYMBOL_BID,curBid)) return;
        double tp = curBid - InpTakeProfit;
        if(PlaceSell(sym, InpLotSize, sl, tp)) { info.last_sl = sl; info.last_tp = tp; }
      }
    }
  }
}

//------------------------------ trade events -----------------------
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
  if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
  ulong deal = trans.deal; if(deal==0) return;
  long magic = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
  if((ulong)magic != InpMagicNumber) return;
  string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
  int entry = (int)HistoryDealGetInteger(deal, DEAL_ENTRY);
  double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
  if(entry == DEAL_ENTRY_OUT)
  {
    if(profit < 0)
    {
      // SL hit: start reverse sequence
      if(StringCompare(sym, SymXAU)==0) StartSequence(infoXAU, SEQ_BUY, SymXAU);
      else if(StringCompare(sym, SymBTC)==0) StartSequence(infoBTC, SEQ_BUY, SymBTC);
    }
    // TP handled by Process continuous reopen
  }
}

//+------------------------------------------------------------------+
