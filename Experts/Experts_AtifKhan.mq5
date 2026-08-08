//+------------------------------------------------------------------+
//|                                     Experts_AtifKhan.mq5         |
//|  MT5 Expert Advisor for XAU/BTC touch and continuous sequence    |
//+------------------------------------------------------------------+
#property copyright "Generated"
#property version   "1.04"
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

// Detected symbol names
string symXAU = "";
string symBTC = "";

// Sequence state
enum SeqState { SEQ_IDLE=0, SEQ_SELL, SEQ_BUY };

struct Sequence
{
   SeqState state;
   datetime candle_time;
   datetime sequence_end;
   ulong    last_deal_ticket;
   double   candle_open;
   double   last_sl;
   double   last_tp;
   bool     active;
};

Sequence stXAU, stBTC;

// Helper: pip conversion
double PipSize(const string symbol)
{
   double pt=0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_POINT, pt)) return(0.0);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits > 3) return pt * 10.0;
   return pt;
}

int OnInit()
{
   Print("Experts_AtifKhan EA initializing...");
   DetectSymbols();

   // explicit init
   stXAU.state = SEQ_IDLE; stXAU.candle_time = 0; stXAU.sequence_end = 0; stXAU.last_deal_ticket = 0; stXAU.candle_open = 0.0; stXAU.last_sl = 0.0; stXAU.last_tp = 0.0; stXAU.active = false;
   stBTC.state = SEQ_IDLE; stBTC.candle_time = 0; stBTC.sequence_end = 0; stBTC.last_deal_ticket = 0; stBTC.candle_open = 0.0; stBTC.last_sl = 0.0; stBTC.last_tp = 0.0; stBTC.active = false;

   if(StringLen(symXAU)>0) PrintFormat("Detected XAU symbol: %s", symXAU);
   if(StringLen(symBTC)>0) PrintFormat("Detected BTC symbol: %s", symBTC);
   if(StringLen(symXAU)==0 && StringLen(symBTC)==0)
      Print("WARNING: No XAU or BTC symbols detected at init; EA will keep scanning until symbols are available.");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("Experts_AtifKhan EA stopped.");
}

void DetectSymbols()
{
   if(StringLen(symXAU)>0 && StringLen(symBTC)>0) return;
   int total = SymbolsTotal(false);
   for(int i=0;i<total;i++)
   {
      string s = SymbolName(i,false);
      string up = StringToUpper(s);
      if(StringLen(symXAU)==0)
      {
         if(StringFind(up,"XAU")>=0 || StringFind(up,"GOLD")>=0)
         {
            bool sel = SymbolSelect(s,true);
            long sel_flag = SymbolInfoInteger(s,SYMBOL_SELECT);
            if(sel || (sel_flag != 0)) { symXAU = s; PrintFormat("Auto-detected XAU: %s", s); }
         }
      }
      if(StringLen(symBTC)==0)
      {
         if(StringFind(up,"BTC")>=0 || StringFind(up,"XBT")>=0)
         {
            bool sel2 = SymbolSelect(s,true);
            long sel2_flag = SymbolInfoInteger(s,SYMBOL_SELECT);
            if(sel2 || (sel2_flag != 0)) { symBTC = s; PrintFormat("Auto-detected BTC: %s", s); }
         }
      }
      if(StringLen(symXAU)>0 && StringLen(symBTC)>0) break;
   }
}

bool HasOpenPosition(const string symbol, const ulong magic, ulong &position_ticket, long &position_type)
{
   position_ticket = 0; position_type = -1;
   int total = PositionsTotal();
   for(int idx=0; idx<total; idx++)
   {
      ulong ticket = PositionGetTicket(idx);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string psym = PositionGetString(POSITION_SYMBOL);
      if(psym != symbol) continue;
      long pmag = PositionGetInteger(POSITION_MAGIC);
      if((ulong)pmag != magic) continue;
      position_ticket = ticket;
      position_type = (int)PositionGetInteger(POSITION_TYPE);
      return true;
   }
   return false;
}

void OnTick()
{
   static uint tickCount = 0; tickCount++;
   if(tickCount % 1500 == 0) DetectSymbols();
   if(InpEnableXAU && StringLen(symXAU)>0) ProcessSymbol(symXAU, stXAU);
   if(InpEnableBTC && StringLen(symBTC)>0) ProcessSymbol(symBTC, stBTC);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong deal_ticket = trans.deal; if(deal_ticket==0) return;
   long deal_magic = (long)HistoryDealGetInteger((ulong)deal_ticket, DEAL_MAGIC);
   if((ulong)deal_magic != InpMagicNumber) return;
   string d_symbol = HistoryDealGetString((ulong)deal_ticket, DEAL_SYMBOL);
   int d_entry = (int)HistoryDealGetInteger((ulong)deal_ticket, DEAL_ENTRY);
   double d_profit = HistoryDealGetDouble((ulong)deal_ticket, DEAL_PROFIT);
   if(d_entry == DEAL_ENTRY_OUT)
   {
      if(d_profit < 0)
      {
         PrintFormat("Detected exit with LOSS on %s. Triggering reverse sequence.", d_symbol);
         if(StringCompare(d_symbol, symXAU) == 0) TriggerReverseSequence(symXAU, stXAU, SEQ_BUY);
         else if(StringCompare(d_symbol, symBTC) == 0) TriggerReverseSequence(symBTC, stBTC, SEQ_BUY);
      }
      else if(d_profit > 0)
         PrintFormat("Detected exit with PROFIT on %s. Continuous reopen possible if sequence active.", d_symbol);
   }
}

void TriggerReverseSequence(const string symbol, Sequence &seq, SeqState startState)
{
   datetime curM5 = (datetime)iTime(symbol, PERIOD_M5, 0);
   if(curM5==0) { PrintFormat("Unable to trigger reverse sequence: no M5 data for %s", symbol); return; }
   double open0 = iOpen(symbol, PERIOD_M5, 0);
   seq.state = startState; seq.candle_time = curM5; seq.sequence_end = curM5 + InpSequenceMinutes*60; seq.candle_open = open0; seq.active = true; seq.last_deal_ticket = 0;
   PrintFormat("Reverse sequence started on %s state=%d until %s", symbol, seq.state, TimeToString(seq.sequence_end, TIME_DATE|TIME_SECONDS));
}

void ProcessSymbol(const string symbol, Sequence &seq)
{
   long sel = SymbolInfoInteger(symbol, SYMBOL_SELECT);
   if(sel==0) SymbolSelect(symbol,true);

   double spread=0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_SPREAD, spread))
   {
      double ask=0.0, bid=0.0, sym_point=0.0;
      if(!SymbolInfoDouble(symbol,SYMBOL_ASK,ask) || !SymbolInfoDouble(symbol,SYMBOL_BID,bid) || !SymbolInfoDouble(symbol,SYMBOL_POINT,sym_point)) return;
      spread = (ask-bid)/sym_point;
   }
   if(spread > InpMaxSpreadPoints) { /*skip*/ }

   datetime curM5=(datetime)iTime(symbol,PERIOD_M5,0), prevM5=(datetime)iTime(symbol,PERIOD_M5,1);
   if(curM5==0||prevM5==0) return;

   double open0=iOpen(symbol,PERIOD_M5,0), low0=iLow(symbol,PERIOD_M5,0), high0=iHigh(symbol,PERIOD_M5,0);
   double open1=iOpen(symbol,PERIOD_M5,1), close1=iClose(symbol,PERIOD_M5,1), low1=iLow(symbol,PERIOD_M5,1);

   double bid=0.0, ask=0.0; if(!SymbolInfoDouble(symbol,SYMBOL_BID,bid)||!SymbolInfoDouble(symbol,SYMBOL_ASK,ask)) return;
   double pip = PipSize(symbol); if(pip<=0) return;

   bool prevBullish = (close1>open1); bool currentMovedBelowOpen = (bid<open0);
   double sym_point=0.0; SymbolInfoDouble(symbol,SYMBOL_POINT,sym_point);
   bool touchedPrevLow = (low0 <= low1 + sym_point*0.5);

   ulong pos_ticket=0; long pos_type=-1; bool hasPos = false;
   hasPos = HasOpenPosition(symbol, InpMagicNumber, pos_ticket, pos_type);

   if(prevBullish && currentMovedBelowOpen && touchedPrevLow)
   {
      if(!hasPos)
      {
         double sl=high0; double entry_price=bid; double tp = entry_price - InpTakeProfit;
         if(ExecuteSell(symbol, InpLotSize, sl, tp))
         {
            seq.state=SEQ_SELL; seq.candle_time=curM5; seq.sequence_end=curM5+InpSequenceMinutes*60; seq.candle_open=open0; seq.last_sl=sl; seq.last_tp=tp; seq.active=true;
            PrintFormat("SELL sequence started on %s",symbol);
         }
      }
   }

   double buyTriggerPrice = open0 + pip*30.0; bool buyCondition = (ask >= buyTriggerPrice);
   if(buyCondition && !hasPos)
   {
      double sl=low0; double entry_price=ask; double tp = entry_price + InpTakeProfit;
      if(ExecuteBuy(symbol, InpLotSize, sl, tp))
      {
         seq.state=SEQ_BUY; seq.candle_time=curM5; seq.sequence_end=curM5+InpSequenceMinutes*60; seq.candle_open=open0; seq.last_sl=sl; seq.last_tp=tp; seq.active=true;
         PrintFormat("BUY sequence started on %s",symbol);
      }
   }

   if(seq.active)
   {
      if(TimeCurrent() > seq.sequence_end || iTime(symbol,PERIOD_M5,0) != seq.candle_time) { seq.active=false; seq.state=SEQ_IDLE; }
      else
      {
         hasPos = HasOpenPosition(symbol, InpMagicNumber, pos_ticket, pos_type);
         if(!hasPos)
         {
            if(seq.state==SEQ_BUY)
            {
               double sl=iLow(symbol,PERIOD_M5,0); double entry_price=0.0; if(!SymbolInfoDouble(symbol,SYMBOL_ASK,entry_price)) return; double tp = entry_price + InpTakeProfit;
               if(ExecuteBuy(symbol, InpLotSize, sl, tp)) { seq.last_sl=sl; seq.last_tp=tp; PrintFormat("Reopened BUY on %s",symbol); }
            }
            else if(seq.state==SEQ_SELL)
            {
               double sl=iHigh(symbol,PERIOD_M5,0); double entry_price=0.0; if(!SymbolInfoDouble(symbol,SYMBOL_BID,entry_price)) return; double tp = entry_price - InpTakeProfit;
               if(ExecuteSell(symbol, InpLotSize, sl, tp)) { seq.last_sl=sl; seq.last_tp=tp; PrintFormat("Reopened SELL on %s",symbol); }
            }
         }
      }
   }
}

bool ExecuteBuy(const string symbol, double lot, double sl, double tp)
{
   trade.SetExpertMagicNumber(InpMagicNumber); trade.SetDeviationInPoints(InpSlippage);
   for(int attempt=1; attempt<=InpRetryCount; attempt++)
   {
      double ask=0.0; if(!SymbolInfoDouble(symbol,SYMBOL_ASK,ask)) return false;
      if(trade.Buy(lot, symbol, ask, sl, tp, NULL)) { PrintFormat("Buy placed %s",symbol); return true; }
      int rc=GetLastError(); PrintFormat("Buy attempt %d failed on %s error=%d", attempt, symbol, rc); ResetLastError(); Sleep(InpRetryDelayMs);
   }
   PrintFormat("Buy failed after %d attempts on %s", InpRetryCount, symbol); return false;
}

bool ExecuteSell(const string symbol, double lot, double sl, double tp)
{
   trade.SetExpertMagicNumber(InpMagicNumber); trade.SetDeviationInPoints(InpSlippage);
   for(int attempt=1; attempt<=InpRetryCount; attempt++)
   {
      double bid=0.0; if(!SymbolInfoDouble(symbol,SYMBOL_BID,bid)) return false;
      if(trade.Sell(lot, symbol, bid, sl, tp, NULL)) { PrintFormat("Sell placed %s",symbol); return true; }
      int rc=GetLastError(); PrintFormat("Sell attempt %d failed on %s error=%d", attempt, symbol, rc); ResetLastError(); Sleep(InpRetryDelayMs);
   }
   PrintFormat("Sell failed after %d attempts on %s", InpRetryCount, symbol); return false;
}
