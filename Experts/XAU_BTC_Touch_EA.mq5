//+------------------------------------------------------------------+
//|                                     XAU_BTC_Touch_EA.mq5         |
//|  Auto-detects XAU/BTC symbols, monitors M5 on every tick,        |
//|  immediate touch entries, continuous sequences, reverse logic.   |
//+------------------------------------------------------------------+
#property copyright "Generated"
#property version   "1.02"
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
   datetime candle_time;       // M5 candle start time that started the sequence
   datetime sequence_end;      // candle_time + sequence duration
   ulong    last_deal_ticket;  // last deal ticket opened (not strictly required)
   double   candle_open;       // open price of the candle that started sequence
   double   last_sl;
   double   last_tp;
   bool     active;
};

Sequence stXAU, stBTC;

//+------------------------------------------------------------------+
//| Helper: pip conversion (30 pips uses this)                       |
//+------------------------------------------------------------------+
double PipSize(const string symbol)
{
   double pt=0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_POINT, pt)) return(0.0);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits > 3) return pt * 10.0; // pip = 10 * point for 4/5-digit style
   return pt;
}

//+------------------------------------------------------------------+
int OnInit()
{
   Print("XAU_BTC_Touch_EA initializing...");
   DetectSymbols();

   // initialize sequences (assign fields explicitly)
   stXAU.state = SEQ_IDLE; stXAU.candle_time = 0; stXAU.sequence_end = 0; stXAU.last_deal_ticket = 0; stXAU.candle_open = 0.0; stXAU.last_sl = 0.0; stXAU.last_tp = 0.0; stXAU.active = false;
   stBTC.state = SEQ_IDLE; stBTC.candle_time = 0; stBTC.sequence_end = 0; stBTC.last_deal_ticket = 0; stBTC.candle_open = 0.0; stBTC.last_sl = 0.0; stBTC.last_tp = 0.0; stBTC.active = false;

   if(StringLen(symXAU)>0) PrintFormat("Detected XAU symbol: %s", symXAU);
   if(StringLen(symBTC)>0) PrintFormat("Detected BTC symbol: %s", symBTC);
   if(StringLen(symXAU)==0 && StringLen(symBTC)==0)
      Print("WARNING: No XAU or BTC symbols detected at init; EA will keep scanning until symbols are available.");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("XAU_BTC_Touch_EA stopped.");
}

//+------------------------------------------------------------------+
//| Detect broker symbol names for XAU and BTC                       |
//+------------------------------------------------------------------+
void DetectSymbols()
{
   // If both found, nothing to do
   if(StringLen(symXAU)>0 && StringLen(symBTC)>0) return;

   int total = SymbolsTotal(false);
   for(int i=0;i<total;i++)
   {
      string s = SymbolName(i,false);
      string up = StringToUpper(s);
      // detect XAU/GOLD
      if(StringLen(symXAU)==0)
      {
         if(StringFind(up,"XAU")>=0 || StringFind(up,"GOLD")>=0)
         {
            // ensure symbol is selected for market info
            bool sel = SymbolSelect(s,true);
            long sel_flag = SymbolInfoInteger(s,SYMBOL_SELECT);
            if(sel || (sel_flag != 0))
            {
               symXAU = s;
               PrintFormat("Auto-detected XAU: %s", s);
            }
         }
      }
      // detect BTC
      if(StringLen(symBTC)==0)
      {
         if(StringFind(up,"BTC")>=0 || StringFind(up,"XBT")>=0)
         {
            bool sel2 = SymbolSelect(s,true);
            long sel2_flag = SymbolInfoInteger(s,SYMBOL_SELECT);
            if(sel2 || (sel2_flag != 0))
            {
               symBTC = s;
               PrintFormat("Auto-detected BTC: %s", s);
            }
         }
      }
      if(StringLen(symXAU)>0 && StringLen(symBTC)>0) break;
   }
}

//+------------------------------------------------------------------+
//| Check whether there's already an open position for symbol+magic  |
//+------------------------------------------------------------------+
bool HasOpenPosition(const string symbol, const ulong magic, ulong &position_ticket, long &position_type)
{
   position_ticket = 0;
   position_type = -1;
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

//+------------------------------------------------------------------+
void OnTick()
{
   static uint tickCount = 0;
   tickCount++;
   if(tickCount % 1500 == 0) DetectSymbols(); // periodic re-detect

   if(InpEnableXAU && StringLen(symXAU) > 0)
      ProcessSymbol(symXAU, stXAU);

   if(InpEnableBTC && StringLen(symBTC) > 0)
      ProcessSymbol(symBTC, stBTC);
}

//+------------------------------------------------------------------+
//| OnTradeTransaction: detect deals/closures for reverse logic      |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   // Reply only to DEAL_ADD transactions
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal_ticket = trans.deal;
      if(deal_ticket == 0) return;
      long deal_magic = (long)HistoryDealGetInteger((ulong)deal_ticket, DEAL_MAGIC);
      if((ulong)deal_magic != InpMagicNumber) return; // ignore other EA trades

      string d_symbol = HistoryDealGetString((ulong)deal_ticket, DEAL_SYMBOL);
      int    d_entry  = (int)HistoryDealGetInteger((ulong)deal_ticket, DEAL_ENTRY); // DEAL_ENTRY_IN/OUT
      double d_profit = HistoryDealGetDouble((ulong)deal_ticket, DEAL_PROFIT);
      int    d_type   = (int)HistoryDealGetInteger((ulong)deal_ticket, DEAL_TYPE);  // BUY/SELL

      PrintFormat("OnTradeTransaction: deal=%u sym=%s entry=%d type=%d profit=%.8f", deal_ticket, d_symbol, d_entry, d_type, d_profit);

      // We react to exit deals (DEAL_ENTRY_OUT). If negative profit -> SL, positive -> TP
      if(d_entry == DEAL_ENTRY_OUT)
      {
         if(d_profit < 0)
         {
            // Stop Loss was hit -> reverse
            PrintFormat("Detected exit with LOSS on %s. Triggering reverse sequence.", d_symbol);
            if(StringCompare(d_symbol, symXAU) == 0)
               TriggerReverseSequence(symXAU, stXAU, SEQ_BUY);
            else if(StringCompare(d_symbol, symBTC) == 0)
               TriggerReverseSequence(symBTC, stBTC, SEQ_BUY);
         }
         else if(d_profit > 0)
         {
            // TP -> continuous same-side reopen handled in ProcessSymbol while sequence active
            PrintFormat("Detected exit with PROFIT on %s. Continuous reopen possible if sequence active.", d_symbol);
         }
      }
   }
}

//+------------------------------------------------------------------+
void TriggerReverseSequence(const string symbol, Sequence &seq, SeqState startState)
{
   datetime curM5 = (datetime)iTime(symbol, PERIOD_M5, 0);
   if(curM5 == 0)
   {
      PrintFormat("Unable to trigger reverse sequence: no M5 data for %s", symbol);
      return;
   }
   double open0 = iOpen(symbol, PERIOD_M5, 0);
   seq.state = startState;
   seq.candle_time = curM5;
   seq.sequence_end = curM5 + InpSequenceMinutes * 60;
   seq.candle_open = open0;
   seq.active = true;
   seq.last_deal_ticket = 0;
   PrintFormat("Reverse sequence started on %s state=%d until %s", symbol, seq.state, TimeToString(seq.sequence_end, TIME_DATE|TIME_SECONDS));
}

//+------------------------------------------------------------------+
void ProcessSymbol(const string symbol, Sequence &seq)
{
   long selected = SymbolInfoInteger(symbol, SYMBOL_SELECT);
   if(selected == 0)
      SymbolSelect(symbol, true);

   // spread check (in points)
   double spread = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_SPREAD, spread))
   {
      double ask = 0.0, bid = 0.0, sym_point = 0.0;
      if(!SymbolInfoDouble(symbol, SYMBOL_ASK, ask) || !SymbolInfoDouble(symbol, SYMBOL_BID, bid) || !SymbolInfoDouble(symbol, SYMBOL_POINT, sym_point))
         return;
      spread = (ask - bid) / sym_point;
   }
   if(spread > InpMaxSpreadPoints)
   {
      // skip opening but continue monitoring
   }

   datetime curM5 = (datetime)iTime(symbol, PERIOD_M5, 0);
   datetime prevM5 = (datetime)iTime(symbol, PERIOD_M5, 1);
   if(curM5 == 0 || prevM5 == 0) return;

   double open0 = iOpen(symbol, PERIOD_M5, 0);
   double low0  = iLow(symbol, PERIOD_M5, 0);
   double high0 = iHigh(symbol, PERIOD_M5, 0);
   double open1 = iOpen(symbol, PERIOD_M5, 1);
   double close1= iClose(symbol, PERIOD_M5, 1);
   double low1  = iLow(symbol, PERIOD_M5, 1);
   double high1 = iHigh(symbol, PERIOD_M5, 1);

   double bid = 0.0, ask = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_BID, bid) || !SymbolInfoDouble(symbol, SYMBOL_ASK, ask)) return;

   double pip = PipSize(symbol);
   if(pip<=0) return;

   // SELL detection: previous candle bullish, current moved down and touched/broke previous low
   bool prevBullish = (close1 > open1);
   bool currentMovedBelowOpen = (bid < open0);
   double sym_point=0.0; SymbolInfoDouble(symbol, SYMBOL_POINT, sym_point);
   bool touchedPrevLow = (low0 <= low1 + sym_point*0.5);

   ulong pos_ticket = 0; long pos_type = -1;
   bool hasPos = HasOpenPosition(symbol, InpMagicNumber, pos_ticket, pos_type);

   if(prevBullish && currentMovedBelowOpen && touchedPrevLow)
   {
      if(!hasPos)
      {
         double sl = high0;
         double entry_price = bid;
         double tp = entry_price - InpTakeProfit;
         if(ExecuteSell(symbol, InpLotSize, sl, tp))
         {
            seq.state = SEQ_SELL;
            seq.candle_time = curM5;
            seq.sequence_end = curM5 + InpSequenceMinutes * 60;
            seq.candle_open = open0;
            seq.last_sl = sl;
            seq.last_tp = tp;
            seq.active = true;
            PrintFormat("SELL sequence started on %s candle_time=%s end=%s SL=%.8f TP=%.8f", symbol, TimeToString(seq.candle_time), TimeToString(seq.sequence_end), sl, tp);
         }
      }
   }

   // BUY detection: when price moves 30 pips above candle open
   double buyTriggerPrice = open0 + pip * 30.0;
   bool buyCondition = (ask >= buyTriggerPrice);

   if(buyCondition && !hasPos)
   {
      double sl = low0;
      double entry_price = ask;
      double tp = entry_price + InpTakeProfit;
      if(ExecuteBuy(symbol, InpLotSize, sl, tp))
      {
         seq.state = SEQ_BUY;
         seq.candle_time = curM5;
         seq.sequence_end = curM5 + InpSequenceMinutes * 60;
         seq.candle_open = open0;
         seq.last_sl = sl;
         seq.last_tp = tp;
         seq.active = true;
         PrintFormat("BUY sequence started on %s candle_time=%s end=%s SL=%.8f TP=%.8f", symbol, TimeToString(seq.candle_time), TimeToString(seq.sequence_end), sl, tp);
      }
   }

   // Continuous reopen while sequence active
   if(seq.active)
   {
      if(TimeCurrent() > seq.sequence_end || iTime(symbol, PERIOD_M5, 0) != seq.candle_time)
      {
         PrintFormat("Sequence ended for %s (state=%d). Now idle.", symbol, seq.state);
         seq.active = false;
         seq.state = SEQ_IDLE;
      }
      else
      {
         // if no position open, reopen same-side
         hasPos = HasOpenPosition(symbol, InpMagicNumber, pos_ticket, pos_type);
         if(!hasPos)
         {
            if(seq.state == SEQ_BUY)
            {
               double sl = iLow(symbol, PERIOD_M5, 0);
               double entry_price = 0.0;
               if(!SymbolInfoDouble(symbol, SYMBOL_ASK, entry_price)) return;
               double tp = entry_price + InpTakeProfit;
               if(ExecuteBuy(symbol, InpLotSize, sl, tp))
               {
                  seq.last_sl = sl; seq.last_tp = tp;
                  PrintFormat("Reopened BUY during sequence on %s SL=%.8f TP=%.8f", symbol, sl, tp);
               }
            }
            else if(seq.state == SEQ_SELL)
            {
               double sl = iHigh(symbol, PERIOD_M5, 0);
               double entry_price = 0.0;
               if(!SymbolInfoDouble(symbol, SYMBOL_BID, entry_price)) return;
               double tp = entry_price - InpTakeProfit;
               if(ExecuteSell(symbol, InpLotSize, sl, tp))
               {
                  seq.last_sl = sl; seq.last_tp = tp;
                  PrintFormat("Reopened SELL during sequence on %s SL=%.8f TP=%.8f", symbol, sl, tp);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
bool ExecuteBuy(const string symbol, double lot, double sl, double tp)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   bool ok = false;
   for(int attempt=1; attempt<=InpRetryCount; attempt++)
   {
      double ask=0.0;
      if(!SymbolInfoDouble(symbol,SYMBOL_ASK,ask)) return false;
      ok = trade.Buy(lot, symbol, ask, sl, tp, NULL);
      if(ok)
      {
         PrintFormat("Buy order placed on %s lot=%.2f price=%.8f sl=%.8f tp=%.8f attempt=%d", symbol, lot, ask, sl, tp, attempt);
         return true;
      }
      else
      {
         int rc = GetLastError();
         PrintFormat("Buy attempt %d failed on %s, error=%d", attempt, symbol, rc);
         ResetLastError();
         Sleep(InpRetryDelayMs);
      }
   }
   PrintFormat("Buy failed after %d attempts on %s", InpRetryCount, symbol);
   return false;
}

//+------------------------------------------------------------------+
bool ExecuteSell(const string symbol, double lot, double sl, double tp)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   bool ok = false;
   for(int attempt=1; attempt<=InpRetryCount; attempt++)
   {
      double bid=0.0;
      if(!SymbolInfoDouble(symbol,SYMBOL_BID,bid)) return false;
      ok = trade.Sell(lot, symbol, bid, sl, tp, NULL);
      if(ok)
      {
         PrintFormat("Sell order placed on %s lot=%.2f price=%.8f sl=%.8f tp=%.8f attempt=%d", symbol, lot, bid, sl, tp, attempt);
         return true;
      }
      else
      {
         int rc = GetLastError();
         PrintFormat("Sell attempt %d failed on %s, error=%d", attempt, symbol, rc);
         ResetLastError();
         Sleep(InpRetryDelayMs);
      }
   }
   PrintFormat("Sell failed after %d attempts on %s", InpRetryCount, symbol);
   return false;
}
