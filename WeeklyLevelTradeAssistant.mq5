//+------------------------------------------------------------------+
//|                                    WeeklyLevelTradeAssistant.mq5 |
//+------------------------------------------------------------------+
#property version   "1.01"

#include <Trade/Trade.mqh>
CTrade trade;

//----------------------------------------------------
// Inputs
//----------------------------------------------------
input double DepositLotPer1000            = 0.01;
input double MaxMarginUsagePercent        = 25.0;
input double MaxLotIncreasePercent        = 20.0;
input bool   OnePositionPerSymbol         = true;

//----------------------------------------------------
// Button names
//----------------------------------------------------
string BTN_SELL_BASE      = "WLTA_BTN_SELL";
string BTN_AUTO_SELL_BASE = "WLTA_BTN_AUTO_SELL";
string BTN_AUTO_BUY_BASE  = "WLTA_BTN_AUTO_BUY";

string BTN_SELL;
string BTN_AUTO_SELL;
string BTN_AUTO_BUY;

//----------------------------------------------------
// Weekly line prefixes
//----------------------------------------------------
string W1_PREFIX_1 = "WLTA_W1_LAST_";
string W1_PREFIX_2 = "WLTA_W1_PREV_";

//----------------------------------------------------
// Utility functions
//----------------------------------------------------
string LastLotKey(string symbol)
{
   return "WLTA_LAST_LOT_" + symbol;
}

double NormalizeVolumeBySymbol(string symbol, double volume)
{
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0)
      lotStep = 0.01;

   volume = MathMax(minLot, MathMin(maxLot, volume));
   volume = MathFloor(volume / lotStep) * lotStep;

   int volDigits = 2;
   if(lotStep == 1.0)         volDigits = 0;
   else if(lotStep == 0.1)    volDigits = 1;
   else if(lotStep == 0.01)   volDigits = 2;
   else if(lotStep == 0.001)  volDigits = 3;

   return NormalizeDouble(volume, volDigits);
}

bool SymbolHasOpenPosition(string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol)
         return true;
   }
   return false;
}

double CalculateMaxVolumeForMargin(string symbol, ENUM_ORDER_TYPE orderType, double maxMarginMoney)
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double price = (orderType == ORDER_TYPE_BUY) ? ask : bid;

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0 || maxLot <= 0.0 || lotStep <= 0.0)
      return 0.0;

   double bestLot = 0.0;

   for(double lot = minLot; lot <= maxLot + (lotStep / 2.0); lot += lotStep)
   {
      double margin = 0.0;
      double normLot = NormalizeVolumeBySymbol(symbol, lot);

      if(!OrderCalcMargin(orderType, symbol, normLot, price, margin))
         continue;

      if(margin <= maxMarginMoney)
         bestLot = normLot;
      else
         break;
   }

   return bestLot;
}

int GetWeeklyLevels(string symbol, double &levels[])
{
   ArrayResize(levels, 10);

   double high1 = iHigh(symbol, PERIOD_W1, 1);
   double low1  = iLow(symbol, PERIOD_W1, 1);

   double high2 = iHigh(symbol, PERIOD_W1, 2);
   double low2  = iLow(symbol, PERIOD_W1, 2);

   if(high1 == 0.0 || low1 == 0.0 || high2 == 0.0 || low2 == 0.0)
      return 0;

   double mid1   = (high1 + low1) / 2.0;
   double extUp1 = high1 + (high1 - mid1);
   double extDn1 = low1  - (mid1 - low1);

   double mid2   = (high2 + low2) / 2.0;
   double extUp2 = high2 + (high2 - mid2);
   double extDn2 = low2  - (mid2 - low2);

   levels[0] = high1;
   levels[1] = low1;
   levels[2] = mid1;
   levels[3] = extUp1;
   levels[4] = extDn1;

   levels[5] = high2;
   levels[6] = low2;
   levels[7] = mid2;
   levels[8] = extUp2;
   levels[9] = extDn2;

   return 10;
}

bool FindNearestBelow(string symbol, double referencePrice, double &level)
{
   double levels[];
   int count = GetWeeklyLevels(symbol, levels);
   if(count <= 0)
      return false;

   double bestDistance = DBL_MAX;
   bool found = false;

   for(int i = 0; i < count; i++)
   {
      if(levels[i] >= referencePrice)
         continue;

      double dist = referencePrice - levels[i];
      if(dist < bestDistance)
      {
         bestDistance = dist;
         level = levels[i];
         found = true;
      }
   }

   return found;
}

bool FindNearestAbove(string symbol, double referencePrice, double &level)
{
   double levels[];
   int count = GetWeeklyLevels(symbol, levels);
   if(count <= 0)
      return false;

   double bestDistance = DBL_MAX;
   bool found = false;

   for(int i = 0; i < count; i++)
   {
      if(levels[i] <= referencePrice)
         continue;

      double dist = levels[i] - referencePrice;
      if(dist < bestDistance)
      {
         bestDistance = dist;
         level = levels[i];
         found = true;
      }
   }

   return found;
}

bool BuildWeeklySLTP(string symbol, ENUM_POSITION_TYPE posType, double entryPrice, double &slPrice, double &tpPrice)
{
   slPrice = 0.0;
   tpPrice = 0.0;

   if(posType == POSITION_TYPE_BUY)
   {
      if(!FindNearestBelow(symbol, entryPrice, slPrice))
         return false;
      if(!FindNearestAbove(symbol, entryPrice, tpPrice))
         return false;
   }
   else
   {
      if(!FindNearestAbove(symbol, entryPrice, slPrice))
         return false;
      if(!FindNearestBelow(symbol, entryPrice, tpPrice))
         return false;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   return (slPrice > 0.0 && tpPrice > 0.0);
}

double CalculateManagedLot(string symbol, bool isBuy)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double baseLot = (balance / 1000.0) * DepositLotPer1000;
   baseLot = NormalizeVolumeBySymbol(symbol, baseLot);

   ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double maxMarginMoney = AccountInfoDouble(ACCOUNT_EQUITY) * (MaxMarginUsagePercent / 100.0);
   double marginLot = CalculateMaxVolumeForMargin(symbol, orderType, maxMarginMoney);

   if(marginLot <= 0.0)
      return 0.0;

   double cappedLot = MathMin(baseLot, marginLot);

   string key = LastLotKey(symbol);
   if(GlobalVariableCheck(key))
   {
      double previousLot = GlobalVariableGet(key);
      if(previousLot > 0.0)
      {
         double maxGrowthLot = previousLot * (1.0 + (MaxLotIncreasePercent / 100.0));
         cappedLot = MathMin(cappedLot, maxGrowthLot);
      }
   }

   return NormalizeVolumeBySymbol(symbol, cappedLot);
}

void StoreLastLot(string symbol, double lot)
{
   GlobalVariableSet(LastLotKey(symbol), lot);
}

void DrawLine(string name, double price, color clr)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
}

void DrawWeeklyLevels()
{
   string symbol = _Symbol;

   double high1 = iHigh(symbol, PERIOD_W1, 1);
   double low1  = iLow(symbol, PERIOD_W1, 1);

   double high2 = iHigh(symbol, PERIOD_W1, 2);
   double low2  = iLow(symbol, PERIOD_W1, 2);

   if(high1 == 0 || low1 == 0 || high2 == 0 || low2 == 0)
      return;

   double mid1   = (high1 + low1) / 2.0;
   double extUp1 = high1 + (high1 - mid1);
   double extDn1 = low1  - (mid1 - low1);

   double mid2   = (high2 + low2) / 2.0;
   double extUp2 = high2 + (high2 - mid2);
   double extDn2 = low2  - (mid2 - low2);

   DrawLine(W1_PREFIX_1 + "HIGH",   high1,  clrYellow);
   DrawLine(W1_PREFIX_1 + "LOW",    low1,   clrYellow);
   DrawLine(W1_PREFIX_1 + "MID",    mid1,   clrYellow);
   DrawLine(W1_PREFIX_1 + "EXT_UP", extUp1, clrYellow);
   DrawLine(W1_PREFIX_1 + "EXT_DN", extDn1, clrYellow);

   DrawLine(W1_PREFIX_2 + "HIGH",   high2,  clrSilver);
   DrawLine(W1_PREFIX_2 + "LOW",    low2,   clrSilver);
   DrawLine(W1_PREFIX_2 + "MID",    mid2,   clrSilver);
   DrawLine(W1_PREFIX_2 + "EXT_UP", extUp2, clrSilver);
   DrawLine(W1_PREFIX_2 + "EXT_DN", extDn2, clrSilver);
}

//----------------------------------------------------
// Create button
//----------------------------------------------------

void InitButtonNames()
{
   string suffix = "_" + (string)ChartID();
   BTN_SELL      = BTN_SELL_BASE + suffix;
   BTN_AUTO_SELL = BTN_AUTO_SELL_BASE + suffix;
   BTN_AUTO_BUY  = BTN_AUTO_BUY_BASE + suffix;
}

bool CreateButton(const string name, const string text, int x, int y, color bg)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   ResetLastError();
   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
   {
      Print("CreateButton failed for ", name, " err=", GetLastError());
      return false;
   }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 120);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 28);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);

   return true;
}

void CreateControlPanel()
{
   CreateButton(BTN_SELL,      "SALE",      15,  30, clrOrangeRed);
   CreateButton(BTN_AUTO_SELL, "AUTO-SELL", 145, 30, clrFireBrick);
   CreateButton(BTN_AUTO_BUY,  "AUTO-BUY",  275, 30, clrSeaGreen);
   ChartRedraw(0);
}

void DeleteControlPanel()
{
   ObjectDelete(0, BTN_SELL);
   ObjectDelete(0, BTN_AUTO_SELL);
   ObjectDelete(0, BTN_AUTO_BUY);
}


void EnsureControlPanel()
{
   if(ObjectFind(0, BTN_SELL) < 0 ||
      ObjectFind(0, BTN_AUTO_SELL) < 0 ||
      ObjectFind(0, BTN_AUTO_BUY) < 0)
   {
      CreateControlPanel();
   }
}

void CloseSymbolPositions(string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      if(!trade.PositionClose(ticket))
      {
         Print("Failed to close position ticket=", ticket,
               " retcode=", trade.ResultRetcode(),
               " desc=", trade.ResultRetcodeDescription());
      }
   }
}

void OpenWeeklyTrade(bool isBuy)
{
   string symbol = _Symbol;

   if(OnePositionPerSymbol && SymbolHasOpenPosition(symbol))
   {
      Print("There is already an open position on ", symbol);
      return;
   }

   double lot = CalculateManagedLot(symbol, isBuy);
   if(lot <= 0.0)
   {
      Print("Lot calculation failed for ", symbol);
      return;
   }

   double entry = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(symbol, SYMBOL_BID);

   ENUM_POSITION_TYPE posType = isBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double sl = 0.0;
   double tp = 0.0;

   if(!BuildWeeklySLTP(symbol, posType, entry, sl, tp))
   {
      Print("Could not find previous/next weekly levels for SL/TP.");
      return;
   }

   bool sent = false;
   if(isBuy)
      sent = trade.Buy(lot, symbol, 0.0, sl, tp, "Weekly Auto Buy");
   else
      sent = trade.Sell(lot, symbol, 0.0, sl, tp, "Weekly Auto Sell");

   if(!sent)
   {
      Print("Order send failed. retcode=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription());
      return;
   }

   StoreLastLot(symbol, lot);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   InitButtonNames();
   CreateControlPanel();
   EnsureControlPanel();
   DrawWeeklyLevels();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteControlPanel();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   EnsureControlPanel();
   DrawWeeklyLevels();
}

//+------------------------------------------------------------------+
//| Chart event function                                             |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam == BTN_SELL)
      CloseSymbolPositions(_Symbol);
   else if(sparam == BTN_AUTO_SELL)
      OpenWeeklyTrade(false);
   else if(sparam == BTN_AUTO_BUY)
      OpenWeeklyTrade(true);
}

//+------------------------------------------------------------------+
