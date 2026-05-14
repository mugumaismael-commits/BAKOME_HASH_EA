//+------------------------------------------------------------------+
//|                                             bakome_hash_ea.mq5   |
//|                       BAKOME HASH - Neural Trend EA              |
//|                              Author: bakome                      |
//|                         Version: 2.0 (AI Enhanced)              |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, BAKOME-Hub"
#property link      "https://github.com/BAKOME-Hub"
#property version   "2.00"
#property description "Advanced Trend Following EA with ATR Risk Management"
#property description "EMA crossover + RSI + ATR trailing / break-even"
#property description "No martingale, no grid – prop firm ready"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Input parameters                                                |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double   RiskPercent           = 1.0;       // Risk per trade (%)
input double   MaxDailyLossPercent   = 5.0;       // Max daily loss (%)
input double   MaxDailyProfitPercent = 8.0;       // Daily profit target (%)
input int      MaxPositions          = 1;         // Max concurrent positions
input int      MaxDailyTrades        = 5;         // Max trades per day

input group "=== Strategy Parameters ==="
input int      FastEMA               = 50;
input int      SlowEMA               = 200;
input int      RSI_Period            = 14;
input double   RSI_Buy_Level         = 55.0;
input double   RSI_Sell_Level        = 45.0;
input bool     EnableBuy             = true;
input bool     EnableSell            = true;
input bool     UseATRStops           = true;      // Use ATR-based SL/TP instead of fixed points
input double   ATR_SL_Multiplier     = 1.5;
input double   ATR_TP_Multiplier     = 3.0;

input group "=== Position Management ==="
input bool     UseTrailingStop       = true;
input double   Trail_StartATR        = 1.0;
input double   Trail_StepATR         = 0.5;
input bool     UseBreakEven          = true;
input double   BE_TriggerATR         = 0.8;

input group "=== Filters ==="
input bool     UseSessionFilter      = true;
input int      StartHour             = 8;
input int      EndHour               = 20;
input bool     UseNewsFilter         = true;
input int      NewsBlockMinutesBefore= 30;
input int      NewsBlockMinutesAfter = 20;
input double   MaxSpreadPoints       = 50.0;

input group "=== Execution ==="
input int      SlippagePoints        = 10;
input int      OrderRetryCount       = 3;
input int      OrderRetryDelayMs     = 500;

input group "=== System ==="
input int      MagicNumber           = 20240517;

//+------------------------------------------------------------------+
//| Global variables                                                |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbol;
CAccountInfo   m_account;

int            m_fastEMAHandle;
int            m_slowEMAHandle;
int            m_rsiHandle;
int            m_atrHandle;

double         m_currentATR;
datetime       m_lastBarTime;
int            m_todayTrades;
double         m_dayStartBalance;
bool           m_initialized;
bool           m_tradingEnabled;

// Example news dates (user can modify)
datetime m_newsDates[] = {
   D'2026.06.07 13:30', // Example NFP
   D'2026.06.14 14:00'  // Example FOMC
};

//+------------------------------------------------------------------+
//| Helper: Get indicator value                                      |
//+------------------------------------------------------------------+
bool GetValueFromHandle(int handle, int shift, double &value)
{
   double buffer[1];
   if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0)
      return false;
   value = buffer[0];
   return true;
}

//+------------------------------------------------------------------+
//| Update ATR                                                      |
//+------------------------------------------------------------------+
void UpdateATR()
{
   double atr;
   if(GetValueFromHandle(m_atrHandle, 0, atr))
      m_currentATR = atr;
}

//+------------------------------------------------------------------+
//| Check daily limits                                              |
//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   if(m_todayTrades >= MaxDailyTrades) return true;
   double equity = m_account.Equity();
   double dailyPL = (equity - m_dayStartBalance) / m_dayStartBalance * 100.0;
   if(dailyPL <= -MaxDailyLossPercent)
   {
      Print("Daily loss limit reached: ", dailyPL, "%");
      return true;
   }
   if(dailyPL >= MaxDailyProfitPercent)
   {
      Print("Daily profit target reached: ", dailyPL, "%");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Reset daily stats (call at new day)                             |
//+------------------------------------------------------------------+
void ResetDailyStats()
{
   m_todayTrades = 0;
   m_dayStartBalance = m_account.Balance();
}

//+------------------------------------------------------------------+
//| Session filter                                                  |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   if(!UseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   return (hour >= StartHour && hour <= EndHour);
}

//+------------------------------------------------------------------+
//| News filter (simplified)                                        |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
   if(!UseNewsFilter) return false;
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(m_newsDates); i++)
   {
      datetime news = m_newsDates[i];
      if(now >= news - NewsBlockMinutesBefore * 60 &&
         now <= news + NewsBlockMinutesAfter * 60)
      {
         Print("News filter active: ", TimeToString(news));
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Spread filter                                                   |
//+------------------------------------------------------------------+
bool IsSpreadOk()
{
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime curBar = iTime(_Symbol, PERIOD_H1, 0);
   if(curBar != m_lastBarTime)
   {
      m_lastBarTime = curBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate position size based on risk and ATR                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints)
{
   double riskAmount = m_account.Balance() * RiskPercent / 100.0;
   double tickValue = m_symbol.TickValue();
   double tickSize  = m_symbol.TickSize();
   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0) return 0.01;
   double lot = riskAmount / ((slPoints * tickValue) / tickSize);
   double minLot = m_symbol.LotsMin();
   double maxLot = m_symbol.LotsMax();
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Execute Buy trade                                               |
//+------------------------------------------------------------------+
void ExecuteBuy(double price, double sl, double tp)
{
   double lot = 0;
   if(UseATRStops && m_currentATR > 0)
   {
      double slPoints = (price - sl) / m_symbol.Point();
      lot = CalculateLotSize(slPoints);
   }
   else
   {
      lot = 0.01; // fallback, but shouldn't happen
   }
   if(lot < m_symbol.LotsMin()) lot = m_symbol.LotsMin();

   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = lot;
   req.type = ORDER_TYPE_BUY;
   req.price = price;
   req.sl = sl;
   req.tp = tp;
   req.deviation = SlippagePoints;
   req.magic = MagicNumber;
   req.comment = "BAKOME HASH BUY";

   for(int attempt = 0; attempt < OrderRetryCount; attempt++)
   {
      if(OrderSend(req, res))
      {
         if(res.retcode == TRADE_RETCODE_DONE)
         {
            Print("BUY executed: ", lot, " @ ", price, " SL: ", sl, " TP: ", tp);
            m_todayTrades++;
            break;
         }
      }
      Sleep(OrderRetryDelayMs);
   }
}

void ExecuteSell(double price, double sl, double tp)
{
   double lot = 0;
   if(UseATRStops && m_currentATR > 0)
   {
      double slPoints = (sl - price) / m_symbol.Point();
      lot = CalculateLotSize(slPoints);
   }
   else lot = 0.01;
   if(lot < m_symbol.LotsMin()) lot = m_symbol.LotsMin();

   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = lot;
   req.type = ORDER_TYPE_SELL;
   req.price = price;
   req.sl = sl;
   req.tp = tp;
   req.deviation = SlippagePoints;
   req.magic = MagicNumber;
   req.comment = "BAKOME HASH SELL";

   for(int attempt = 0; attempt < OrderRetryCount; attempt++)
   {
      if(OrderSend(req, res))
      {
         if(res.retcode == TRADE_RETCODE_DONE)
         {
            Print("SELL executed: ", lot, " @ ", price, " SL: ", sl, " TP: ", tp);
            m_todayTrades++;
            break;
         }
      }
      Sleep(OrderRetryDelayMs);
   }
}

//+------------------------------------------------------------------+
//| Manage trailing stop and break-even                             |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Magic() != MagicNumber) continue;

      double profit = m_position.Profit();
      double atr = m_currentATR;
      if(atr <= 0) continue;

      // Break-even
      if(UseBreakEven && profit >= atr * BE_TriggerATR * m_position.Volume())
      {
         double openPrice = m_position.PriceOpen();
         if(m_position.StopLoss() != openPrice && m_position.StopLoss() != 0)
         {
            m_trade.PositionModify(m_position.Ticket(), openPrice, m_position.TakeProfit());
            Print("Break-even activated for ticket ", m_position.Ticket());
         }
      }

      // Trailing stop
      if(UseTrailingStop && profit >= atr * Trail_StartATR * m_position.Volume())
      {
         double newSL = 0;
         if(m_position.PositionType() == POSITION_TYPE_BUY)
            newSL = SymbolInfoDouble(_Symbol, SYMBOL_BID) - (atr * Trail_StepATR);
         else
            newSL = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + (atr * Trail_StepATR);

         double currentSL = m_position.StopLoss();
         if((m_position.PositionType() == POSITION_TYPE_BUY && newSL > currentSL) ||
            (m_position.PositionType() == POSITION_TYPE_SELL && newSL < currentSL) ||
            currentSL == 0)
         {
            m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
            Print("Trailing stop updated: ", newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if there is already a position                            |
//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == MagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Main signal logic                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!m_initialized) return;

   // Daily reset
   static datetime lastDay = 0;
   datetime now = TimeCurrent();
   if(lastDay == 0) lastDay = now;
   if(now - lastDay >= 86400)
   {
      ResetDailyStats();
      lastDay = now;
   }

   if(CheckDailyLimits())
   {
      m_tradingEnabled = false;
      return;
   }
   else m_tradingEnabled = true;

   if(!m_tradingEnabled) return;
   if(!IsTradingTime()) return;
   if(IsNewsTime()) return;
   if(!IsSpreadOk()) return;
   if(HasPosition() && MaxPositions <= 1) return;

   if(!IsNewBar()) return;

   UpdateATR();

   double fastEMA, slowEMA, rsi;
   if(!GetValueFromHandle(m_fastEMAHandle, 1, fastEMA) ||
      !GetValueFromHandle(m_slowEMAHandle, 1, slowEMA) ||
      !GetValueFromHandle(m_rsiHandle, 1, rsi))
      return;

   bool bullishTrend = fastEMA > slowEMA;
   bool bearishTrend = fastEMA < slowEMA;

   double ask = m_symbol.Ask();
   double bid = m_symbol.Bid();
   double price, sl, tp;

   if(EnableBuy && bullishTrend && rsi > RSI_Buy_Level)
   {
      price = ask;
      if(UseATRStops && m_currentATR > 0)
      {
         sl = price - (m_currentATR * ATR_SL_Multiplier);
         tp = price + (m_currentATR * ATR_TP_Multiplier);
      }
      else
      {
         sl = price - StopLossPoints * m_symbol.Point();
         tp = price + TakeProfitPoints * m_symbol.Point();
      }
      // normaliser
      sl = NormalizeDouble(sl, (int)m_symbol.Digits());
      tp = NormalizeDouble(tp, (int)m_symbol.Digits());
      ExecuteBuy(price, sl, tp);
   }
   else if(EnableSell && bearishTrend && rsi < RSI_Sell_Level)
   {
      price = bid;
      if(UseATRStops && m_currentATR > 0)
      {
         sl = price + (m_currentATR * ATR_SL_Multiplier);
         tp = price - (m_currentATR * ATR_TP_Multiplier);
      }
      else
      {
         sl = price + StopLossPoints * m_symbol.Point();
         tp = price - TakeProfitPoints * m_symbol.Point();
      }
      sl = NormalizeDouble(sl, (int)m_symbol.Digits());
      tp = NormalizeDouble(tp, (int)m_symbol.Digits());
      ExecuteSell(price, sl, tp);
   }

   ManagePositions();
}

//+------------------------------------------------------------------+
//| Initialization                                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   m_symbol.Name(_Symbol);
   m_symbol.Refresh();
   m_trade.SetExpertMagicNumber(MagicNumber);

   m_fastEMAHandle = iMA(_Symbol, PERIOD_H1, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   m_slowEMAHandle = iMA(_Symbol, PERIOD_H1, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   m_rsiHandle     = iRSI(_Symbol, PERIOD_H1, RSI_Period, PRICE_CLOSE);
   m_atrHandle     = iATR(_Symbol, PERIOD_H1, 14);

   if(m_fastEMAHandle == INVALID_HANDLE || m_slowEMAHandle == INVALID_HANDLE ||
      m_rsiHandle == INVALID_HANDLE     || m_atrHandle == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return INIT_FAILED;
   }

   m_dayStartBalance = m_account.Balance();
   m_todayTrades = 0;
   m_initialized = true;
   m_tradingEnabled = true;

   Print("BAKOME HASH EA v2.0 initialized. Magic: ", MagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(m_fastEMAHandle);
   IndicatorRelease(m_slowEMAHandle);
   IndicatorRelease(m_rsiHandle);
   IndicatorRelease(m_atrHandle);
   Print("BAKOME HASH EA removed. Reason: ", reason);
}
//+------------------------------------------------------------------+
