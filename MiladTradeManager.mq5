//+------------------------------------------------------------------+
//|                                            MiladTradeManager.mq5 |
//+------------------------------------------------------------------+
#property version   "3.02"

#include <Trade/Trade.mqh>
CTrade trade;

//----------------------------------------------------
// Inputs (simplified)
//----------------------------------------------------
input double MaxMarginUsagePercent = 20.0;
input bool   OnePositionPerSymbol  = true;
input bool   DrawWeeklyLines       = true;
input double RescueTargetUsd       = 10.0;
input bool   EnableLocalWebBridge  = false;
input string LocalBridgeUrl        = "http://127.0.0.1:8000/api/command/next";
input int    BridgePollSeconds     = 1;

//----------------------------------------------------
// Button names
//----------------------------------------------------
string BTN_BUY    = "MILAD_BTN_BUY_AUTO";
string BTN_SELL   = "MILAD_BTN_SELL_AUTO";
string BTN_SALE   = "MILAD_BTN_SALE";
string BTN_RESCUE = "MILAD_BTN_RESCUE";
string BTN_CLOSEALL = "MILAD_BTN_CLOSE_ALL";
string BTN_CLOSE50 = "MILAD_BTN_CLOSE_50";
string BTN_CLOSE30 = "MILAD_BTN_CLOSE_30";
string BTN_GET100 = "MILAD_BTN_GET_100";

//----------------------------------------------------
// Weekly line prefixes
//----------------------------------------------------
string W1_PREFIX_1 = "W1_LAST_";
string W1_PREFIX_2 = "W1_PREV_";

datetime g_lastBridgePoll = 0;

void OpenAutoTradeForSymbolWithLot(bool isBuy, string symbol, double lotOverride, bool bypassSinglePositionGuard);
void CloseAllPositionsForSymbol(string symbol);

//----------------------------------------------------
// Utility helpers
//----------------------------------------------------
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

bool FindNearestWeeklyTargetLevel(string symbol,
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
         if(level <= referencePrice)
            continue;
         distance = level - referencePrice;
      }
      else
      {
         if(level >= referencePrice)
            continue;
         distance = referencePrice - level;
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

//----------------------------------------------------
// Buttons
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
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1000);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);

   return true;
}

void CreateControlPanel()
{
   CreateButton(BTN_BUY,    "AUTO BUY",   15, 30, clrSeaGreen);
   CreateButton(BTN_SELL,   "AUTO SELL", 145, 30, clrFireBrick);
   CreateButton(BTN_SALE,   "SALE",       15, 64, clrIndianRed);
   CreateButton(BTN_RESCUE, "RESCUE $10", 145, 64, clrDarkOrange);
   CreateButton(BTN_CLOSEALL, "CLOSE ALL", 15, 98, clrMediumVioletRed);
   CreateButton(BTN_CLOSE50, "CLOSE 50%", 145, 98, clrSteelBlue);
   CreateButton(BTN_CLOSE30, "CLOSE 30%", 15, 132, clrSlateBlue);
   CreateButton(BTN_GET100, "GET $100",   145, 132, clrDarkGreen);
}

void EnsureControlPanel()
{
   if(ObjectFind(0, BTN_BUY) < 0 || ObjectFind(0, BTN_SELL) < 0 ||
      ObjectFind(0, BTN_SALE) < 0 || ObjectFind(0, BTN_RESCUE) < 0 ||
      ObjectFind(0, BTN_CLOSEALL) < 0 || ObjectFind(0, BTN_CLOSE50) < 0 || ObjectFind(0, BTN_CLOSE30) < 0 ||
      ObjectFind(0, BTN_GET100) < 0)
      CreateControlPanel();
}

void DeleteControlPanel()
{
   ObjectDelete(0, BTN_BUY);
   ObjectDelete(0, BTN_SELL);
   ObjectDelete(0, BTN_SALE);
   ObjectDelete(0, BTN_RESCUE);
   ObjectDelete(0, BTN_CLOSEALL);
   ObjectDelete(0, BTN_CLOSE50);
   ObjectDelete(0, BTN_CLOSE30);
   ObjectDelete(0, BTN_GET100);
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
   if(!DrawWeeklyLines) return;

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
// Open trade (simple)
//----------------------------------------------------
void OpenAutoTrade(bool isBuy)
{
   OpenAutoTradeForSymbol(isBuy, _Symbol);
}

bool IsValidVolumeForSymbol(string symbol, double volume)
{
   if(volume <= 0.0)
      return false;

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   return (volume >= minLot && volume <= maxLot);
}

void OpenAutoTradeForSymbol(bool isBuy, string symbol)
{
   OpenAutoTradeForSymbolWithLot(isBuy, symbol, 0.0, false);
}

void OpenAutoTradeForSymbolWithLot(bool isBuy, string symbol, double lotOverride, bool bypassSinglePositionGuard)
{
   StringTrimRight(symbol);
   StringTrimLeft(symbol);
   if(symbol == "")
      symbol = _Symbol;

   if(!SymbolSelect(symbol, true))
   {
      Print("OpenAutoTrade aborted: failed to select symbol ", symbol);
      return;
   }

   if(OnePositionPerSymbol && !bypassSinglePositionGuard && SymbolHasOpenPosition(symbol))
   {
      Print("There is already an open position on ", symbol);
      return;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxMarginMoney = equity * (MaxMarginUsagePercent / 100.0);

   ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   ENUM_POSITION_TYPE posType = isBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   double volume = CalculateMaxVolumeForMargin(symbol, orderType, maxMarginMoney);
   if(lotOverride > 0.0)
   {
      volume = NormalizeVolumeBySymbol(symbol, lotOverride);
      if(!IsValidVolumeForSymbol(symbol, volume))
      {
         Print("Invalid lot override for ", symbol, ". Requested=", lotOverride, " normalized=", volume);
         return;
      }
   }
   if(volume <= 0.0)
   {
      Print("Could not calculate a valid volume for ", symbol);
      return;
   }

   double openRefPrice = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);

   double slPrice = 0.0;
   double tpPrice = 0.0;

   if(!FindNearestWeeklyOppositeLevel(symbol, posType, openRefPrice, slPrice))
   {
      Print("Entry blocked: could not find previous weekly level for stop loss.");
      return;
   }

   if(!FindNearestWeeklyTargetLevel(symbol, posType, openRefPrice, tpPrice))
   {
      Print("Entry blocked: could not find next weekly level for take profit.");
      return;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   bool sent = false;
   if(isBuy)
      sent = trade.Buy(volume, symbol, 0.0, slPrice, tpPrice, "Milad Auto Buy");
   else
      sent = trade.Sell(volume, symbol, 0.0, slPrice, tpPrice, "Milad Auto Sell");

   if(!sent)
   {
      Print("Order send failed. retcode=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription());
      return;
   }

   Print("Opened ", (isBuy ? "BUY" : "SELL"),
         " symbol=", symbol,
         " volume=", volume,
         " manualLot=", (lotOverride > 0.0 ? "true" : "false"),
         " maxMarginUsagePercent=", MaxMarginUsagePercent,
         " SL=", slPrice,
         " TP=", tpPrice);
}

double ComputePriceDeltaForMoney(string symbol, double totalVolume, double targetMoney)
{
   if(totalVolume <= 0.0 || targetMoney <= 0.0)
      return 0.0;

   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = SymbolInfoDouble(symbol, SYMBOL_POINT);

   double tickValueProfit = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   double tickValueLoss   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double tickValue = 0.0;

   if(tickValueProfit > 0.0 && tickValueLoss > 0.0)
      tickValue = (tickValueProfit + tickValueLoss) / 2.0;
   else if(tickValueProfit > 0.0)
      tickValue = tickValueProfit;
   else
      tickValue = tickValueLoss;

   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   return (targetMoney * tickSize) / (tickValue * totalVolume);
}

bool ApplyRescueForSide(string symbol,
                        ENUM_POSITION_TYPE side,
                        double weightedEntry,
                        double totalVolume,
                        ulong &tickets[])
{
   double delta = ComputePriceDeltaForMoney(symbol, totalVolume, RescueTargetUsd);
   if(delta <= 0.0)
   {
      Print("RESCUE failed: could not compute price delta for ", symbol, " side=", (int)side);
      return false;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double marketPrice = (side == POSITION_TYPE_BUY)
                        ? SymbolInfoDouble(symbol, SYMBOL_BID)
                        : SymbolInfoDouble(symbol, SYMBOL_ASK);
   bool isInProfit = (side == POSITION_TYPE_BUY)
                     ? (marketPrice > weightedEntry)
                     : (marketPrice < weightedEntry);

   double rescueTp = NormalizeDouble((side == POSITION_TYPE_BUY)
                                     ? (weightedEntry + delta)
                                     : (weightedEntry - delta), digits);
   double rescueSl = NormalizeDouble((side == POSITION_TYPE_BUY)
                                     ? (weightedEntry + delta)
                                     : (weightedEntry - delta), digits);

   bool allOk = true;
   for(int i = 0; i < ArraySize(tickets); i++)
   {
      ulong ticket = tickets[i];
      if(!PositionSelectByTicket(ticket))
      {
         allOk = false;
         Print("RESCUE modify skipped: failed to select ticket=", ticket);
         continue;
      }

      double currentSl = PositionGetDouble(POSITION_SL);
      double currentTp = PositionGetDouble(POSITION_TP);

      double newSl = currentSl;
      double newTp = currentTp;

      if(isInProfit)
      {
         // Winning basket: secure +$target by moving SL to profit side.
         newSl = rescueSl;
      }
      else
      {
         // Losing basket: move TP to +$target from weighted entry.
         newTp = rescueTp;
      }

      if(!trade.PositionModify(ticket, newSl, newTp))
      {
         allOk = false;
         Print("RESCUE modify failed. ticket=", ticket,
               " retcode=", trade.ResultRetcode(),
               " desc=", trade.ResultRetcodeDescription());
      }
   }

   Print("RESCUE applied on ", symbol,
         " side=", (side == POSITION_TYPE_BUY ? "BUY" : "SELL"),
         " mode=", (isInProfit ? "LOCK_PROFIT_SL" : "RECOVERY_TP"),
         " target=$", DoubleToString(RescueTargetUsd, 2),
         " totalVolume=", totalVolume,
         " entry=", weightedEntry,
         " rescueLevel=", (isInProfit ? rescueSl : rescueTp),
         " tickets=", ArraySize(tickets));

   return allOk;
}

void ApplyRescueMode()
{
   ApplyRescueModeForSymbol(_Symbol);
}

void ApplyRescueModeForSymbol(string symbol)
{
   StringTrimRight(symbol);
   StringTrimLeft(symbol);
   if(symbol == "")
      symbol = _Symbol;

   double buyVolume = 0.0;
   double sellVolume = 0.0;
   double buyWeightedPriceSum = 0.0;
   double sellWeightedPriceSum = 0.0;
   ulong buyTickets[];
   ulong sellTickets[];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);

      if(posType == POSITION_TYPE_BUY)
      {
         buyVolume += volume;
         buyWeightedPriceSum += entry * volume;
         int buySize = ArraySize(buyTickets);
         ArrayResize(buyTickets, buySize + 1);
         buyTickets[buySize] = ticket;
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         sellVolume += volume;
         sellWeightedPriceSum += entry * volume;
         int sellSize = ArraySize(sellTickets);
         ArrayResize(sellTickets, sellSize + 1);
         sellTickets[sellSize] = ticket;
      }
   }

   if(buyVolume <= 0.0 && sellVolume <= 0.0)
   {
      Print("RESCUE skipped: no open positions for ", symbol);
      return;
   }

   bool ok = true;
   if(buyVolume > 0.0)
   {
      double buyEntry = buyWeightedPriceSum / buyVolume;
      if(!ApplyRescueForSide(symbol, POSITION_TYPE_BUY, buyEntry, buyVolume, buyTickets))
         ok = false;
   }

   if(sellVolume > 0.0)
   {
      double sellEntry = sellWeightedPriceSum / sellVolume;
      if(!ApplyRescueForSide(symbol, POSITION_TYPE_SELL, sellEntry, sellVolume, sellTickets))
         ok = false;
   }

   if(ok)
      Print("RESCUE mode completed for ", symbol);
   else
      Print("RESCUE mode completed with errors for ", symbol);
}

void SetTakeProfitForTargetUsd(double targetUsd)
{
   SetTakeProfitForTargetUsdForSymbol(targetUsd, _Symbol);
}

void SetTakeProfitForTargetUsdForSymbol(double targetUsd, string symbol)
{
   StringTrimRight(symbol);
   StringTrimLeft(symbol);
   if(symbol == "")
      symbol = _Symbol;
   if(targetUsd <= 0.0)
   {
      Print("SET TP aborted: invalid targetUsd=", targetUsd);
      return;
   }

   double buyVolume = 0.0;
   double sellVolume = 0.0;
   double buyWeightedPriceSum = 0.0;
   double sellWeightedPriceSum = 0.0;
   ulong buyTickets[];
   ulong sellTickets[];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);

      if(posType == POSITION_TYPE_BUY)
      {
         buyVolume += volume;
         buyWeightedPriceSum += entry * volume;
         int buySize = ArraySize(buyTickets);
         ArrayResize(buyTickets, buySize + 1);
         buyTickets[buySize] = ticket;
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         sellVolume += volume;
         sellWeightedPriceSum += entry * volume;
         int sellSize = ArraySize(sellTickets);
         ArrayResize(sellTickets, sellSize + 1);
         sellTickets[sellSize] = ticket;
      }
   }

   if(buyVolume <= 0.0 && sellVolume <= 0.0)
   {
      Print("SET TP skipped: no open positions for ", symbol);
      return;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   bool allOk = true;

   if(buyVolume > 0.0)
   {
      double buyEntry = buyWeightedPriceSum / buyVolume;
      double buyDelta = ComputePriceDeltaForMoney(symbol, buyVolume, targetUsd);
      if(buyDelta <= 0.0)
      {
         allOk = false;
         Print("SET TP failed for BUY: could not compute delta.");
      }
      else
      {
         double tpBuy = NormalizeDouble(buyEntry + buyDelta, digits);
         for(int i = 0; i < ArraySize(buyTickets); i++)
         {
            ulong ticket = buyTickets[i];
            if(!PositionSelectByTicket(ticket))
            {
               allOk = false;
               Print("SET TP BUY skipped: failed to select ticket=", ticket);
               continue;
            }

            double currentSl = PositionGetDouble(POSITION_SL);
            if(!trade.PositionModify(ticket, currentSl, tpBuy))
            {
               allOk = false;
               Print("SET TP BUY failed. ticket=", ticket,
                     " retcode=", trade.ResultRetcode(),
                     " desc=", trade.ResultRetcodeDescription());
            }
         }

         Print("SET TP BUY applied: target=$", DoubleToString(targetUsd, 2),
               " totalVolume=", buyVolume,
               " entry=", buyEntry,
               " tp=", tpBuy,
               " tickets=", ArraySize(buyTickets));
      }
   }

   if(sellVolume > 0.0)
   {
      double sellEntry = sellWeightedPriceSum / sellVolume;
      double sellDelta = ComputePriceDeltaForMoney(symbol, sellVolume, targetUsd);
      if(sellDelta <= 0.0)
      {
         allOk = false;
         Print("SET TP failed for SELL: could not compute delta.");
      }
      else
      {
         double tpSell = NormalizeDouble(sellEntry - sellDelta, digits);
         for(int i = 0; i < ArraySize(sellTickets); i++)
         {
            ulong ticket = sellTickets[i];
            if(!PositionSelectByTicket(ticket))
            {
               allOk = false;
               Print("SET TP SELL skipped: failed to select ticket=", ticket);
               continue;
            }

            double currentSl = PositionGetDouble(POSITION_SL);
            if(!trade.PositionModify(ticket, currentSl, tpSell))
            {
               allOk = false;
               Print("SET TP SELL failed. ticket=", ticket,
                     " retcode=", trade.ResultRetcode(),
                     " desc=", trade.ResultRetcodeDescription());
            }
         }

         Print("SET TP SELL applied: target=$", DoubleToString(targetUsd, 2),
               " totalVolume=", sellVolume,
               " entry=", sellEntry,
               " tp=", tpSell,
               " tickets=", ArraySize(sellTickets));
      }
   }

   if(allOk)
      Print("SET TP mode completed for ", symbol, " target=$", DoubleToString(targetUsd, 2));
   else
      Print("SET TP mode completed with errors for ", symbol, " target=$", DoubleToString(targetUsd, 2));
}

void ClosePartialByPercent(double percent)
{
   ClosePartialByPercentForSymbol(percent, _Symbol);
}

void ClosePartialByPercentForSymbol(double percent, string symbol)
{
   StringTrimRight(symbol);
   StringTrimLeft(symbol);
   if(symbol == "")
      symbol = _Symbol;
   if(percent <= 0.0 || percent >= 100.0)
   {
      Print("Partial close aborted: invalid percent=", percent);
      return;
   }

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   int affected = 0;
   int closed = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      double currentVolume = PositionGetDouble(POSITION_VOLUME);
      double closeVolume = NormalizeVolumeBySymbol(symbol, currentVolume * (percent / 100.0));
      double remainingVolume = NormalizeVolumeBySymbol(symbol, currentVolume - closeVolume);
      affected++;

      if(closeVolume <= 0.0)
      {
         Print("Partial close skipped (volume too small). ticket=", ticket,
               " current=", currentVolume, " percent=", percent);
         continue;
      }

      if(closeVolume >= currentVolume || remainingVolume < minLot)
      {
         Print("Partial close skipped (would fully close or break min lot). ticket=", ticket,
               " current=", currentVolume, " close=", closeVolume,
               " remaining=", remainingVolume, " minLot=", minLot);
         continue;
      }

      if(!trade.PositionClosePartial(ticket, closeVolume))
      {
         Print("Partial close failed. ticket=", ticket,
               " closeVolume=", closeVolume,
               " retcode=", trade.ResultRetcode(),
               " desc=", trade.ResultRetcodeDescription());
         continue;
      }

      closed++;
      Print("Partial close success. ticket=", ticket,
            " closeVolume=", closeVolume,
            " percent=", percent);
   }

   if(affected == 0)
      Print("Partial close skipped: no open positions for ", symbol);
   else
      Print("Partial close summary for ", symbol, ": affected=", affected,
            " partiallyClosed=", closed, " percent=", percent);
}

string ExtractJsonValue(const string body, const string keyName)
{
   string key = "\"" + keyName + "\"";
   int keyPos = StringFind(body, key);
   if(keyPos < 0)
      return "";

   int colonPos = StringFind(body, ":", keyPos);
   if(colonPos < 0)
      return "";

   int firstQuote = StringFind(body, "\"", colonPos + 1);
   if(firstQuote < 0)
      return "";

   int secondQuote = StringFind(body, "\"", firstQuote + 1);
   if(secondQuote < 0)
      return "";

   string value = StringSubstr(body, firstQuote + 1, secondQuote - firstQuote - 1);
   StringTrimRight(value);
   StringTrimLeft(value);
   return value;
}

bool FetchBridgeCommand(string &command, string &stack, string &lotText)
{
   command = "";
   stack = "";
   lotText = "";
   char response[];
   char requestData[];
   string responseHeaders;
   int timeoutMs = 1000;

   ResetLastError();
   int statusCode = WebRequest("GET", LocalBridgeUrl, "", timeoutMs, requestData, response, responseHeaders);
   if(statusCode == -1)
   {
      int err = GetLastError();
      if(err != 4014)
         Print("Web bridge request failed. error=", err);
      return false;
   }

   if(statusCode != 200)
   {
      Print("Web bridge returned non-200 status: ", statusCode);
      return false;
   }

   string body = CharArrayToString(response);

   command = ExtractJsonValue(body, "command");
   StringTrimRight(command);
   StringTrimLeft(command);
   StringToLower(command);

   stack = ExtractJsonValue(body, "stack");
   StringTrimRight(stack);
   StringTrimLeft(stack);
   lotText = ExtractJsonValue(body, "lot");
   StringTrimRight(lotText);
   StringTrimLeft(lotText);
   return (command != "");
}

void ExecuteExternalCommand(const string rawCommand, const string rawStack, const string rawLotText)
{
   string command = rawCommand;
   StringTrimRight(command);
   StringTrimLeft(command);
   StringToLower(command);

   string symbol = rawStack;
   StringTrimRight(symbol);
   StringTrimLeft(symbol);
   if(symbol == "")
      symbol = _Symbol;

   if(command == "")
      return;

   double lotOverride = 0.0;
   if(rawLotText != "")
   {
      lotOverride = StringToDouble(rawLotText);
      if(lotOverride <= 0.0)
      {
         Print("Ignoring invalid lot override from bridge: ", rawLotText);
         lotOverride = 0.0;
      }
   }

   if(command == "buy")
   {
      Print("Local bridge command: BUY symbol=", symbol);
      OpenAutoTradeForSymbolWithLot(true, symbol, lotOverride, lotOverride > 0.0);
   }
   else if(command == "sell" || command == "sale")
   {
      Print("Local bridge command: SELL/SALE symbol=", symbol);
      OpenAutoTradeForSymbolWithLot(false, symbol, lotOverride, lotOverride > 0.0);
   }
   else if(command == "rescue")
   {
      Print("Local bridge command: RESCUE symbol=", symbol);
      ApplyRescueModeForSymbol(symbol);
   }
   else if(command == "close50")
   {
      Print("Local bridge command: CLOSE 50% symbol=", symbol);
      ClosePartialByPercentForSymbol(50.0, symbol);
   }
   else if(command == "closeall")
   {
      Print("Local bridge command: CLOSE ALL symbol=", symbol);
      CloseAllPositionsForSymbol(symbol);
   }
   else if(command == "close30")
   {
      Print("Local bridge command: CLOSE 30% symbol=", symbol);
      ClosePartialByPercentForSymbol(30.0, symbol);
   }
   else if(command == "get100")
   {
      Print("Local bridge command: GET $100 symbol=", symbol);
      SetTakeProfitForTargetUsdForSymbol(100.0, symbol);
   }
   else
   {
      Print("Unknown local bridge command: ", command);
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   CreateControlPanel();
   DrawWeeklyLevels();
   if(EnableLocalWebBridge)
   {
      EventSetTimer(MathMax(1, BridgePollSeconds));
      Print("Local web bridge enabled. Poll URL=", LocalBridgeUrl);
   }
   ChartRedraw(0);
   Print("MiladTradeManager v3.02 initialized on symbol ", _Symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteControlPanel();
   Print("MiladTradeManager deinitialized. reason=", reason);
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
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!EnableLocalWebBridge)
      return;

   if(BridgePollSeconds <= 0)
      return;

   if((TimeCurrent() - g_lastBridgePoll) < BridgePollSeconds)
      return;

   g_lastBridgePoll = TimeCurrent();

   string command = "";
   string stack = "";
   string lotText = "";
   if(FetchBridgeCommand(command, stack, lotText))
      ExecuteExternalCommand(command, stack, lotText);
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
         Print("AUTO BUY clicked");
         OpenAutoTrade(true);
      }
      else if(sparam == BTN_SELL)
      {
         Print("AUTO SELL clicked");
         OpenAutoTrade(false);
      }
      else if(sparam == BTN_SALE)
      {
         Print("SALE clicked");
         OpenAutoTrade(false);
      }
      else if(sparam == BTN_RESCUE)
      {
         Print("RESCUE clicked");
         ApplyRescueMode();
      }
      else if(sparam == BTN_CLOSE50)
      {
         Print("CLOSE 50% clicked");
         ClosePartialByPercent(50.0);
      }
      else if(sparam == BTN_CLOSEALL)
      {
         Print("CLOSE ALL clicked");
         CloseAllPositionsForSymbol(_Symbol);
      }
      else if(sparam == BTN_CLOSE30)
      {
         Print("CLOSE 30% clicked");
         ClosePartialByPercent(30.0);
      }
      else if(sparam == BTN_GET100)
      {
         Print("GET $100 clicked");
         SetTakeProfitForTargetUsd(100.0);
      }
   }
}
//+------------------------------------------------------------------+
void CloseAllPositionsForSymbol(string symbol)
{
   StringTrimRight(symbol);
   StringTrimLeft(symbol);
   if(symbol == "")
      symbol = _Symbol;

   int affected = 0;
   int closed = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      affected++;

      if(!trade.PositionClose(ticket))
      {
         Print("Close all failed. ticket=", ticket,
               " retcode=", trade.ResultRetcode(),
               " desc=", trade.ResultRetcodeDescription());
         continue;
      }

      closed++;
      Print("Close all success. ticket=", ticket, " symbol=", symbol);
   }

   if(affected == 0)
      Print("Close all skipped: no open positions for ", symbol);
   else
      Print("Close all summary for ", symbol, ": affected=", affected, " closed=", closed);
}
