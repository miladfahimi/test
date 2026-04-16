//+------------------------------------------------------------------+
//|                                            MiladTradeManager.mq5 |
//+------------------------------------------------------------------+
#property version   "2.61"

#include <Trade/Trade.mqh>
CTrade trade;

//----------------------------------------------------
// Inputs
//----------------------------------------------------
input double MaxMarginUsagePercent      = 25.0;
input double TargetProfitPercent        = 1.0;
input double StopLossPercent            = 1.0;

input double ProfitLockTriggerUSD       = 100.0;
input double LockedProfitUSD            = 10.0;

input double NegativeTriggerUSD         = -30.0;
input double RescueTakeProfitUSD        = 10.0;

input double PartialClosePercent        = 50.0;

input double TrailingStartUSD           = 200.0;
input double TrailingDistanceUSD        = 50.0;

input bool   OnePositionPerSymbol       = true;
input bool   UseCurrentChartSymbol      = true;

input bool   EnableWeeklyLevels         = true;
input double EntryZoneUSD               = 50.0;

//----------------------------------------------------
// Button names
//----------------------------------------------------
string BTN_BUY  = "MILAD_BTN_BUY_AUTO";
string BTN_SELL = "MILAD_BTN_SELL_AUTO";
string CHK_ENTRY_ZONE = "MILAD_CHK_ENTRY_ZONE";

bool EntryZoneCheckEnabled = true;

//----------------------------------------------------
// Weekly line prefixes
//----------------------------------------------------
string W1_PREFIX_1 = "W1_LAST_";
string W1_PREFIX_2 = "W1_PREV_";

//----------------------------------------------------
// Utility functions
//----------------------------------------------------
bool NearlyEqual(double a, double b, double eps)
{
   return (MathAbs(a - b) <= eps);
}

double GetEquity()
{
   return AccountInfoDouble(ACCOUNT_EQUITY);
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

      string psymbol = PositionGetString(POSITION_SYMBOL);
      if(psymbol == symbol)
         return true;
   }
   return false;
}

//----------------------------------------------------
// Persistent partial-close state
//----------------------------------------------------
string PartialCloseKey(ulong ticket)
{
   return "MILAD_PARTIAL_DONE_" + (string)ticket;
}

bool IsPartialCloseDone(ulong ticket)
{
   return GlobalVariableCheck(PartialCloseKey(ticket));
}

void MarkPartialCloseDone(ulong ticket)
{
   GlobalVariableSet(PartialCloseKey(ticket), (double)TimeCurrent());
}

void ClearPartialCloseFlag(ulong ticket)
{
   string key = PartialCloseKey(ticket);
   if(GlobalVariableCheck(key))
      GlobalVariableDel(key);
}

//----------------------------------------------------
// Find target price for a given profit/loss in account currency
//----------------------------------------------------
double FindPriceForTargetProfit(string symbol,
                                ENUM_POSITION_TYPE posType,
                                double volume,
                                double openPrice,
                                double targetProfitUSD)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   if(MathAbs(targetProfitUSD) < 0.0000001)
      return NormalizeDouble(openPrice, digits);

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   ENUM_ORDER_TYPE orderType = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double step = 1000.0 * point;
   double price = openPrice;
   double profit = 0.0;

   for(int i = 0; i < 20000; i++)
   {
      double nextPrice;

      if(posType == POSITION_TYPE_BUY)
         nextPrice = (targetProfitUSD > 0.0) ? price + step : price - step;
      else
         nextPrice = (targetProfitUSD > 0.0) ? price - step : price + step;

      if(nextPrice <= 0.0)
         break;

      if(!OrderCalcProfit(orderType, symbol, volume, openPrice, nextPrice, profit))
      {
         Print("OrderCalcProfit failed for ", symbol, " error=", GetLastError());
         return NormalizeDouble(openPrice, digits);
      }

      bool reached = false;
      if(targetProfitUSD > 0.0 && profit >= targetProfitUSD)
         reached = true;
      if(targetProfitUSD < 0.0 && profit <= targetProfitUSD)
         reached = true;

      if(reached)
      {
         double low = price;
         double high = nextPrice;

         if(low > high)
         {
            double tmp = low;
            low = high;
            high = tmp;
         }

         for(int j = 0; j < 80; j++)
         {
            double mid = (low + high) / 2.0;
            double midProfit = 0.0;

            if(!OrderCalcProfit(orderType, symbol, volume, openPrice, mid, midProfit))
               break;

            if(targetProfitUSD > 0.0)
            {
               if(midProfit < targetProfitUSD)
               {
                  if(posType == POSITION_TYPE_BUY) low = mid;
                  else                             high = mid;
               }
               else
               {
                  if(posType == POSITION_TYPE_BUY) high = mid;
                  else                             low = mid;
               }
            }
            else
            {
               if(midProfit > targetProfitUSD)
               {
                  if(posType == POSITION_TYPE_BUY) high = mid;
                  else                             low = mid;
               }
               else
               {
                  if(posType == POSITION_TYPE_BUY) low = mid;
                  else                             high = mid;
               }
            }
         }

         return NormalizeDouble((low + high) / 2.0, digits);
      }

      price = nextPrice;
   }

   return NormalizeDouble(openPrice, digits);
}

//----------------------------------------------------
// Calculate max volume by margin cap
//----------------------------------------------------
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
      {
         Print("OrderCalcMargin failed for ", symbol, " lot=", normLot, " error=", GetLastError());
         continue;
      }

      if(margin <= maxMarginMoney)
         bestLot = normLot;
      else
         break;
   }

   return bestLot;
}

//----------------------------------------------------
// Weekly levels helpers
//----------------------------------------------------
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

bool IsNearWeeklyLevel(string symbol, ENUM_ORDER_TYPE orderType, double volume)
{
   double currentPrice = (orderType == ORDER_TYPE_BUY)
                         ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(symbol, SYMBOL_BID);

   double levels[];
   int count = GetWeeklyLevels(symbol, levels);
   if(count <= 0)
      return false;

   for(int i = 0; i < count; i++)
   {
      double pnl = 0.0;

      if(!OrderCalcProfit(orderType, symbol, volume, currentPrice, levels[i], pnl))
         continue;

      if(MathAbs(pnl) <= EntryZoneUSD)
         return true;
   }

   return false;
}

bool FindNearestWeeklyOppositeLevel(string symbol,
                                    ENUM_POSITION_TYPE posType,
                                    double referencePrice,
                                    double &nearestLevel)
{
   double levels[];
   int count = GetWeeklyLevels(symbol, levels);
   if(count <= 0)
      return false;

   bool found = false;
   double bestDistance = DBL_MAX;

   for(int i = 0; i < count; i++)
   {
      double level = levels[i];
      double distance = 0.0;

      if(posType == POSITION_TYPE_BUY)
      {
         if(level >= referencePrice)
            continue;
         distance = referencePrice - level;
      }
      else
      {
         if(level <= referencePrice)
            continue;
         distance = level - referencePrice;
      }

      if(distance < bestDistance)
      {
         bestDistance = distance;
         nearestLevel = level;
         found = true;
      }
   }

   return found;
}

double ComputeWeeklyBasedStopLoss(string symbol,
                                  ENUM_POSITION_TYPE posType,
                                  double volume,
                                  double openPrice,
                                  double bufferUsd)
{
   double nearestLevel = 0.0;
   if(!FindNearestWeeklyOppositeLevel(symbol, posType, openPrice, nearestLevel))
      return 0.0;

   return FindPriceForTargetProfit(symbol, posType, volume, nearestLevel, -MathAbs(bufferUsd));
}

//----------------------------------------------------
// Safe modify
//----------------------------------------------------
bool SafeModifyPosition(ulong ticket, string symbol, double newSL, double newTP)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double eps = SymbolInfoDouble(symbol, SYMBOL_POINT) * 2.0;

   double oldSL = PositionGetDouble(POSITION_SL);
   double oldTP = PositionGetDouble(POSITION_TP);

   newSL = (newSL > 0.0) ? NormalizeDouble(newSL, digits) : 0.0;
   newTP = (newTP > 0.0) ? NormalizeDouble(newTP, digits) : 0.0;

   bool sameSL = NearlyEqual(oldSL, newSL, eps);
   bool sameTP = NearlyEqual(oldTP, newTP, eps);

   if(sameSL && sameTP)
      return true;

   bool ok = trade.PositionModify(ticket, newSL, newTP);
   if(!ok)
   {
      Print("PositionModify failed. ticket=", ticket,
            " symbol=", symbol,
            " newSL=", newSL,
            " newTP=", newTP,
            " retcode=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription());
   }
   return ok;
}

//----------------------------------------------------
// Create button
//----------------------------------------------------
bool CreateButton(const string name, const string text, int x, int y, color bg)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
   {
      Print("Failed to create button: ", name, " error=", GetLastError());
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
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);

   return true;
}

void UpdateEntryZoneCheckbox()
{
   string text = EntryZoneCheckEnabled ? "[x] ENTRY ZONE" : "[ ] ENTRY ZONE";
   ObjectSetString(0, CHK_ENTRY_ZONE, OBJPROP_TEXT, text);
}

bool CreateEntryZoneCheckbox(int x, int y)
{
   if(ObjectFind(0, CHK_ENTRY_ZONE) >= 0)
      ObjectDelete(0, CHK_ENTRY_ZONE);

   if(!ObjectCreate(0, CHK_ENTRY_ZONE, OBJ_BUTTON, 0, 0, 0))
   {
      Print("Failed to create checkbox: ", CHK_ENTRY_ZONE, " error=", GetLastError());
      return false;
   }

   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_XSIZE, 250);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_YSIZE, 24);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_BGCOLOR, clrDimGray);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, CHK_ENTRY_ZONE, OBJPROP_STATE, false);

   UpdateEntryZoneCheckbox();
   return true;
}

void CreateControlPanel()
{
   CreateButton(BTN_BUY,  "BUY AUTO",  15, 30, clrSeaGreen);
   CreateButton(BTN_SELL, "SELL AUTO", 145, 30, clrFireBrick);
   CreateEntryZoneCheckbox(15, 65);
}

void DeleteControlPanel()
{
   ObjectDelete(0, BTN_BUY);
   ObjectDelete(0, BTN_SELL);
   ObjectDelete(0, CHK_ENTRY_ZONE);
}

//----------------------------------------------------
// Weekly lines
//----------------------------------------------------
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
   if(!EnableWeeklyLevels) return;

   string symbol = _Symbol;

   double high1 = iHigh(symbol, PERIOD_W1, 1);
   double low1  = iLow(symbol, PERIOD_W1, 1);

   double high2 = iHigh(symbol, PERIOD_W1, 2);
   double low2  = iLow(symbol, PERIOD_W1, 2);

   if(high1 == 0 || low1 == 0 || high2 == 0 || low2 == 0) return;

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
// Partial close and TP extension
//----------------------------------------------------
bool TryPartialCloseAndExtendTP(ulong ticket, string symbol, double currentSL)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   if(IsPartialCloseDone(ticket))
      return false;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double volume              = PositionGetDouble(POSITION_VOLUME);
   double openPrice           = PositionGetDouble(POSITION_PRICE_OPEN);

   double closeVolume = NormalizeVolumeBySymbol(symbol, volume * (PartialClosePercent / 100.0));
   double minLot      = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   if(closeVolume < minLot || closeVolume <= 0.0)
   {
      MarkPartialCloseDone(ticket);
      return false;
   }

   bool ok = trade.PositionClosePartial(ticket, closeVolume);
   if(!ok)
   {
      Print("PositionClosePartial failed. ticket=", ticket,
            " retcode=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription());
      return false;
   }

   MarkPartialCloseDone(ticket);
   Sleep(500);

   if(!PositionSelectByTicket(ticket))
      return true;

   double remainingVolume = PositionGetDouble(POSITION_VOLUME);
   double newTPProfitUSD  = GetEquity() * (StopLossPercent / 100.0);
   double newTPPrice      = FindPriceForTargetProfit(symbol, posType, remainingVolume, openPrice, newTPProfitUSD);

   SafeModifyPosition(ticket, symbol, currentSL, newTPPrice);
   return true;
}

//----------------------------------------------------
// Open trade
//----------------------------------------------------
void OpenAutoTrade(bool isBuy)
{
   string symbol = _Symbol;

   if(OnePositionPerSymbol && SymbolHasOpenPosition(symbol))
   {
      Print("There is already an open position on ", symbol);
      return;
   }

   double equity = GetEquity();
   double maxMarginMoney = equity * (MaxMarginUsagePercent / 100.0);

   ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double volume = CalculateMaxVolumeForMargin(symbol, orderType, maxMarginMoney);

   if(volume <= 0.0)
   {
      Print("Could not calculate a valid volume for ", symbol);
      return;
   }

   if(EntryZoneCheckEnabled && !IsNearWeeklyLevel(symbol, orderType, volume))
   {
      Print("Entry blocked: price is not within weekly level zone");
      return;
   }

   double fixedTpUsd = equity * (StopLossPercent / 100.0);
   double weeklySlBufferUsd = 50.0;

   ENUM_POSITION_TYPE plannedPosType = isBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double currentPrice = (plannedPosType == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(symbol, SYMBOL_BID);
   double nearestOppositeLevel = 0.0;
   if(!FindNearestWeeklyOppositeLevel(symbol, plannedPosType, currentPrice, nearestOppositeLevel))
   {
      Print("Entry blocked: no weekly level found on opposite side for stop loss placement");
      return;
   }

   bool sent = false;
   if(isBuy)
      sent = trade.Buy(volume, symbol, 0.0, 0.0, 0.0, "Milad Auto Buy");
   else
      sent = trade.Sell(volume, symbol, 0.0, 0.0, 0.0, "Milad Auto Sell");

   if(!sent)
   {
      Print("Order send failed. retcode=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription());
      return;
   }

   Sleep(500);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      string psymbol = PositionGetString(POSITION_SYMBOL);
      if(psymbol != symbol) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double posVolume           = PositionGetDouble(POSITION_VOLUME);
      double openPrice           = PositionGetDouble(POSITION_PRICE_OPEN);

      double slPrice = ComputeWeeklyBasedStopLoss(symbol, posType, posVolume, openPrice, weeklySlBufferUsd);
      if(slPrice <= 0.0)
         slPrice = FindPriceForTargetProfit(symbol, posType, posVolume, openPrice, -(equity * (StopLossPercent / 100.0)));
      double tpPrice = FindPriceForTargetProfit(symbol, posType, posVolume, openPrice, fixedTpUsd);

      SafeModifyPosition(ticket, symbol, slPrice, tpPrice);
      ClearPartialCloseFlag(ticket);

      Print("Opened ", (isBuy ? "BUY" : "SELL"),
            " symbol=", symbol,
            " volume=", posVolume,
            " equity=", equity,
            " TP_USD=", fixedTpUsd,
            " SL_mode=weekly_level_plus_buffer",
            " maxMarginMoney=", maxMarginMoney);
      return;
   }
}

//----------------------------------------------------
// Manage position
//----------------------------------------------------
void ManageOnePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   string symbol = PositionGetString(POSITION_SYMBOL);

   if(UseCurrentChartSymbol && symbol != _Symbol)
      return;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double volume              = PositionGetDouble(POSITION_VOLUME);
   double openPrice           = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentProfit       = PositionGetDouble(POSITION_PROFIT);
   double currentSL           = PositionGetDouble(POSITION_SL);
   double currentTP           = PositionGetDouble(POSITION_TP);

   double equity             = GetEquity();
   double stopLossUsd        = equity * (StopLossPercent / 100.0);
   double triggerProfitUsd   = ProfitLockTriggerUSD;
   double partialTriggerUsd  = ProfitLockTriggerUSD;
   double trailingStartUsd   = TrailingStartUSD;

   double initialSLPrice = FindPriceForTargetProfit(symbol, posType, volume, openPrice, -stopLossUsd);
   double initialTPPrice = FindPriceForTargetProfit(symbol, posType, volume, openPrice, stopLossUsd);
   double lockedSLPrice  = FindPriceForTargetProfit(symbol, posType, volume, openPrice,  LockedProfitUSD);
   double rescueTPPrice  = FindPriceForTargetProfit(symbol, posType, volume, openPrice,  RescueTakeProfitUSD);

   if(currentSL == 0.0 || currentTP == 0.0)
   {
      double newSL = (currentSL == 0.0) ? initialSLPrice : currentSL;
      double newTP = (currentTP == 0.0) ? initialTPPrice : currentTP;
      SafeModifyPosition(ticket, symbol, newSL, newTP);

      if(!PositionSelectByTicket(ticket))
         return;

      currentSL     = PositionGetDouble(POSITION_SL);
      currentTP     = PositionGetDouble(POSITION_TP);
      currentProfit = PositionGetDouble(POSITION_PROFIT);
   }

   if(currentProfit >= partialTriggerUsd && !IsPartialCloseDone(ticket))
   {
      if(TryPartialCloseAndExtendTP(ticket, symbol, currentSL))
         return;
   }

   if(!PositionSelectByTicket(ticket))
      return;

   posType       = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   volume        = PositionGetDouble(POSITION_VOLUME);
   openPrice     = PositionGetDouble(POSITION_PRICE_OPEN);
   currentSL     = PositionGetDouble(POSITION_SL);
   currentTP     = PositionGetDouble(POSITION_TP);
   currentProfit = PositionGetDouble(POSITION_PROFIT);

   lockedSLPrice = FindPriceForTargetProfit(symbol, posType, volume, openPrice, LockedProfitUSD);
   rescueTPPrice = FindPriceForTargetProfit(symbol, posType, volume, openPrice, RescueTakeProfitUSD);

   if(currentProfit >= trailingStartUsd)
   {
      double trailLockedProfitUsd = currentProfit - TrailingDistanceUSD;

      if(trailLockedProfitUsd > LockedProfitUSD)
      {
         double trailSLPrice = FindPriceForTargetProfit(symbol, posType, volume, openPrice, trailLockedProfitUsd);
         bool shouldMoveSL = false;

         if(posType == POSITION_TYPE_BUY)
         {
            if(currentSL == 0.0 || trailSLPrice > currentSL)
               shouldMoveSL = true;
         }
         else
         {
            if(currentSL == 0.0 || trailSLPrice < currentSL)
               shouldMoveSL = true;
         }

         if(shouldMoveSL)
            SafeModifyPosition(ticket, symbol, trailSLPrice, currentTP);
      }
   }
   else if(currentProfit >= triggerProfitUsd)
   {
      bool shouldMoveSL = false;

      if(posType == POSITION_TYPE_BUY)
      {
         if(currentSL == 0.0 || lockedSLPrice > currentSL)
            shouldMoveSL = true;
      }
      else
      {
         if(currentSL == 0.0 || lockedSLPrice < currentSL)
            shouldMoveSL = true;
      }

      if(shouldMoveSL)
         SafeModifyPosition(ticket, symbol, lockedSLPrice, currentTP);
   }

   if(currentProfit <= NegativeTriggerUSD)
   {
      bool shouldMoveTP = false;

      if(posType == POSITION_TYPE_BUY)
      {
         if(currentTP == 0.0 || rescueTPPrice < currentTP)
            shouldMoveTP = true;
      }
      else
      {
         if(currentTP == 0.0 || rescueTPPrice > currentTP)
            shouldMoveTP = true;
      }

      if(shouldMoveTP)
         SafeModifyPosition(ticket, symbol, currentSL, rescueTPPrice);
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   CreateControlPanel();
   DrawWeeklyLevels();
   Print("MiladTradeManager v2.60 initialized on symbol ", _Symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteControlPanel();
   Print("MiladTradeManager deinitialized. reason=", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   DrawWeeklyLevels();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
         ManageOnePosition(ticket);
   }
}

//+------------------------------------------------------------------+
//| Chart event function                                             |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == BTN_BUY)
      {
         Print("BUY AUTO clicked");
         OpenAutoTrade(true);
      }
      else if(sparam == BTN_SELL)
      {
         Print("SELL AUTO clicked");
         OpenAutoTrade(false);
      }
      else if(sparam == CHK_ENTRY_ZONE)
      {
         EntryZoneCheckEnabled = !EntryZoneCheckEnabled;
         UpdateEntryZoneCheckbox();
         Print("Entry zone check ", (EntryZoneCheckEnabled ? "enabled" : "disabled"));
      }
   }
}
//+------------------------------------------------------------------+
