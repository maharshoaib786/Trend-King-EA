#property copyright ""
#property link      ""
#property version   "2.00"
#property description "Trend King EA"
#property strict

#include <Trade/Trade.mqh>

//==============================
// Inputs
//==============================
input int      InpFastEMAPeriod        = 9;        // EMA 1 (fast): Updated for M5 quick trend
input int      InpMidEMAPeriod         = 21;       // EMA 2: Updated for M5 quick trend
input int      InpAtrPeriod            = 14;       // ATR period (dashboard display)
input double   InpLotSize              = 0.01;     // Fixed lot size
input ulong    InpMagicNumber          = 20260207; // Magic number
input int      InpMaxSlippagePoints    = 20;       // Max slippage (points)
input int      InpMaxSpreadPoints      = 250;       // Max spread (points)
input bool     InpBypassSpreadOnManualStart = false; // START GRID ignores spread filter if true
input bool     InpEnableAdvancePendingOrders = true; // Maintain pending ladder in active direction
input int      InpAdvancePendingLimit   = 10;      // Number of pending orders to keep in advance
input int      InpHardPendingStopsCap   = 10;      // Hard cap for pending stop orders (0 = use InpAdvancePendingLimit)
input bool     InpOnlyPendingEntries    = true;    // If true, EA opens entries only via stop pending orders
input int      InpPendingRetryCooldownSec = 30;    // Cooldown after pending-order limit error
input int      InpMaxPendingPlacePerTick = 2;      // Max new pending orders to place per tick
input double   InpGridGapPrice         = 1.0;      // Grid gap in price units (XAUUSD: 1.0 ~= 100 points on 2 digits)
input double   InpTpVolatile           = 20.0;     // TP when VOLATILE (price units)
input double   InpTpNormal             = 3.0;      // TP when ACTIVE/SIDEWAYS (price units)
input bool     InpTpHitReplaceInLimit  = true;     // Replace TP-hit positions with limit orders in non-volatile markets
input bool     InpUseHmaHardExit       = true;     // HMA Hard Exit: Close all on candle close against HMA
input int      InpHmaExitConfirmationBars = 2;     // Candles needed to confirm HMA exit
input bool     InpResumeOnHmaRecovery  = true;     // Resume trading if price closes back on trend side
input int      InpHmaExitPeriod        = 34;       // HMA Period for hard exit
input bool     InpDirectionalLock      = true;     // Lock to latest active grid direction
input bool     InpReverseOnOppositeCrossover = true; // Close current grid and reverse on opposite crossover
input bool     InpShowSignalTextOnChart = true;    // Print BUY/SELL text on crossover candle
//--- Signal Inputs
input string         InpAuthUrl = "https://raw.githubusercontent.com/YourUser/Trend-King-EA/main/accounts.txt"; // Auth URL (Raw Text)
sinput string        InpSepSignals    = "--- SIGNAL SETTINGS ---"; // [Signal Config]
input int      InpSignalTextOffsetPoints = 120;    // Vertical offset for BUY/SELL text (points)
input bool     InpRunM1Only            = true;     // EA allowed only on M1/M5 timeframes
input bool     InpResetDirectionOnFlat = true;     // Reset direction when all EA positions are closed
input int      InpMaxGridOrders        = 30;       // Safety cap for open grid orders
input bool     InpShowEMAsOnChart      = true;     // Show colored EMAs on chart (Green/Orange)
input int      InpEMADrawBars          = 250;      // Number of bars to draw EMA lines as chart objects
input bool     InpShowDashboard        = true;     // Show live EA dashboard on chart
input bool     InpForceObjectsInFront  = true;     // Force objects to stay in front of candles
input int      InpDashboardX           = 12;       // Dashboard X offset
input int      InpDashboardY           = 22;       // Dashboard Y offset
input int      InpDashboardHeight      = 0;        // Dashboard height (0 = auto max to chart bottom)
input double   InpTrailStepPips        = 7000;       // Step trail: profit step in pips (0 = disabled)
input int      InpEmaResetCooldownBars = 5;        // Bars to skip after EMA touch reset (0 = no cooldown)

// Hidden internal constants/flags (not shown in Inputs menu).
int    InpTpRefillLimitMax = 5;
int    InpTpRefillDelaySec = 3;
bool   InpReopenClosedPositions = false;
double InpReopenWaitDistancePrice = 10.0;
int    InpReopenWaitDistancePoints = 1000;

// Market regime detection thresholds
double InpEmaSepAtrThreshold  = 0.5;    // EMA sep / ATR must exceed this for trending (M5 optimized)
double InpAtrVolatileRatio    = 1.05;   // ATR / avg_ATR must exceed this for volatile (M5 optimized)
int    InpAtrAvgPeriod        = 100;    // Bars to average ATR over (~8h on M5)

//==============================
// Globals
//==============================
CTrade   trade;
int      g_emaFastHandle      = INVALID_HANDLE;
int      g_emaMidHandle       = INVALID_HANDLE;
int      g_atrHandle          = INVALID_HANDLE;
datetime g_lastSignalBarTime  = 0;
string   g_emaVisualStatus    = "EMA visual: not started";
bool     g_gridEnabled        = true;
string   g_lastActionStatus   = "Action: ready";
int      g_reopenRequestCount = 0;
int      g_reopenRequestDirection[];
double   g_reopenRequestClosePrice[];
datetime g_nextPendingRetryTime = 0;
bool     g_pendingLimitHitThisTick = false;
double   g_pendingAnchorPrice = 0.0;
int      g_pendingAnchorDirection = 0;
string   g_tpRefillLimitCommentPrefix = "TP Refill Limit";
int      g_tpRefillQueueCount = 0;
int      g_tpRefillQueueDirection[];
double   g_tpRefillQueuePrice[];
datetime g_tpRefillQueueDueTime[];
long     g_tpRefillQueuePositionId[];
datetime g_emaTouchLastCheckedBarTime = 0;
int      g_emaTouchCooldownBarsLeft = 0;
bool     g_forcePendingAnchorActive = false;
int      g_forcePendingAnchorDirection = 0;

double   g_forcePendingAnchorPrice = 0.0;
bool     g_hmaPaused = false;

enum GridDirection
{
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = -1
};

int g_activeDirection = DIR_NONE;
int CountOurPositions(int direction = DIR_NONE);
bool IsOurPosition();
bool IsOurPositionNearPrice(const int direction, const double price, const double tol);
void CancelAllOurPendingOrders();
void CancelOurPendingStopsOnly(const int direction = DIR_NONE);
void ManageAdvancePendingOrders();
bool GetDirectionalBasePendingPrice(const int direction, double &basePrice);
void ResetPendingAnchor();
void ResetPendingRetryState();
bool RemoveOneTrailingPendingOrder(const int direction, double &removedPrice);
bool IsTpRefillLimitOrderType(const long orderType, const int direction = DIR_NONE);
bool IsTpRefillLimitOrder(const long orderType, const string comment, const int direction = DIR_NONE);
int CountTpRefillLimitOrders(const int direction = DIR_NONE);
bool HasTpRefillLimitNearPrice(const int direction, const double price, const double tol);
bool DeleteOldestTpRefillLimit(const int direction);
bool PlaceTpRefillLimitOrder(const int direction, const double requestedPrice, const string reason);
bool IsPositionIdentifierStillOpen(const long positionId, const int direction);
void AddTpRefillQueue(const int direction, const double closePrice, const long positionId);
void RemoveTpRefillQueueAt(const int index);
void ClearTpRefillQueue();
void ProcessTpRefillQueue();
void ProcessTpEmaResetWait();

string DirectionToText(const int direction)
{
   if(direction == DIR_BUY)
      return "BUY";
   if(direction == DIR_SELL)
      return "SELL";
   return "NONE";
}

string EmaObjectName(const int emaIndex, const int segmentIndex)
{
   return StringFormat("EA_EMA_%d_SEG_%d", emaIndex, segmentIndex);
}

string DashboardObjectName(const string key)
{
   return StringFormat("EA_DASH_%I64d_%s", ChartID(), key);
}

void DeleteDashboardObjects()
{
   string keys[] =
   {
      "PANEL", "PANEL_BG", "HEADER", "HEADER_BG", "TITLE", "MODE", "STATUS",
      "CARD_ACCT", "L_BAL", "V_BAL", "L_EQU", "V_EQU", "L_PL", "V_PL",
      "CARD_MKT", "L_SYM", "V_SYM", "L_SPR", "V_SPR", "L_ATR", "V_ATR",
      "L_ACT", "V_ACT", "L_SIG", "V_SIG",
      "CARD_GRID", "H_POS", "V_POS", "H_PND", "V_PND", "H_QUE", "V_QUE", "INF_BOT",
      "L_ACT_ST", "V_ACT_ST",
      "BTN_START", "BTN_STOP", "BTN_CLOSE"
   };

   int n = ArraySize(keys);
   for(int i = 0; i < n; ++i)
      ObjectDelete(0, DashboardObjectName(keys[i]));
}

//==============================
// Dashboard Helpers (Modern UI)
//==============================
bool UpsertDashboardRect(const string name, const int x, const int y, const int w, const int h, 
                        const color bgColor, const color borderColor, const int zOrder = 1000)
{
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0)) return false;
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, zOrder);
   return true;
}

bool UpsertDashboardText(const string name, const int x, const int y, const string text, 
                        const color textColor, const int fontSize = 9, const string font = "Segoe UI", 
                        const int anchor = ANCHOR_LEFT_UPPER, const int zOrder = 1001)
{
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0)) return false;
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, zOrder);
   return true;
}

bool UpsertDashboardButton(const string name, const int x, const int y, const int w, const int h, 
                          const string text, const color bgColor, const color textColor, 
                          const color hoverColor = C'0,0,0', const int zOrder = 1002)
{
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0)) return false;
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI Semibold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   // Note: Hover color not directly supported by standard OBJ_BUTTON in simple way without events, 
   // but we utilize standard properties.
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, bgColor); 
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, zOrder);
   return true;
}

void DeleteExtraEmaSegments(const int emaIndex, const int fromSegment)
{
   for(int i = fromSegment; i < 5000; ++i)
   {
      string name = EmaObjectName(emaIndex, i);
      if(ObjectFind(0, name) < 0)
         break;
      ObjectDelete(0, name);
   }
}

void DeleteEmaVisualObjects()
{
   DeleteExtraEmaSegments(1, 1);
   DeleteExtraEmaSegments(2, 1);
   DeleteExtraEmaSegments(3, 1); // Cleanup old EMA-3 objects from previous versions
}

bool UpsertEmaSegment(const int emaIndex,
                      const int segmentIndex,
                      const datetime t1,
                      const double p1,
                      const datetime t2,
                      const double p2,
                      const color lineColor)
{
   string name = EmaObjectName(emaIndex, segmentIndex);

   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2))
         return false;

      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   }
   else
   {
      if(!ObjectMove(0, name, 0, t1, p1))
         return false;
      if(!ObjectMove(0, name, 1, t2, p2))
         return false;
   }

   ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 500);
   return true;
}

//==============================
// Market Regime Helper
//==============================
string DetermineMarketRegime()
{
   double emaFast[], emaMid[], atrBuf[];
   
   // Get current EMA values
   if(CopyBuffer(g_emaFastHandle, 0, 0, 1, emaFast) <= 0) return "UNKNOWN";
   if(CopyBuffer(g_emaMidHandle, 0, 0, 1, emaMid) <= 0) return "UNKNOWN";
   
   // Get ATR history for volatility avg
   int atrLookback = MathMax(20, InpAtrAvgPeriod);
   if(CopyBuffer(g_atrHandle, 0, 0, atrLookback, atrBuf) <= 0) return "UNKNOWN";
   
   double currentAtr = atrBuf[atrLookback-1]; // Newest is at end
   double sumAtr = 0;
   for(int i=0; i<atrLookback; i++) sumAtr += atrBuf[i];
   double avgAtr = sumAtr / atrLookback;
   
   // --- HMA Dashboard Logic Swap (v1.23) ---
   // User Request: "Same fast trend volatility detector" as HMA Bot.
   // We calculate internal HMA(14) and HMA(34) to determine market state quickly.
   
   double hmaFast = GetHMA(14, 0);
   double hmaSlow = GetHMA(34, 0); // Matches HMA Hard Exit default, good baseline
   double hmaFastPrev = GetHMA(14, 1);
   
   if(hmaFast == 0 || hmaSlow == 0 || hmaFastPrev == 0) 
   {
      static datetime lastErr = 0;
      if(TimeCurrent() - lastErr > 10) {
         Print("DetermineMarketRegime: HMA calc failed. Fast=", hmaFast, " Slow=", hmaSlow, " FastPrev=", hmaFastPrev);
         lastErr = TimeCurrent();
      }
      return "UNKNOWN";
   }
      
   double hmaSep = MathAbs(hmaFast - hmaSlow);
   double hmaSlope = MathAbs(hmaFast - hmaFastPrev);
   
   // Normalize with ATR (if available) for cross-pair compatibility
   double sepRatio = (currentAtr > 0) ? (hmaSep / currentAtr) : 0;
   double slopeRatio = (currentAtr > 0) ? (hmaSlope / currentAtr) : 0;
   
   // HMA is very responsive.
   // 1. Sideways: If Fast HMA is barely moving or hugged tight to Slow HMA.
   if(slopeRatio < 0.05 || sepRatio < 0.1)
      return "SIDEWAYS";
      
   // 2. Volatile: If HMA separation is HUGE (2x ATR).
   if(sepRatio > 2.0)
      return "VOLATILE";
      
   // 3. Active: Default state for HMA (Fast Trend)
   return "ACTIVE";
}

double GetActiveTP()
{
   string regime = DetermineMarketRegime();
   if(regime == "VOLATILE") return InpTpVolatile;
   return InpTpNormal;
}



//==============================
// HMA Exit Helpers
//==============================
double GetLWMA(const double &prices[], int period, int shift)
{
   int size = ArraySize(prices);
   if(period <= 0 || size < shift + period) return 0.0;
   
   double sum = 0.0;
   double wSum = 0.0;
   for(int i = 0; i < period; i++)
   {
      double w = period - i;
      // Safety check for index
      int idx = shift + i;
      if(idx >= size) break;
      
      sum += prices[idx] * w;
      wSum += w;
   }
   return (wSum > 0) ? sum / wSum : 0.0;
}

double GetHMA(int period, int shift)
{
   if(period < 2) return 0.0;
   
   int half = period / 2;
   int sqrtP = (int)MathSqrt(period);
   int totalBars = period + sqrtP + shift + 2; // Reduced buffer slightly, +2 safety
   
   // Check if enough bars on chart
   int availableBars = Bars(_Symbol, _Period);
   if(availableBars < totalBars) {
      if(shift == 0) // Only log for main calls to avoid spam
         Print("GetHMA: Not enough Bars. Need=", totalBars, " Have=", availableBars);
      return 0.0; 
   }
   
   double closePrices[];
   // Use CopyClose with error handling
   int copied = CopyClose(_Symbol, _Period, 0, totalBars, closePrices);
   if(copied < totalBars)
   {
      if(shift == 0)
         Print("GetHMA: CopyClose failed. Need=", totalBars, " Got=", copied, " Err=", GetLastError());
      return 0.0; 
   }
   
   // Important: ArraySetAsSeries MUST be true for correct LWMA logic (index 0 = newest)
   ArraySetAsSeries(closePrices, true);
   
   double rawHMA[];
   ArrayResize(rawHMA, sqrtP);
   
   for(int k = 0; k < sqrtP; k++) 
   {
      int pos = shift + k;
      double wmaHalf = GetLWMA(closePrices, half, pos);
      double wmaFull = GetLWMA(closePrices, period, pos);
      
      if(wmaHalf == 0.0 || wmaFull == 0.0) {
         if(shift == 0) 
            Print("GetHMA: GetLWMA failed at k=", k, " wmaHalf=", wmaHalf, " wmaFull=", wmaFull);
         return 0.0; // Propagate error
      }
      
      rawHMA[k] = 2 * wmaHalf - wmaFull;
   }
   
   double result = GetLWMA(rawHMA, sqrtP, 0); 
   if(result == 0.0 && shift == 0)
      Print("GetHMA: Final GetLWMA failed. rawHMA size=", ArraySize(rawHMA), " sqrtP=", sqrtP);
      
   return result; 
}

void CheckHmaExit()
{
   if(!InpUseHmaHardExit || g_activeDirection == DIR_NONE) return;
   
   // Check only on new bar
   datetime currentTime = iTime(_Symbol, _Period, 0);
   static datetime lastChecked = 0;
   if(currentTime == lastChecked) return;
   lastChecked = currentTime;

   // 1. Resume Logic
   if(g_hmaPaused)
   {
      double hmaVal = GetHMA(InpHmaExitPeriod, 1);
      double closePrice = iClose(_Symbol, _Period, 1);
      
      bool backOnTrack = false;
      if(g_activeDirection == DIR_BUY && closePrice > hmaVal && InpResumeOnHmaRecovery)
         backOnTrack = true;
      else if(g_activeDirection == DIR_SELL && closePrice < hmaVal && InpResumeOnHmaRecovery)
         backOnTrack = true;
         
      if(backOnTrack)
      {
         g_hmaPaused = false;
         g_lastActionStatus = "Action: HMA Recovery (Resuming HMA Pause)";
         Print("HMA RESUME: Close ", closePrice, " recovered vs HMA ", hmaVal);
         UpdateDashboard();
      }
      return; // Regardless of resume, we don't check exit condition in same tick? (Or we could, but let's wait)
   }
   
   // 2. Exit Logic (Confirmation Check)
   int confirmBars = InpHmaExitConfirmationBars;
   if(confirmBars < 1) confirmBars = 1;

   bool exitTrigger = true;
   double hmaVal1 = GetHMA(InpHmaExitPeriod, 1); // Log first bar for display
   double close1 = iClose(_Symbol, _Period, 1);
   
   for(int i=1; i<=confirmBars; i++)
   {
       double hVal = GetHMA(InpHmaExitPeriod, i);
       double cVal = iClose(_Symbol, _Period, i);
       
       if(hVal == 0.0) { exitTrigger = false; break; }
       
       if(g_activeDirection == DIR_BUY)
       {
          if(cVal >= hVal) { exitTrigger = false; break; } // Failed condition
       }
       else if(g_activeDirection == DIR_SELL)
       {
          if(cVal <= hVal) { exitTrigger = false; break; } // Failed condition
       }
   }
      
   if(exitTrigger)
   {
      Print("HMA EXIT TRIGGER: ", confirmBars, " candles closed against HMA. Last Close: ", close1, " vs HMA ", hmaVal1);
      CloseAllFromDashboard(); 
      g_hmaPaused = true;
      g_lastActionStatus = "Action: HMA Hard Exit (Paused)";
      UpdateDashboard();
   }
}

void StartGridWaitForSignal()
{
   g_gridEnabled = true;
   g_lastActionStatus = "Action: Pending start (waiting for signal)";
   g_activeDirection = DIR_NONE; // Ensure clean state
   
   // Consume the current bar's signal (if any) to force waiting for a FRESH crossover.
   g_lastSignalBarTime = iTime(_Symbol, _Period, 1);
   
   Print("Start button clicked. Enabled grid, waiting for fresh signal.");
}

void StartGridNowFromDashboard()
{
   g_gridEnabled = true;
   
   // Determine Immediate Trend from current EMA values
   double fast[], slow[];
   if(CopyBuffer(g_emaFastHandle, 0, 0, 1, fast) <= 0 || CopyBuffer(g_emaMidHandle, 0, 0, 1, slow) <= 0) // Corrected g_emaSlowHandle to g_emaMidHandle
   {
      g_lastActionStatus = "Action: Error checking EMA trend";
      Print("Start Now failed: EMA buffer error.");
      return;
   }
   
   int direction = DIR_NONE;
   if(fast[0] > slow[0]) direction = DIR_BUY;
   else if(fast[0] < slow[0]) direction = DIR_SELL;
   
   g_activeDirection = direction;
   g_lastActionStatus = "Action: Forced Start (" + DirectionToText(direction) + ")";
   Print("Start Now clicked. Forced start in direction: ", DirectionToText(direction));
   
   // Trigger immediate entry logic if possible
   if(InpOnlyPendingEntries)
   {
      StartPendingLadderForDirection(g_activeDirection, "Forced Pending Start");
   }
   else
   {
      if(OpenGridOrder(g_activeDirection, "Forced Start Open"))
         ManageAdvancePendingOrders();
   }
}

//==============================
void UpdateEmaVisuals()
{
   if(!InpShowEMAsOnChart)
   {
      DeleteEmaVisualObjects();
      g_emaVisualStatus = "EMA visual: disabled";
      return;
   }

   int barsTotal = Bars(_Symbol, _Period);
   int barsToDraw = (int)MathMin((double)InpEMADrawBars, (double)(barsTotal - 1));
   if(barsToDraw < 2)
   {
      g_emaVisualStatus = "EMA visual: waiting for bars";
      return;
   }

   int need = barsToDraw + 1;

   double emaFast[], emaMid[];
   datetime barTimes[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaMid, true);
   ArraySetAsSeries(barTimes, true);

   ResetLastError();
   if(CopyBuffer(g_emaFastHandle, 0, 0, need, emaFast) < need)
   {
      g_emaVisualStatus = StringFormat("EMA visual: fast CopyBuffer failed (%d)", GetLastError());
      return;
   }
   ResetLastError();
   if(CopyBuffer(g_emaMidHandle, 0, 0, need, emaMid) < need)
   {
      g_emaVisualStatus = StringFormat("EMA visual: mid CopyBuffer failed (%d)", GetLastError());
      return;
   }
   ResetLastError();
   if(CopyTime(_Symbol, _Period, 0, need, barTimes) < need)
   {
      g_emaVisualStatus = StringFormat("EMA visual: CopyTime failed (%d)", GetLastError());
      return;
   }

   int drawFails = 0;
   for(int i = barsToDraw; i >= 1; --i)
   {
      datetime t1 = barTimes[i];
      datetime t2 = barTimes[i - 1];
      if(!UpsertEmaSegment(1, i, t1, emaFast[i], t2, emaFast[i - 1], clrGreen))
         drawFails++;
      if(!UpsertEmaSegment(2, i, t1, emaMid[i],  t2, emaMid[i - 1],  clrOrange))
         drawFails++;
   }

   DeleteExtraEmaSegments(1, barsToDraw + 1);
   DeleteExtraEmaSegments(2, barsToDraw + 1);
   DeleteExtraEmaSegments(3, 1); // Ensure legacy EMA-3 chart objects are removed
   ChartRedraw(0);

   if(drawFails == 0)
      g_emaVisualStatus = StringFormat("EMA visual: drawn (%d bars)", barsToDraw);
   else
      g_emaVisualStatus = StringFormat("EMA visual: partial (%d draw fails)", drawFails);
}

int GetCurrentSignalDirection()
{
   double emaFast[], emaMid[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaMid, true);

   if(CopyBuffer(g_emaFastHandle, 0, 0, 2, emaFast) < 2)
      return DIR_NONE;
   if(CopyBuffer(g_emaMidHandle, 0, 0, 2, emaMid) < 2)
      return DIR_NONE;

   if(emaFast[1] > emaMid[1])
      return DIR_BUY;
   if(emaFast[1] < emaMid[1])
      return DIR_SELL;

   return DIR_NONE;
}

void DrawSignalTextOnChart(const int direction)
{
   if(!InpShowSignalTextOnChart)
      return;
   if(direction != DIR_BUY && direction != DIR_SELL)
      return;

   datetime barTime = iTime(_Symbol, _Period, 1);
   if(barTime == 0)
      return;

   string side = (direction == DIR_BUY ? "BUY" : "SELL");
   string name = StringFormat("EA_SIG_%s_%I64d", side, (long)barTime);
   if(ObjectFind(0, name) >= 0)
      return;

   double high = iHigh(_Symbol, _Period, 1);
   double low  = iLow(_Symbol, _Period, 1);
   if(high <= 0.0 || low <= 0.0)
      return;

   double offset = MathMax(1.0, (double)InpSignalTextOffsetPoints) * _Point;
   double y = (direction == DIR_BUY ? low - offset : high + offset);

   if(!ObjectCreate(0, name, OBJ_TEXT, 0, barTime, y))
      return;

   ObjectSetString(0, name, OBJPROP_TEXT, side);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI Black");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 12);
   ObjectSetInteger(0, name, OBJPROP_COLOR, (direction == DIR_BUY ? C'96,220,128' : C'255,122,122'));
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1100);
}

bool CloseAllOurPositions()
{
   bool allClosed = true;
   for(int pass = 0; pass < 5; ++pass)
   {
      bool found = false;
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsOurPosition())
            continue;

         found = true;
         if(!trade.PositionClose(ticket))
         {
            allClosed = false;
            Print("Close failed. Ticket=", ticket, " Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
      }

      if(!found)
         break;
   }

   return (CountOurPositions() == 0 && allClosed);
}

void ClearReopenRequests()
{
   g_reopenRequestCount = 0;
   ArrayResize(g_reopenRequestDirection, 0);
   ArrayResize(g_reopenRequestClosePrice, 0);
}

void ClearTpRefillQueue()
{
   g_tpRefillQueueCount = 0;
   ArrayResize(g_tpRefillQueueDirection, 0);
   ArrayResize(g_tpRefillQueuePrice, 0);
   ArrayResize(g_tpRefillQueueDueTime, 0);
   ArrayResize(g_tpRefillQueuePositionId, 0);
}

void AddTpRefillQueue(const int direction, const double closePrice, const long positionId)
{
   if(direction != DIR_BUY && direction != DIR_SELL)
      return;
   if(closePrice <= 0.0)
      return;

   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = _Point;
   double tol = tick * 0.5;

   for(int i = 0; i < g_tpRefillQueueCount; ++i)
   {
      if(g_tpRefillQueueDirection[i] != direction)
         continue;
      if(MathAbs(g_tpRefillQueuePrice[i] - closePrice) <= tol)
         return; // avoid duplicate queued refill at same level
   }

   int n = g_tpRefillQueueCount;
   ArrayResize(g_tpRefillQueueDirection, n + 1);
   ArrayResize(g_tpRefillQueuePrice, n + 1);
   ArrayResize(g_tpRefillQueueDueTime, n + 1);
   ArrayResize(g_tpRefillQueuePositionId, n + 1);
   g_tpRefillQueueDirection[n] = direction;
   g_tpRefillQueuePrice[n] = closePrice;
   g_tpRefillQueueDueTime[n] = TimeCurrent() + (int)MathMax(0, InpTpRefillDelaySec);
   g_tpRefillQueuePositionId[n] = positionId;
   g_tpRefillQueueCount = n + 1;
}

void RemoveTpRefillQueueAt(const int index)
{
   if(index < 0 || index >= g_tpRefillQueueCount)
      return;

   for(int i = index; i < g_tpRefillQueueCount - 1; ++i)
   {
      g_tpRefillQueueDirection[i] = g_tpRefillQueueDirection[i + 1];
      g_tpRefillQueuePrice[i] = g_tpRefillQueuePrice[i + 1];
      g_tpRefillQueueDueTime[i] = g_tpRefillQueueDueTime[i + 1];
      g_tpRefillQueuePositionId[i] = g_tpRefillQueuePositionId[i + 1];
   }

   g_tpRefillQueueCount--;
   ArrayResize(g_tpRefillQueueDirection, g_tpRefillQueueCount);
   ArrayResize(g_tpRefillQueuePrice, g_tpRefillQueueCount);
   ArrayResize(g_tpRefillQueueDueTime, g_tpRefillQueueCount);
   ArrayResize(g_tpRefillQueuePositionId, g_tpRefillQueueCount);
}

void ResetPendingAnchor()
{
   g_pendingAnchorPrice = 0.0;
   g_pendingAnchorDirection = DIR_NONE;
   g_forcePendingAnchorActive = false;
   g_forcePendingAnchorDirection = DIR_NONE;
   g_forcePendingAnchorPrice = 0.0;
}

void ResetPendingRetryState()
{
   g_nextPendingRetryTime = 0;
   g_pendingLimitHitThisTick = false;
}

void StartPendingLadderForDirection(const int direction, const string reason)
{
   if(direction != DIR_BUY && direction != DIR_SELL)
      return;

   if(g_activeDirection != direction)
      ResetPendingAnchor();

   ResetPendingRetryState();
   g_activeDirection = direction;

   double marketAnchor = (direction == DIR_BUY)
                       ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                       : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(marketAnchor > 0.0)
   {
      g_pendingAnchorPrice = RoundToTick(marketAnchor);
      NormalizeBaseForMarket(direction, g_pendingAnchorPrice);
      g_pendingAnchorDirection = direction;
   }

   ManageAdvancePendingOrders();

   int pendingNow = CountOurPendingOrders(direction);
   if(pendingNow > 0)
      g_lastActionStatus = StringFormat("Action: %s (%d pending)", reason, pendingNow);
   else
      g_lastActionStatus = StringFormat("Action: %s failed (no pending placed)", reason);
}

void AddReopenRequest(const int direction, const double closePrice)
{
   if(direction != DIR_BUY && direction != DIR_SELL)
      return;
   if(closePrice <= 0.0)
      return;

   int n = g_reopenRequestCount;
   ArrayResize(g_reopenRequestDirection, n + 1);
   ArrayResize(g_reopenRequestClosePrice, n + 1);
   g_reopenRequestDirection[n] = direction;
   g_reopenRequestClosePrice[n] = closePrice;
   g_reopenRequestCount = n + 1;
}

void RemoveReopenRequestAt(const int index)
{
   if(index < 0 || index >= g_reopenRequestCount)
      return;

   for(int i = index; i < g_reopenRequestCount - 1; ++i)
   {
      g_reopenRequestDirection[i] = g_reopenRequestDirection[i + 1];
      g_reopenRequestClosePrice[i] = g_reopenRequestClosePrice[i + 1];
   }

   g_reopenRequestCount--;
   ArrayResize(g_reopenRequestDirection, g_reopenRequestCount);
   ArrayResize(g_reopenRequestClosePrice, g_reopenRequestCount);
}

double GetReopenDistancePrice()
{
   double byPrice  = MathMax(0.0, InpReopenWaitDistancePrice);
   double byPoints = MathMax(0.0, (double)InpReopenWaitDistancePoints) * _Point;

   if(byPrice <= 0.0 && byPoints <= 0.0)
      return 0.0;
   if(byPrice <= 0.0)
      return byPoints;
   if(byPoints <= 0.0)
      return byPrice;

   return MathMax(byPrice, byPoints);
}

bool IsReopenDistanceReached(const int direction, const double closePrice)
{
   double dist = GetReopenDistancePrice();
   if(dist <= 0.0)
      return true;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   if(direction == DIR_BUY)
      return (bid <= closePrice - dist);
   if(direction == DIR_SELL)
      return (ask >= closePrice + dist);

   return false;
}

void ReverseGridToSignal(const int signalDirection)
{
   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);

   bool closed = CloseAllOurPositions();
   CancelAllOurPendingOrders();
   ClearReopenRequests();
   ClearTpRefillQueue();
   g_emaTouchLastCheckedBarTime = 0;
   ResetPendingAnchor();
   ResetPendingRetryState();
   g_activeDirection = signalDirection;

   if(!closed && CountOurPositions() > 0)
   {
      g_lastActionStatus = "Action: reverse blocked (close failed)";
      return;
   }

   g_lastActionStatus = StringFormat("Action: reversed to %s", DirectionToText(signalDirection));

   if(InpOnlyPendingEntries)
   {
      StartPendingLadderForDirection(signalDirection, "Reversed pending");
      return;
   }

   if(CountOurPositions(signalDirection) < InpMaxGridOrders)
   {
      if(OpenGridOrder(signalDirection, "Reverse crossover"))
         ManageAdvancePendingOrders();
   }
}

void StartGridFromDashboard()
{
   g_gridEnabled = true;

   int signalDir = GetCurrentSignalDirection();
   if(signalDir == DIR_NONE)
   {
      g_lastActionStatus = "Action: Start blocked (signal NONE)";
      return;
   }

   bool hasAnyPositions = (CountOurPositions() > 0);
   if(InpDirectionalLock && hasAnyPositions && g_activeDirection != DIR_NONE && signalDir != g_activeDirection)
   {
      g_lastActionStatus = "Action: Start blocked by directional lock";
      return;
   }

   g_activeDirection = signalDir;

   if(CountOurPositions(g_activeDirection) >= InpMaxGridOrders)
   {
      g_lastActionStatus = "Action: Start blocked (max grid orders reached)";
      return;
   }

   if(InpOnlyPendingEntries)
   {
      StartPendingLadderForDirection(g_activeDirection, "Pending start");
      return;
   }

   if(OpenGridOrder(g_activeDirection, "Manual Start Grid", InpBypassSpreadOnManualStart))
   {
      g_lastActionStatus = StringFormat("Action: Grid started (%s)", DirectionToText(g_activeDirection));
      ManageAdvancePendingOrders();
   }
}

void StopGridFromDashboard()
{
   g_gridEnabled = false;
   ClearReopenRequests();
   ClearTpRefillQueue();
   g_emaTouchLastCheckedBarTime = 0;
   CancelAllOurPendingOrders();
   ResetPendingAnchor();
   ResetPendingRetryState();
   g_lastActionStatus = "Action: Grid stopped (new entries paused)";
}

void CloseAllFromDashboard()
{
   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);

   bool closed = CloseAllOurPositions();
   CancelAllOurPendingOrders();
   ClearReopenRequests();
   ClearTpRefillQueue();
   g_emaTouchLastCheckedBarTime = 0;
   ResetPendingAnchor();
   ResetPendingRetryState();

   if(CountOurPositions() == 0)
      g_activeDirection = DIR_NONE;

   if(closed || CountOurPositions() == 0)
      g_lastActionStatus = "Action: all positions closed";
   else
      g_lastActionStatus = "Action: close all partial/failed (check Experts log)";
}

void ProcessPendingReopen()
{
   if(!InpReopenClosedPositions)
   {
      ClearReopenRequests();
      return;
   }

   if(!g_gridEnabled)
      return;

   if(g_reopenRequestCount <= 0)
      return;

   for(int i = g_reopenRequestCount - 1; i >= 0; --i)
   {
      int reopenDir = g_reopenRequestDirection[i];
      double closePrice = g_reopenRequestClosePrice[i];

      if(reopenDir != DIR_BUY && reopenDir != DIR_SELL)
      {
         RemoveReopenRequestAt(i);
         continue;
      }

      if(g_activeDirection != DIR_NONE && reopenDir != g_activeDirection)
      {
         // Stale reopen request from old direction.
         RemoveReopenRequestAt(i);
         continue;
      }

      if(!IsReopenDistanceReached(reopenDir, closePrice))
         continue;

      bool hasAnyPositions = (CountOurPositions() > 0);
      if(InpDirectionalLock && hasAnyPositions && g_activeDirection != DIR_NONE && reopenDir != g_activeDirection)
      {
         RemoveReopenRequestAt(i);
         continue;
      }

      if(g_activeDirection == DIR_NONE)
         g_activeDirection = reopenDir;

      if(CountOurPositions(reopenDir) >= InpMaxGridOrders)
         continue;

      if(InpOnlyPendingEntries)
      {
         RemoveReopenRequestAt(i);
         StartPendingLadderForDirection(reopenDir, "Reopen pending after distance");
         break;
      }

      if(OpenGridOrder(reopenDir, "Reopen After Distance"))
      {
         RemoveReopenRequestAt(i);
         g_lastActionStatus = StringFormat("Action: reopened (%s) after distance move", DirectionToText(reopenDir));
         ManageAdvancePendingOrders();
         break; // one reopen per tick to avoid bursts
      }
   }
}

void ProcessTpRefillQueue()
{
   if(!InpTpHitReplaceInLimit || InpTpRefillLimitMax < 1)
   {
      ClearTpRefillQueue();
      return;
   }

   if(!g_gridEnabled)
      return;

   if(g_tpRefillQueueCount <= 0)
      return;

   datetime now = TimeCurrent();
   for(int i = g_tpRefillQueueCount - 1; i >= 0; --i)
   {
      int dir = g_tpRefillQueueDirection[i];
      double px = g_tpRefillQueuePrice[i];
      datetime due = g_tpRefillQueueDueTime[i];
      long posId = g_tpRefillQueuePositionId[i];

      if(dir != DIR_BUY && dir != DIR_SELL)
      {
         RemoveTpRefillQueueAt(i);
         continue;
      }

      if(g_activeDirection != DIR_NONE && dir != g_activeDirection)
      {
         // stale queue item from previous trend
         RemoveTpRefillQueueAt(i);
         continue;
      }

      if(IsPositionIdentifierStillOpen(posId, dir))
      {
         // Ensure full TP close before placing refill limit.
         RemoveTpRefillQueueAt(i);
         continue;
      }

      if(now < due)
         continue;

      if(PlaceTpRefillLimitOrder(dir, px, "from TP close"))
      {
         g_lastActionStatus = StringFormat("Action: TP refill limit placed (%s)", DirectionToText(dir));
      }

      RemoveTpRefillQueueAt(i);
   }
}

void ProcessTpEmaResetWait()
{
   return; // Disabled in v1.21+
}



void UpdateDashboard()
{
   if(!InpShowDashboard)
   {
      DeleteDashboardObjects();
      return;
   }

   // --- Constants & Colors ---
   // Colors: Dark Theme Professional
   const color CLR_BG_MAIN    = C'18,22,31';   // Deep Slate
   const color CLR_BG_PANEL   = C'28,34,46';   // Lighter Slate
   const color CLR_HEADER_ACC = C'59,130,246'; // Bright Blue
   const color CLR_TEXT_MAIN  = C'241,245,249'; // White-ish
   const color CLR_TEXT_DIM   = C'148,163,184'; // Muted Blue-Grey
   const color CLR_BUY        = C'34,197,94';   // Vibrant Green
   const color CLR_SELL       = C'239,68,68';   // Vibrant Red
   const color CLR_WARN       = C'245,158,11';  // Amber/Orange
   const color CLR_BTN_START  = C'21,128,61';   // Dark Green
   const color CLR_BTN_STOP   = C'185,28,28';   // Dark Red
   const color CLR_BTN_CLOSE  = C'194,65,12';   // Dark Orange

   // --- Gather Data ---
   // Market Checks
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPts = (ask > 0 && bid > 0) ? (ask - bid) / _Point : 0;
   
   // Positions & Pending
   int totalPos   = CountOurPositions();
   int buyPos     = CountOurPositions(DIR_BUY);
   int sellPos    = CountOurPositions(DIR_SELL);
   int pendingAll = CountOurPendingOrders();
   int pendingBuy = CountOurPendingOrders(DIR_BUY);
   int pendingSell= CountOurPendingOrders(DIR_SELL);
   int queueSize  = g_tpRefillQueueCount;
   
   // P/L Calculation
   double floatingPL = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i) {
      if(PositionSelectByTicket(PositionGetTicket(i)) && IsOurPosition())
         floatingPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   color plColor = (floatingPL >= 0) ? CLR_BUY : CLR_SELL;

   // Signal & Direction
   int signalDir = GetCurrentSignalDirection();
   string signalTxt = (signalDir == DIR_BUY) ? "BUY" : (signalDir == DIR_SELL) ? "SELL" : "WAIT";
   color signalClr  = (signalDir == DIR_BUY) ? CLR_BUY : (signalDir == DIR_SELL) ? CLR_SELL : CLR_TEXT_DIM;
   
   string activeDirTxt = (g_activeDirection == DIR_BUY) ? "BUY GRID" : (g_activeDirection == DIR_SELL) ? "SELL GRID" : "NONE";
   color activeDirClr  = (g_activeDirection == DIR_BUY) ? CLR_BUY : (g_activeDirection == DIR_SELL) ? CLR_SELL : CLR_TEXT_DIM;

   // ATR
   double atrVal = 0.0;
   if(g_atrHandle != INVALID_HANDLE) {
      double buff[]; ArraySetAsSeries(buff, true);
      if(CopyBuffer(g_atrHandle, 0, 0, 1, buff) == 1) atrVal = buff[0];
   }

   // --- Layout Configuration ---
   int x = InpDashboardX;
   int y = InpDashboardY;
   int w = 460;     // Increased Width to 460
   int pad = 10;    // Padding

   // Calculate dynamic height
   int h = 400; 

   // Background Panel
   UpsertDashboardRect(DashboardObjectName("PANEL_BG"), x, y, w, h, CLR_BG_MAIN, C'40,45,60');
   
   // HEADER Section
   UpsertDashboardRect(DashboardObjectName("HEADER_BG"), x, y, w, 32, CLR_HEADER_ACC, CLR_HEADER_ACC);
   UpsertDashboardText(DashboardObjectName("TITLE"), x + pad, y + 6, "EMA CROSSOVER GRID", C'255,255,255', 11, "Segoe UI Black");
   string statusTxt = g_gridEnabled ? "RUNNING" : "STOPPED";
   color statusClr  = g_gridEnabled ? C'255,255,255' : C'255,200,200';
   // Use ANCHOR_RIGHT_UPPER to prevent text from overflowing to the right
   UpsertDashboardText(DashboardObjectName("STATUS"), x + w - pad, y + 8, statusTxt, statusClr, 9, "Segoe UI Bold", ANCHOR_RIGHT_UPPER);

   //==============================
// Authorization Logic
//==============================
bool CheckAuthorization()
{
   if(InpAuthUrl == "")
   {
      Print("Auth: URL is empty. Skipping check (Development Mode).");
      return true;
   }

   string cookie=NULL, headers;
   char post[], result[];
   int res;
   
   // Reset last error
   ResetLastError();
   
   // Perform GET request
   res = WebRequest("GET", InpAuthUrl, cookie, NULL, 5000, post, 0, result, headers);
   
   if(res == -1)
   {
      int err = GetLastError();
      string msg = "Auth: WebRequest failed. Error=" + IntegerToString(err);
      if(err == 4060) msg += " (Add URL to Allowed WebRequest in Tools>Options)";
      Alert(msg);
      Print(msg);
      // Fail safely? Or block? User requested "Only Run on Allowed Accounts". So BLOCK.
      return false; 
   }
   
   if(res != 200)
   {
      Alert("Auth: Server returned " + IntegerToString(res));
      return false;
   }
   
   // Parse response
   string content = CharArrayToString(result);
   long myLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   string myLoginStr = IntegerToString(myLogin);
   
   // Simple check: Is my login in the content? 
   // Split by lines to avoid partial matches (e.g. 123 in 12345)
   string lines[];
   int lineCount = StringSplit(content, '\n', lines);
   
   for(int i=0; i<lineCount; i++)
   {
      string line = lines[i];
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == myLoginStr)
      {
         Print("Auth: Account ", myLogin, " is AUTHORIZED.");
         return true;
      }
   }
   
   Alert("Auth: Account " + myLoginStr + " is NOT AUTHORIZED.");
   Print("Auth: Failed. Account not in list.");
   return false;
}
//+------------------------------------------------------------------+ 
   // --- 1. ACCOUNT INFO (Balance, Equity, P/L) ---
   int cy = y + 42; 
   UpsertDashboardRect(DashboardObjectName("CARD_ACCT"), x + pad, cy, w - 2*pad, 55, CLR_BG_PANEL, CLR_BG_PANEL);
   
   // Labels
   UpsertDashboardText(DashboardObjectName("L_BAL"), x + pad*2, cy + 5, "Balance", CLR_TEXT_DIM, 8);
   UpsertDashboardText(DashboardObjectName("V_BAL"), x + pad*2, cy + 20, DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), CLR_TEXT_MAIN, 10, "Segoe UI Semibold");
   
   UpsertDashboardText(DashboardObjectName("L_EQU"), x + pad*2 + 80, cy + 5, "Equity", CLR_TEXT_DIM, 8);
   UpsertDashboardText(DashboardObjectName("V_EQU"), x + pad*2 + 80, cy + 20, DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), CLR_TEXT_MAIN, 10, "Segoe UI Semibold");
   
   UpsertDashboardText(DashboardObjectName("L_PL"), x + pad*2 + 160, cy + 5, "Floating P/L", CLR_TEXT_DIM, 8);
   UpsertDashboardText(DashboardObjectName("V_PL"), x + pad*2 + 160, cy + 18, DoubleToString(floatingPL, 2), plColor, 12, "Segoe UI Bold");

   // --- Last Action (Moved to Header Right) ---
   // Positioned further right
   int actionX = x + w - 220; 
   UpsertDashboardText(DashboardObjectName("L_ACT_ST"), actionX, cy + 5, "Last Action", CLR_TEXT_DIM, 8);
   // Shorten/Format action status if too long?
   // Truncate to ~25 chars? Or wrap? 
   // For now, assume it fits or simple truncation.
   string shortStatus = g_lastActionStatus;
   if(StringLen(shortStatus) > 30) shortStatus = StringSubstr(shortStatus, 0, 27) + "...";
   UpsertDashboardText(DashboardObjectName("V_ACT_ST"), actionX, cy + 20, shortStatus, CLR_WARN, 8, "Segoe UI");

   // --- 2. MARKET & SIGNAL INFO ---
   cy += 65;
   UpsertDashboardRect(DashboardObjectName("CARD_MKT"), x + pad, cy, w - 2*pad, 75, CLR_BG_PANEL, CLR_BG_PANEL);
   
   // Row 1: Symbol | Spread | ATR
   // Increased offsets to prevent overlap (Fix for XAUUSD length)
   UpsertDashboardText(DashboardObjectName("L_SYM"), x + pad*2, cy + 6, "Symbol", CLR_TEXT_DIM, 8);
   UpsertDashboardText(DashboardObjectName("V_SYM"), x + pad*2 + 60, cy + 6, _Symbol, CLR_TEXT_MAIN, 8, "Segoe UI Semibold");
   
   UpsertDashboardText(DashboardObjectName("L_SPR"), x + pad*2 + 150, cy + 6, "Spread", CLR_TEXT_DIM, 8);
   int sprLimit = InpMaxSpreadPoints;
   color sprClr = (spreadPts > sprLimit) ? CLR_SELL : CLR_TEXT_MAIN;
   UpsertDashboardText(DashboardObjectName("V_SPR"), x + pad*2 + 200, cy + 6, DoubleToString(spreadPts, 0) + " pts", sprClr, 8, "Segoe UI Semibold");

   UpsertDashboardText(DashboardObjectName("L_ATR"), x + pad*2 + 270, cy + 6, "Market", CLR_TEXT_DIM, 8);
   UpsertDashboardText(DashboardObjectName("V_ATR"), x + pad*2 + 330, cy + 6, DetermineMarketRegime(), CLR_TEXT_MAIN, 8, "Segoe UI Semibold");

   // Row 2: Active Trend | Signal
   int r2y = cy + 28;
   UpsertDashboardText(DashboardObjectName("L_ACT"), x + pad*2, r2y, "Active Direction:", CLR_TEXT_DIM, 9);
   // Moved value further right to avoid overlapping label "Active Direction:"
   UpsertDashboardText(DashboardObjectName("V_ACT"), x + pad*2 + 130, r2y, activeDirTxt, activeDirClr, 9, "Segoe UI Black");

   int r3y = cy + 48;
   UpsertDashboardText(DashboardObjectName("L_SIG"), x + pad*2, r3y, "Current Signal:", CLR_TEXT_DIM, 9);
   // Moved value further right to adhere to column alignment
   UpsertDashboardText(DashboardObjectName("V_SIG"), x + pad*2 + 130, r3y, signalTxt, signalClr, 9, "Segoe UI Bold");
   
   // --- 3. GRID STATISTICS ---
   cy += 85;
   UpsertDashboardRect(DashboardObjectName("CARD_GRID"), x + pad, cy, w - 2*pad, 80, CLR_BG_PANEL, CLR_BG_PANEL);
   
   // Columns: Positions | Pending
   // Widened column spacing
   int col1 = x + pad*2;
   int col2 = x + pad*2 + 150;
   int col3 = x + pad*2 + 280;
   
   UpsertDashboardText(DashboardObjectName("H_POS"), col1, cy + 5, "Positions", CLR_TEXT_DIM, 8);
   UpsertDashboardText(DashboardObjectName("V_POS"), col1, cy + 20, IntegerToString(totalPos) + " (" + IntegerToString(buyPos) + "B/" + IntegerToString(sellPos) + "S)", CLR_TEXT_MAIN, 10, "Segoe UI Semibold");

   UpsertDashboardText(DashboardObjectName("H_PND"), col2, cy + 5, "Pending Orders", CLR_TEXT_DIM, 8);
   UpsertDashboardText(DashboardObjectName("V_PND"), col2, cy + 20, IntegerToString(pendingAll), CLR_TEXT_MAIN, 10, "Segoe UI Semibold");

   UpsertDashboardText(DashboardObjectName("H_QUE"), col3, cy + 5, "Reopen Q", CLR_TEXT_DIM, 8);
   UpsertDashboardText(DashboardObjectName("V_QUE"), col3, cy + 20, IntegerToString(queueSize), CLR_TEXT_MAIN, 10, "Segoe UI Semibold");

   // Info Line
   string info = "Mode: " + (InpReverseOnOppositeCrossover ? "AUTO REVERSE" : "MANUAL") + " | " + 
                 "Limit Cap: " + IntegerToString(InpHardPendingStopsCap);
   UpsertDashboardText(DashboardObjectName("INF_BOT"), col1, cy + 50, info, CLR_TEXT_DIM, 8);

   // --- 4. ACTION STATUS REMOVED FROM BOTTOM ---
   // It is now in the header.
   // Or keep section title for something else?
   // Nothing needed here for now.

   // --- 5. BUTTONS ---
   // Moved up further to match HMA layout
   int by = y + h - 90; // Was -70
   int bw = (w - 5*pad) / 4; // 4 Buttons
   
   UpsertDashboardButton(DashboardObjectName("BTN_START"), x + pad, by, bw, 32, "START", CLR_BTN_START, C'255,255,255');
   // Darker Green for START NOW
   color clrStartNow = C'20,100,60'; 
   UpsertDashboardButton(DashboardObjectName("BTN_START_NOW"), x + pad*2 + bw, by, bw, 32, "START NOW", clrStartNow, C'255,255,255');
   
   UpsertDashboardButton(DashboardObjectName("BTN_STOP"), x + pad*3 + bw*2, by, bw, 32, "STOP", CLR_BTN_STOP, C'255,255,255');
   UpsertDashboardButton(DashboardObjectName("BTN_CLOSE"), x + pad*4 + bw*3, by, bw, 32, "CLOSE ALL", CLR_BTN_CLOSE, C'255,255,255');

   ChartRedraw(0);
}

double RoundToTick(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = _Point;

   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

bool IsSpreadOK()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   double spreadPoints = (ask - bid) / _Point;
   return (spreadPoints <= InpMaxSpreadPoints);
}

double GetSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return -1.0;

   return (ask - bid) / _Point;
}

bool IsOurPosition()
{
   string symbol = PositionGetString(POSITION_SYMBOL);
   long   magic  = PositionGetInteger(POSITION_MAGIC);
   return (symbol == _Symbol && (ulong)magic == InpMagicNumber);
}

int CountOurPositions(int direction)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      if(direction == DIR_BUY && posType != POSITION_TYPE_BUY)
         continue;
      if(direction == DIR_SELL && posType != POSITION_TYPE_SELL)
         continue;

      count++;
   }
   return count;
}

bool IsPositionIdentifierStillOpen(const long positionId, const int direction)
{
   if(positionId <= 0)
      return false;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;

      long ident = PositionGetInteger(POSITION_IDENTIFIER);
      if(ident != positionId)
         continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      if(direction == DIR_BUY && posType != POSITION_TYPE_BUY)
         continue;
      if(direction == DIR_SELL && posType != POSITION_TYPE_SELL)
         continue;

      return true;
   }

   return false;
}

bool IsOurPendingOrderType(const long orderType, const int direction)
{
   if(direction == DIR_BUY)
      return (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_LIMIT);
   if(direction == DIR_SELL)
      return (orderType == ORDER_TYPE_SELL_STOP || orderType == ORDER_TYPE_SELL_LIMIT);

   return (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP || 
           orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT);
}

bool IsTpRefillLimitOrderType(const long orderType, const int direction)
{
   if(direction == DIR_BUY)
      return (orderType == ORDER_TYPE_BUY_LIMIT);
   if(direction == DIR_SELL)
      return (orderType == ORDER_TYPE_SELL_LIMIT);

   return (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT);
}

bool IsTpRefillLimitOrder(const long orderType, const string comment, const int direction)
{
   if(!InpTpHitReplaceInLimit)
      return false;
   if(!IsTpRefillLimitOrderType(orderType, direction))
      return false;

   return (StringFind(comment, g_tpRefillLimitCommentPrefix, 0) == 0);
}

bool IsAnyPendingOrderType(const long orderType)
{
   return (orderType == ORDER_TYPE_BUY_LIMIT ||
           orderType == ORDER_TYPE_SELL_LIMIT ||
           orderType == ORDER_TYPE_BUY_STOP ||
           orderType == ORDER_TYPE_SELL_STOP ||
           orderType == ORDER_TYPE_BUY_STOP_LIMIT ||
           orderType == ORDER_TYPE_SELL_STOP_LIMIT);
}

int CountTpRefillLimitOrders(const int direction)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol  = OrderGetString(ORDER_SYMBOL);
      long   magic   = OrderGetInteger(ORDER_MAGIC);
      long   type    = OrderGetInteger(ORDER_TYPE);
      string comment = OrderGetString(ORDER_COMMENT);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;
      if(!IsTpRefillLimitOrder(type, comment, direction))
         continue;

      count++;
   }
   return count;
}

bool HasTpRefillLimitNearPrice(const int direction, const double price, const double tol)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol  = OrderGetString(ORDER_SYMBOL);
      long   magic   = OrderGetInteger(ORDER_MAGIC);
      long   type    = OrderGetInteger(ORDER_TYPE);
      string comment = OrderGetString(ORDER_COMMENT);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;
      if(!IsTpRefillLimitOrder(type, comment, direction))
         continue;

      double openPrice = RoundToTick(OrderGetDouble(ORDER_PRICE_OPEN));
      if(MathAbs(openPrice - price) <= tol)
         return true;
   }
   return false;
}

bool DeleteOldestTpRefillLimit(const int direction)
{
   bool found = false;
   ulong oldestTicket = 0;
   datetime oldestTime = 0;

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol  = OrderGetString(ORDER_SYMBOL);
      long   magic   = OrderGetInteger(ORDER_MAGIC);
      long   type    = OrderGetInteger(ORDER_TYPE);
      string comment = OrderGetString(ORDER_COMMENT);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;
      if(!IsTpRefillLimitOrder(type, comment, direction))
         continue;

      datetime setupTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(!found || setupTime < oldestTime)
      {
         found = true;
         oldestTicket = ticket;
         oldestTime = setupTime;
      }
   }

   if(!found || oldestTicket == 0)
      return false;

   return trade.OrderDelete(oldestTicket);
}

bool PlaceTpRefillLimitOrder(const int direction, const double requestedPrice, const string reason)
{
   if(!InpTpHitReplaceInLimit || InpTpRefillLimitMax < 1)
      return false;
   
   string regime = DetermineMarketRegime();
   if(regime == "VOLATILE")
   {
      // In volatile markets, do not place limit orders (let profit run)
      return false;
   }

   if(direction != DIR_BUY && direction != DIR_SELL)
      return false;

   bool terminalTrade = (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   bool mqlTrade      = (bool)MQLInfoInteger(MQL_TRADE_ALLOWED);
   if(!terminalTrade || !mqlTrade)
      return false;

   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);

   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = _Point;
   double tol = tick * 0.5;

   double price = RoundToTick(requestedPrice);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;
      
   // Limit Order Logic validation (BuyLimit below Ask, SellLimit above Bid)
   if(direction == DIR_BUY)
   {
      if(price >= ask) return false; // Immediate fill risk
   }
   else
   {
      if(price <= bid) return false; // Immediate fill risk
   }

   long stopsLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (double)stopsLevelPts * _Point;
   if(minDist < 0.0)
      minDist = 0.0;
      
   // Basic validation retained...

   if(HasTpRefillLimitNearPrice(direction, price, tol))
      return true;

   // Do not place refill at nearly same price as an existing open position.
   if(IsOurPositionNearPrice(direction, price, tol))
      return false;

   while(CountTpRefillLimitOrders(direction) >= InpTpRefillLimitMax)
   {
      if(!DeleteOldestTpRefillLimit(direction))
         break;
   }

   double tp = 0.0;
   bool ok = false;
   string comment = g_tpRefillLimitCommentPrefix;
   if(reason != "")
      comment = comment + " | " + reason;

   if(direction == DIR_BUY)
   {
      tp = RoundToTick(price + GetActiveTP());
      ok = trade.BuyLimit(InpLotSize, price, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, comment);
   }
   else
   {
      tp = RoundToTick(price - GetActiveTP());
      ok = trade.SellLimit(InpLotSize, price, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, comment);
   }

   if(!ok)
   {
      long ret = trade.ResultRetcode();
      if(ret == 10015) // invalid price
      {
         double ask2 = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bid2 = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double retryPrice = price;
         bool retried = false;

         if(direction == DIR_BUY && ask2 > 0.0)
         {
            double maxAllowed2 = ask2 - minDist - (2.0 * tick);
            retryPrice = RoundToTick(MathMin(price, maxAllowed2));
            if(retryPrice > 0.0)
            {
               tp = RoundToTick(retryPrice + GetActiveTP());
               retried = trade.BuyLimit(InpLotSize, retryPrice, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, comment);
            }
         }
         else if(direction == DIR_SELL && bid2 > 0.0)
         {
            double minAllowed2 = bid2 + minDist + (2.0 * tick);
            retryPrice = RoundToTick(MathMax(price, minAllowed2));
            tp = RoundToTick(retryPrice - GetActiveTP());
            retried = trade.SellLimit(InpLotSize, retryPrice, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, comment);
         }

         if(retried)
            return true;
      }

      Print("TP refill limit failed. Retcode=", trade.ResultRetcode(), " Msg=", trade.ResultRetcodeDescription(), " Price=", price);
      return false;
   }

   return true;
}

void PurgeNonStopPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);
      long   magic  = OrderGetInteger(ORDER_MAGIC);
      long   type   = OrderGetInteger(ORDER_TYPE);
      string comment = OrderGetString(ORDER_COMMENT);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;
      if(!IsAnyPendingOrderType(type))
         continue;

      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
      {
         if(IsTpRefillLimitOrder(type, comment, DIR_NONE))
            continue;

         if(trade.OrderDelete(ticket))
            Print("Removed non-stop pending order ticket=", ticket, " type=", type);
      }
   }
}

int CountOurPendingOrders(const int direction = DIR_NONE)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);
      long   magic  = OrderGetInteger(ORDER_MAGIC);
      long   type   = OrderGetInteger(ORDER_TYPE);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;
      if(direction == DIR_NONE)
      {
         if(!IsAnyPendingOrderType(type))
            continue;
      }
      else
      {
         if(!IsOurPendingOrderType(type, direction))
            continue;
      }

      count++;
   }
   return count;
}

void CancelAllOurPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);
      long   magic  = OrderGetInteger(ORDER_MAGIC);
      long   type   = OrderGetInteger(ORDER_TYPE);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;
      if(!IsAnyPendingOrderType(type))
         continue;

      trade.OrderDelete(ticket);
   }
}

void CancelOurPendingStopsOnly(const int direction)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);
      long   magic  = OrderGetInteger(ORDER_MAGIC);
      long   type   = OrderGetInteger(ORDER_TYPE);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;

      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;

      if(direction == DIR_BUY && type != ORDER_TYPE_BUY_STOP)
         continue;
      if(direction == DIR_SELL && type != ORDER_TYPE_SELL_STOP)
         continue;

      trade.OrderDelete(ticket);
   }
}

bool GetDirectionalBasePositionPrice(const int direction, double &basePrice)
{
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      if(direction == DIR_BUY && posType != POSITION_TYPE_BUY)
         continue;
      if(direction == DIR_SELL && posType != POSITION_TYPE_SELL)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(!found)
      {
         basePrice = openPrice;
         found = true;
      }
      else if(direction == DIR_BUY && openPrice > basePrice)
         basePrice = openPrice;
      else if(direction == DIR_SELL && openPrice < basePrice)
         basePrice = openPrice;
   }

   return found;
}

bool GetDirectionalBasePendingPrice(const int direction, double &basePrice)
{
   bool found = false;
   double candidate = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);
      long   magic  = OrderGetInteger(ORDER_MAGIC);
      long   type   = OrderGetInteger(ORDER_TYPE);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;
      if(!IsOurPendingOrderType(type, direction))
         continue;

      double p = RoundToTick(OrderGetDouble(ORDER_PRICE_OPEN));
      if(!found)
      {
         candidate = p;
         found = true;
      }
      else if(direction == DIR_BUY && p < candidate)
         candidate = p;
      else if(direction == DIR_SELL && p > candidate)
         candidate = p;
   }

   if(!found)
      return false;

   if(direction == DIR_BUY)
      basePrice = RoundToTick(candidate - InpGridGapPrice);
   else
      basePrice = RoundToTick(candidate + InpGridGapPrice);

   return true;
}

bool RemoveOneTrailingPendingOrder(const int direction, double &removedPrice)
{
   removedPrice = 0.0;

   bool found = false;
   ulong trailingTicket = 0;
   double trailingPrice = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);
      long   magic  = OrderGetInteger(ORDER_MAGIC);
      long   type   = OrderGetInteger(ORDER_TYPE);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;
      if(!IsOurPendingOrderType(type, direction))
         continue;

      double price = RoundToTick(OrderGetDouble(ORDER_PRICE_OPEN));
      if(!found)
      {
         found = true;
         trailingTicket = ticket;
         trailingPrice = price;
      }
      else if(direction == DIR_BUY && price < trailingPrice)
      {
         trailingTicket = ticket;
         trailingPrice = price;
      }
      else if(direction == DIR_SELL && price > trailingPrice)
      {
         trailingTicket = ticket;
         trailingPrice = price;
      }
   }

   if(!found || trailingTicket == 0)
      return false;

   if(!trade.OrderDelete(trailingTicket))
      return false;

   removedPrice = trailingPrice;
   return true;
}

bool IsPendingPriceValid(const int direction, const double price)
{
   long stopsLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (double)stopsLevelPts * _Point;
   if(minDist < 0.0)
      minDist = 0.0;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   if(direction == DIR_BUY)
      return (price > ask + minDist);
   if(direction == DIR_SELL)
      return (price < bid - minDist);

   return false;
}

void NormalizeBaseForMarket(const int direction, double &basePrice)
{
   if(InpGridGapPrice <= 0.0)
      return;

   long stopsLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (double)stopsLevelPts * _Point;
   if(minDist < 0.0)
      minDist = 0.0;

   int guard = 0;
   if(direction == DIR_BUY)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double threshold = ask + minDist;
      while(basePrice + InpGridGapPrice <= threshold && guard < 1000)
      {
         basePrice += InpGridGapPrice;
         guard++;
      }
   }
   else if(direction == DIR_SELL)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double threshold = bid - minDist;
      while(basePrice - InpGridGapPrice >= threshold && guard < 1000)
      {
         basePrice -= InpGridGapPrice;
         guard++;
      }
   }
}

bool IsOurPositionNearPrice(const int direction, const double price, const double tol)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      if(direction == DIR_BUY && posType != POSITION_TYPE_BUY)
         continue;
      if(direction == DIR_SELL && posType != POSITION_TYPE_SELL)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(openPrice - price) <= tol)
         return true;
   }

   return false;
}

int FindTargetIndexByPrice(const double price, const double &targets[], const double tol)
{
   int n = ArraySize(targets);
   for(int i = 0; i < n; ++i)
   {
      if(MathAbs(price - targets[i]) <= tol)
         return i;
   }
   return -1;
}

bool PlaceAdvancePendingOrder(const int direction, const double entryPrice, const string reason)
{
   bool terminalTrade = (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   bool mqlTrade      = (bool)MQLInfoInteger(MQL_TRADE_ALLOWED);
   if(!terminalTrade || !mqlTrade)
      return false;

   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);

   double price = RoundToTick(entryPrice);
   double tp = 0.0;
   bool ok = false;

   if(direction == DIR_BUY)
   {
      tp = RoundToTick(price + GetActiveTP());
      ok = trade.BuyStop(InpLotSize, price, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, reason);
   }
   else if(direction == DIR_SELL)
   {
      tp = RoundToTick(price - GetActiveTP());
      ok = trade.SellStop(InpLotSize, price, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, reason);
   }

   if(!ok)
   {
      long retcode = trade.ResultRetcode();
      if(retcode == 10033) // TRADE_RETCODE_LIMIT_ORDERS
      {
         g_pendingLimitHitThisTick = true;
         int cooldownSec = (int)MathMax(1, InpPendingRetryCooldownSec);
         g_nextPendingRetryTime = TimeCurrent() + cooldownSec;
         g_lastActionStatus = StringFormat("Action: pending limit hit, retry in %d sec", cooldownSec);
      }

      Print("Pending order failed. Retcode=", trade.ResultRetcode(), " Msg=", trade.ResultRetcodeDescription(), " Price=", price);
      return false;
   }

   return true;
}

void ManageAdvancePendingOrders()
{
   if(!InpEnableAdvancePendingOrders || InpAdvancePendingLimit < 1)
      return;
   if(g_activeDirection == DIR_NONE)
      return;
   if(TimeCurrent() < g_nextPendingRetryTime)
      return;

   g_pendingLimitHitThisTick = false;

   int effectivePendingLimit = InpAdvancePendingLimit;
   if(InpHardPendingStopsCap > 0 && InpHardPendingStopsCap < effectivePendingLimit)
      effectivePendingLimit = InpHardPendingStopsCap;
   if(effectivePendingLimit < 1)
      return;

   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = _Point;
   double tol = tick * 0.5;

   // Collect existing same-direction pending stops, remove opposite/non-stop and duplicates.
   double existingPendingPrices[];
   ArrayResize(existingPendingPrices, 0);
   int pendingCount = 0;
   bool hasPendingFrontier = false;
   double pendingFrontier = 0.0; // BUY: highest pending, SELL: lowest pending

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);
      long   magic  = OrderGetInteger(ORDER_MAGIC);
      long   type   = OrderGetInteger(ORDER_TYPE);
      string comment = OrderGetString(ORDER_COMMENT);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;
      if(!IsAnyPendingOrderType(type))
         continue;

      if(IsTpRefillLimitOrder(type, comment, g_activeDirection))
         continue;

      if(!IsOurPendingOrderType(type, g_activeDirection))
      {
         trade.OrderDelete(ticket); // remove opposite direction or non-stop pending
         continue;
      }

      double price = RoundToTick(OrderGetDouble(ORDER_PRICE_OPEN));
      if(FindTargetIndexByPrice(price, existingPendingPrices, tol) >= 0)
      {
         trade.OrderDelete(ticket); // duplicate at same price
         continue;
      }

      int n = ArraySize(existingPendingPrices);
      ArrayResize(existingPendingPrices, n + 1);
      existingPendingPrices[n] = price;
      pendingCount++;

      if(!hasPendingFrontier)
      {
         pendingFrontier = price;
         hasPendingFrontier = true;
      }
      else if(g_activeDirection == DIR_BUY && price > pendingFrontier)
      {
         pendingFrontier = price;
      }
      else if(g_activeDirection == DIR_SELL && price < pendingFrontier)
      {
         pendingFrontier = price;
      }
   }

   // Enforce hard cap by trimming trailing orders first.
   while(pendingCount > effectivePendingLimit)
   {
      double removedPrice = 0.0;
      if(!RemoveOneTrailingPendingOrder(g_activeDirection, removedPrice))
         break;

      pendingCount--;
      int idx = FindTargetIndexByPrice(removedPrice, existingPendingPrices, tol);
      if(idx >= 0)
      {
         int n = ArraySize(existingPendingPrices);
         for(int k = idx; k < n - 1; ++k)
            existingPendingPrices[k] = existingPendingPrices[k + 1];
         ArrayResize(existingPendingPrices, n - 1);
      }
   }

   if(pendingCount >= effectivePendingLimit)
      return;

   // Find placement frontier:
   // BUY uses highest of (positions/pending), SELL uses lowest of (positions/pending).
   bool hasPosBase = false;
   double posBase = 0.0;
   double frontier = 0.0;
   bool hasFrontier = false;
   if(g_forcePendingAnchorActive && g_forcePendingAnchorDirection == g_activeDirection && g_forcePendingAnchorPrice > 0.0)
   {
      frontier = RoundToTick(g_forcePendingAnchorPrice);
      hasFrontier = true;
      g_forcePendingAnchorActive = false;
      g_forcePendingAnchorDirection = DIR_NONE;
      g_forcePendingAnchorPrice = 0.0;
   }

   if(!hasFrontier)
   {
      if(GetDirectionalBasePositionPrice(g_activeDirection, posBase))
         hasPosBase = true;

      if(hasPosBase)
      {
         frontier = posBase;
         hasFrontier = true;
      }

      if(hasPendingFrontier)
      {
         if(!hasFrontier)
         {
            frontier = pendingFrontier;
            hasFrontier = true;
         }
         else if(g_activeDirection == DIR_BUY && pendingFrontier > frontier)
         {
            frontier = pendingFrontier;
         }
         else if(g_activeDirection == DIR_SELL && pendingFrontier < frontier)
         {
            frontier = pendingFrontier;
         }
      }
   }

   if(!hasFrontier)
   {
      if(g_pendingAnchorDirection == g_activeDirection && g_pendingAnchorPrice > 0.0)
      {
         frontier = g_pendingAnchorPrice;
      }
      else
      {
         frontier = (g_activeDirection == DIR_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      }

      if(frontier <= 0.0)
         return;
   }

   frontier = RoundToTick(frontier);
   g_pendingAnchorPrice = frontier;
   g_pendingAnchorDirection = g_activeDirection;

   int maxPlacePerTick = (int)MathMax(1, InpMaxPendingPlacePerTick);
   int toPlace = (int)MathMin((double)maxPlacePerTick, (double)(effectivePendingLimit - pendingCount));
   int placed = 0;
   int guard = 0;

   while(placed < toPlace && guard < (effectivePendingLimit + 500))
   {
      double nextPrice = (g_activeDirection == DIR_BUY)
                       ? RoundToTick(frontier + InpGridGapPrice)
                       : RoundToTick(frontier - InpGridGapPrice);

      // Advance frontier each step so we extend ladder forward and add only missing count.
      frontier = nextPrice;
      guard++;

      if(!IsPendingPriceValid(g_activeDirection, nextPrice))
         continue;

      if(IsOurPositionNearPrice(g_activeDirection, nextPrice, tol))
         continue;

      if(FindTargetIndexByPrice(nextPrice, existingPendingPrices, tol) >= 0)
         continue;

      if(PlaceAdvancePendingOrder(g_activeDirection, nextPrice, "Advance Pending"))
      {
         int n = ArraySize(existingPendingPrices);
         ArrayResize(existingPendingPrices, n + 1);
         existingPendingPrices[n] = nextPrice;
         placed++;
      }
      else
      {
         if(g_pendingLimitHitThisTick)
            break;

         // For other retcodes, stop this tick to avoid repeated spam.
         break;
      }
   }

   g_pendingAnchorPrice = frontier;
}

bool GetLatestEntryPrice(int direction, double &latestPrice)
{
   datetime latestTime = 0;
   bool     found      = false;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      if(direction == DIR_BUY && posType != POSITION_TYPE_BUY)
         continue;
      if(direction == DIR_SELL && posType != POSITION_TYPE_SELL)
         continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || openTime > latestTime)
      {
         latestTime  = openTime;
         latestPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         found       = true;
      }
   }

   return found;
}

int DetectExistingDirection()
{
   int buyCount  = CountOurPositions(DIR_BUY);
   int sellCount = CountOurPositions(DIR_SELL);

   if(buyCount > 0 && sellCount == 0)
      return DIR_BUY;
   if(sellCount > 0 && buyCount == 0)
      return DIR_SELL;

   return DIR_NONE;
}

bool OpenGridOrder(int direction, const string reason, const bool bypassSpreadFilter = false)
{
   bool terminalTrade = (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   bool mqlTrade      = (bool)MQLInfoInteger(MQL_TRADE_ALLOWED);
   if(!terminalTrade || !mqlTrade)
   {
      g_lastActionStatus = "Action: trading disabled in terminal/EA";
      Print(g_lastActionStatus);
      return false;
   }

   if(!bypassSpreadFilter && !IsSpreadOK())
   {
      double spreadPts = GetSpreadPoints();
      g_lastActionStatus = StringFormat("Action: blocked by spread (%.1f > %d)", spreadPts, InpMaxSpreadPoints);
      Print(g_lastActionStatus);
      return false;
   }

   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
   {
      g_lastActionStatus = "Action: invalid market prices";
      return false;
   }

   bool   ok = false;
   double tp = 0.0;

   if(direction == DIR_BUY)
   {
      tp = RoundToTick(ask + GetActiveTP());
      ok = trade.Buy(InpLotSize, _Symbol, 0.0, 0.0, tp, reason);
   }
   else if(direction == DIR_SELL)
   {
      tp = RoundToTick(bid - GetActiveTP());
      ok = trade.Sell(InpLotSize, _Symbol, 0.0, 0.0, tp, reason);
   }

   if(!ok)
   {
      Print("Order failed. Retcode=", trade.ResultRetcode(), " Msg=", trade.ResultRetcodeDescription());
      g_lastActionStatus = StringFormat("Action: %s failed (%d)", reason, (int)trade.ResultRetcode());
      return false;
   }

   g_lastActionStatus = StringFormat("Action: %s opened (%s)", reason, DirectionToText(direction));
   return true;
}

//==============================
// Crossover Logic
//==============================
bool GetCrossoverSignal(int &signal)
{
   signal = DIR_NONE;

   // Dynamic arrays are required for ArraySetAsSeries in MQL5.
   double emaFast[], emaMid[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaMid, true);

   if(CopyBuffer(g_emaFastHandle, 0, 0, 3, emaFast) < 3)
      return false;
   if(CopyBuffer(g_emaMidHandle, 0, 0, 3, emaMid) < 3)
      return false;

   // Use closed bars (index 2 -> previous, index 1 -> latest closed) for stable crossover detection.
   bool bullishCross = (emaFast[2] <= emaMid[2] && emaFast[1] > emaMid[1]);
   bool bearishCross = (emaFast[2] >= emaMid[2] && emaFast[1] < emaMid[1]);

   datetime signalBarTime = iTime(_Symbol, _Period, 1);
   if(signalBarTime == 0 || signalBarTime == g_lastSignalBarTime)
      return false;

   if(bullishCross)
   {
      g_lastSignalBarTime = signalBarTime;
      signal = DIR_BUY;
      return true;
   }

   if(bearishCross)
   {
      g_lastSignalBarTime = signalBarTime;
      signal = DIR_SELL;
      return true;
   }

   return false;
}

//==============================
// Grid Execution
//==============================
// Step Trailing Stop: Per-position pip-based SL management
// Rule: At 50 pips profit -> SL to breakeven, at 100 pips -> SL locks 50 pips, etc.
//==============================
void ApplyStepTrailingStop()
{
   if(InpTrailStepPips <= 0.0)
      return;

   double stepPriceDistance = InpTrailStepPips * _Point;
   if(stepPriceDistance <= 0.0)
      return;

   long stopsLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = (double)stopsLevelPts * _Point;
   if(minStopDist < 0.0) minStopDist = 0.0;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;

      long   posType   = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      // Calculate current floating profit in price distance
      double priceDist = 0.0;
      if(posType == POSITION_TYPE_BUY)
         priceDist = bid - openPrice;
      else if(posType == POSITION_TYPE_SELL)
         priceDist = openPrice - ask;
      else
         continue;

      // How many complete pip-steps has profit crossed?
      int completedSteps = (int)MathFloor(priceDist / stepPriceDistance);
      if(completedSteps < 1)
         continue; // Not yet at first step

      // Pips to lock = (steps - 1) * stepPips
      // Step 1 (50 pips): lock 0 (breakeven)
      // Step 2 (100 pips): lock 50 pips
      // Step 3 (150 pips): lock 100 pips
      double lockPriceDist = (double)(completedSteps - 1) * stepPriceDistance;

      // Calculate new SL price
      double newSL = 0.0;
      if(posType == POSITION_TYPE_BUY)
      {
         newSL = RoundToTick(openPrice + lockPriceDist);
         if(newSL > bid - minStopDist)
            continue;
      }
      else
      {
         newSL = RoundToTick(openPrice - lockPriceDist);
         if(newSL < ask + minStopDist)
            continue;
      }

      // Only modify if newSL is an improvement over currentSL
      bool shouldModify = false;
      if(posType == POSITION_TYPE_BUY)
         shouldModify = (newSL > currentSL + _Point) || (currentSL == 0.0);
      else
         shouldModify = (currentSL == 0.0) || (newSL < currentSL - _Point);

      if(!shouldModify)
         continue;

      if(trade.PositionModify(ticket, newSL, currentTP))
      {
         double profitPips = priceDist / _Point;
         double lockedPips = lockPriceDist / _Point;
         Print("Trail Step: Ticket #", ticket,
               " Profit=", DoubleToString(profitPips, 1), " pips",
               " Step=", completedSteps,
               " Locked=", DoubleToString(lockedPips, 1), " pips",
               " NewSL=", DoubleToString(newSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      }
   }
}

void ManageActiveGrid()
{
   // Step trailing stop applies to ALL open positions regardless of entry mode
   ApplyStepTrailingStop();

   if(InpOnlyPendingEntries || InpEnableAdvancePendingOrders)
      return;

   if(g_activeDirection == DIR_NONE)
      return;
   
   if(CountOurPositions() == 0)
   {
      if(InpResetDirectionOnFlat)
         g_activeDirection = DIR_NONE;
      return;
   }

   int dirCount = CountOurPositions(g_activeDirection);
   if(dirCount <= 0 || dirCount >= InpMaxGridOrders)
      return;

   double latestEntry = 0.0;
   if(!GetLatestEntryPrice(g_activeDirection, latestEntry))
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return;

   // Buy grid: add orders every gap downward from last buy entry.
   if(g_activeDirection == DIR_BUY)
   {
      double nextBuyLevel = latestEntry - InpGridGapPrice;
      if(bid <= nextBuyLevel)
         OpenGridOrder(DIR_BUY, "Grid BUY");
   }

   // Sell grid: add orders every gap upward from last sell entry.
   if(g_activeDirection == DIR_SELL)
   {
      double nextSellLevel = latestEntry + InpGridGapPrice;
      if(ask >= nextSellLevel)
         OpenGridOrder(DIR_SELL, "Grid SELL");
   }
}

//==============================
// MT5 Event Handlers
//==============================
int OnInit()
{
   if(InpRunM1Only && _Period != PERIOD_M1 && _Period != PERIOD_M5)
   {
      Print("This EA is configured for M1/M5 only. Current timeframe: ", EnumToString(_Period));
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpLotSize <= 0.0 || InpGridGapPrice <= 0.0 || InpTpNormal <= 0.0 || InpMaxGridOrders < 1 || InpAtrPeriod < 1 || InpHardPendingStopsCap < 0 || InpTpRefillDelaySec < 0 || (InpEnableAdvancePendingOrders && InpAdvancePendingLimit < 1) || (InpTpHitReplaceInLimit && InpTpRefillLimitMax < 1))
   {
      Print("Invalid inputs. Check lot size, ATR period, grid gap, take profit, max grid orders, stop pending limits, and TP refill limit count.");
      return INIT_PARAMETERS_INCORRECT;
   }

   // [AUTH CHECK]
   if(!CheckAuthorization())
   {
      return INIT_FAILED;
   }

   // Indicator initialization
   g_emaFastHandle = iMA(_Symbol, _Period, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaMidHandle  = iMA(_Symbol, _Period, InpMidEMAPeriod,  0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle     = iATR(_Symbol, _Period, InpAtrPeriod);

   if(g_emaFastHandle == INVALID_HANDLE || g_emaMidHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA/ATR indicator handles.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber((long)InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);

   if(InpForceObjectsInFront)
      ChartSetInteger(0, CHART_FOREGROUND, false);

   g_gridEnabled = true;
   ClearReopenRequests();
   ClearTpRefillQueue();
   g_emaTouchLastCheckedBarTime = 0;
   g_hmaPaused = false;
   PurgeNonStopPendingOrders();
   g_lastActionStatus = "Action: ready";
   g_activeDirection = DetectExistingDirection();
   ManageAdvancePendingOrders();
   UpdateEmaVisuals();
   UpdateDashboard();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteEmaVisualObjects();
   DeleteDashboardObjects();
   ClearTpRefillQueue();
   g_emaTouchLastCheckedBarTime = 0;

   if(g_emaFastHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaFastHandle);
   if(g_emaMidHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaMidHandle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
}

void OnTick()
{
   // Keep visual EMA lines synced on chart from this single EA file.
   UpdateEmaVisuals();
   UpdateDashboard();
   
   // Verify HMA Exit
   CheckHmaExit();

   if(!g_gridEnabled)
      return;
      
   if(g_hmaPaused)
   {
      // Allow Pending Queue processing (Limits)? Maybe. But stop adding NEW grid orders.
      // We will skip ManageActiveGrid.
      return; 
   }

   PurgeNonStopPendingOrders();
   ProcessPendingReopen();
   ProcessTpRefillQueue();
   ProcessTpEmaResetWait();

   // 1) Manage currently active grid on every tick.
   ManageActiveGrid();
   ManageAdvancePendingOrders();

   // 2) Detect fresh crossover signal and start/switch direction if allowed.
   int signal = DIR_NONE;
   if(!GetCrossoverSignal(signal))
      return;

   if(signal == DIR_NONE)
      return;

   DrawSignalTextOnChart(signal);

   bool hasAnyPositions = (CountOurPositions() > 0);
   bool hasAnyPending   = (CountOurPendingOrders() > 0);
   bool gridHasExposure = (hasAnyPositions || hasAnyPending);
   bool oppositeSignal  = (g_activeDirection != DIR_NONE && signal != g_activeDirection);

   if(oppositeSignal && gridHasExposure)
   {
      if(InpReverseOnOppositeCrossover)
      {
         ReverseGridToSignal(signal);
         return;
      }

      if(InpDirectionalLock)
         return;
   }

   if(oppositeSignal)
      CancelAllOurPendingOrders();

   if(oppositeSignal || g_activeDirection == DIR_NONE)
      g_hmaPaused = false; // Reset pause on direction switch

   g_activeDirection = signal;

   if(CountOurPositions(g_activeDirection) < InpMaxGridOrders)
   {
      if(InpOnlyPendingEntries)
      {
         StartPendingLadderForDirection(g_activeDirection, "Crossover pending");
      }
      else
      {
         if(OpenGridOrder(g_activeDirection, "Initial crossover"))
            ManageAdvancePendingOrders();
      }
   }
}

// Refill Logic: When TP is hit in non-volatile market, place Limit Order at Entry Price.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!InpTpHitReplaceInLimit)
      return;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket))
      return;

   string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   long   dealMagic  = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   long   dealEntry  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   long   dealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
   long   dealType   = HistoryDealGetInteger(dealTicket, DEAL_TYPE);

   if(dealSymbol != _Symbol || (ulong)dealMagic != InpMagicNumber)
      return;

   // Reopen only after an exit deal closed by take-profit.
   if(dealEntry != DEAL_ENTRY_OUT || dealReason != DEAL_REASON_TP)
      return;

   int closedDirection = DIR_NONE;
   if(dealType == DEAL_TYPE_SELL)
      closedDirection = DIR_BUY;   // SELL deal closes a BUY position
   else if(dealType == DEAL_TYPE_BUY)
      closedDirection = DIR_SELL;  // BUY deal closes a SELL position

   if(closedDirection == DIR_NONE)
      return;

   if(g_activeDirection != DIR_NONE && closedDirection != g_activeDirection)
      return;
   if(!g_gridEnabled)
      return;

   // Check Market Regime - Skip Refill if Volatile
   string regime = DetermineMarketRegime();
   if(regime == "VOLATILE")
   {
      g_lastActionStatus = "Action: TP hit, refill skipped (Volatile)";
      return;
   }

   // Find original entry price
   long positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(IsPositionIdentifierStillOpen(positionId, closedDirection))
      return; // Should be closed, but double check

   double entryPrice = 0.0;
   if(HistorySelectByPosition(positionId))
   {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong dTicket = HistoryDealGetTicket(i);
         if(dTicket > 0)
         {
            long dEntry = HistoryDealGetInteger(dTicket, DEAL_ENTRY);
            if(dEntry == DEAL_ENTRY_IN)
            {
               entryPrice = HistoryDealGetDouble(dTicket, DEAL_PRICE);
               break; // Found entry
            }
         }
      }
   }
   
   if(entryPrice <= 0.0)
   {
      // Fallback: estimate from Exit Price approx? No, unsafe.
      Print("TP Refill: Could not find entry price for position ", positionId);
      return;
   }

   // Place Limit Order at Entry Price
   if(PlaceTpRefillLimitOrder(closedDirection, entryPrice, "TP Refill"))
   {
      g_lastActionStatus = StringFormat("Action: TP hit, Limit Refill placed @ %.2f (%s)", entryPrice, regime);
   }
   else
   {
      g_lastActionStatus = "Action: TP hit, Refill placement failed";
   }
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(!InpShowDashboard)
      return;

   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam == DashboardObjectName("BTN_START"))
   {
      StartGridWaitForSignal();
      UpdateDashboard();
      ChartRedraw();
      return;
   }
   
   if(sparam == DashboardObjectName("BTN_START_NOW"))
   {
      StartGridNowFromDashboard();
      UpdateDashboard();
      ChartRedraw();
      return;
   }

   if(sparam == DashboardObjectName("BTN_STOP"))
   {
      StopGridFromDashboard();
      UpdateDashboard();
      return;
   }

   if(sparam == DashboardObjectName("BTN_CLOSE"))
   {
      CloseAllFromDashboard();
      UpdateDashboard();
      return;
   }
}
