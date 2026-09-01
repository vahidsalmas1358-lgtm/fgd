//+------------------------------------------------------------------+
//|                                       SMC_Institutional_EA.mq5   |
//|   SMART MONEY CONCEPTS / ICT INSTITUTIONAL ORDER-FLOW EXPERT     |
//|                                                                  |
//|   Model implemented (multi-timeframe, non-repainting):           |
//|     1. HTF BIAS      - swing market structure (BOS/CHoCH) on the |
//|                        bias timeframe, optional EMA + 2nd HTF.   |
//|     2. LIQUIDITY MAP - swing pools, EQH/EQL, PDH/PDL, PWH/PWL,   |
//|                        Asian range high/low.                     |
//|     3. MANIPULATION  - liquidity sweep / inducement (wick takes  |
//|                        the pool, body closes back inside).       |
//|     4. CONFIRMATION  - internal CHoCH / MSS on the entry TF in   |
//|                        the direction of bias, validated by       |
//|                        displacement (ATR-scaled) and/or a FVG.   |
//|     5. LOCATION      - premium/discount of the dealing range,    |
//|                        optional OTE (0.618-0.79) refinement.     |
//|     6. POI ENTRY     - order block (last opposing candle before  |
//|                        displacement) and/or FVG, market or limit.|
//|     7. INVALIDATION  - stop beyond the sweep wick / OB / swing.  |
//|     8. TARGET        - next opposing liquidity pool, RR floor.   |
//|     9. MANAGEMENT    - partials, break-even, ATR & structure     |
//|                        trailing, opposite-CHoCH exit, time stop. |
//|    10. PROTECTION    - risk %, daily loss/profit caps, equity DD |
//|                        guard, spread, sessions/killzones, news.  |
//|                                                                  |
//|   Everything is evaluated on CLOSED bars only -> no repainting.  |
//+------------------------------------------------------------------+
#property copyright "SMC Institutional EA"
#property link      "https://www.arena.ai"
#property version   "1.00"
#property description "Smart Money Concepts EA: HTF bias -> liquidity sweep -> CHoCH/MSS + displacement -> OB/FVG/OTE entry -> liquidity target."
#property description "Multi-timeframe, non-repainting, full risk engine, sessions/killzones, news filter, dashboard."

//+------------------------------------------------------------------+
//| ENUMERATIONS                                                     |
//+------------------------------------------------------------------+
enum ENUM_LOGLEVEL
  {
   LOG_SILENT=0,     // Silent
   LOG_TRADES=1,     // Trades only
   LOG_SIGNALS=2,    // Trades + signals
   LOG_DEBUG=3       // Full debug
  };

enum ENUM_BIASMODE
  {
   BIAS_STRUCTURE=0,      // HTF market structure only
   BIAS_STRUCT_EMA=1,     // HTF structure + EMA filter
   BIAS_EMA=2,            // HTF EMA slope/position only
   BIAS_BOTH_HTF=3,       // HTF1 structure must equal HTF2 structure
   BIAS_ANY=4             // No bias filter (both directions allowed)
  };

enum ENUM_ENTRYMODE
  {
   ENTRY_MARKET=0,        // Market on confirmation close
   ENTRY_LIMIT_POI=1,     // Limit order at POI (OB/FVG/OTE)
   ENTRY_LIMIT_ELSE_MKT=2 // Limit at POI, market if price already inside POI
  };

enum ENUM_POIMODE
  {
   POI_OB=0,              // Order block
   POI_FVG=1,             // Fair value gap
   POI_OB_FVG_OVERLAP=2,  // Overlap of OB and FVG (strictest)
   POI_BEST_AVAILABLE=3,  // Overlap > OB > FVG > OTE
   POI_OTE=4              // OTE (0.618-0.79) of the confirmation leg
  };

enum ENUM_SLMODE
  {
   SL_SWEEP=0,            // Beyond the sweep / manipulation wick
   SL_POI=1,              // Beyond the POI (OB/FVG) edge
   SL_STRUCTURE=2,        // Beyond the protected swing point
   SL_ATR=3,              // Pure ATR distance from entry
   SL_WIDEST=4            // Widest of sweep / POI / structure
  };

enum ENUM_TPMODE
  {
   TP_LIQUIDITY=0,        // Next opposing liquidity pool
   TP_RR=1,               // Fixed risk-reward multiple
   TP_LIQ_ELSE_RR=2,      // Liquidity pool if it satisfies min RR, else RR
   TP_RANGE_EXTREME=3     // Opposite extreme of the dealing range
  };

enum ENUM_TRAILMODE
  {
   TRAIL_NONE=0,          // No trailing
   TRAIL_ATR=1,           // ATR trailing
   TRAIL_STRUCTURE=2,     // Structure (swing) trailing
   TRAIL_BOTH=3           // Tightest of ATR and structure
  };

enum ENUM_NEWSIMP
  {
   NEWS_HIGH=0,           // High impact only
   NEWS_MED_HIGH=1,       // Medium + High
   NEWS_ALL=2             // All events
  };

enum ENUM_RISKMODE
  {
   RISK_FIXED_LOT=0,      // Fixed lot size
   RISK_PCT_BALANCE=1,    // % risk of balance
   RISK_PCT_EQUITY=2,     // % risk of equity
   RISK_FIXED_MONEY=3     // Fixed money risk per trade
  };

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=========== 1. GENERAL ==========="
input long           InpMagic              = 20260831;   // Magic number
input string         InpComment            = "SMC-EA";   // Trade comment
input ENUM_LOGLEVEL  InpLogLevel           = LOG_SIGNALS;// Journal verbosity
input bool           InpShowPanel          = true;       // Show dashboard panel
input bool           InpDrawObjects        = true;       // Draw SMC objects on chart
input bool           InpAlertPopup         = false;      // Popup alerts
input bool           InpAlertPush          = false;      // Push notifications
input bool           InpAlertEmail         = false;      // Email alerts

input group "=========== 2. TIMEFRAMES ==========="
input ENUM_TIMEFRAMES InpBiasTF            = PERIOD_H4;  // HTF-1 bias timeframe
input ENUM_TIMEFRAMES InpBiasTF2           = PERIOD_D1;  // HTF-2 confirmation timeframe
input ENUM_TIMEFRAMES InpRangeTF           = PERIOD_H1;  // Dealing-range TF (premium/discount)
input ENUM_TIMEFRAMES InpEntryTF           = PERIOD_M15; // Entry / execution timeframe
input int             InpBarsToAnalyze     = 1200;       // Bars loaded per timeframe

input group "=========== 3. MARKET STRUCTURE ==========="
input int            InpSwingLenHTF        = 8;          // HTF swing pivot length (bars each side)
input int            InpSwingLenRange      = 6;          // Range-TF pivot length
input int            InpSwingLenEntry      = 3;          // Entry-TF internal pivot length
input ENUM_BIASMODE  InpBiasMode           = BIAS_STRUCT_EMA; // Bias determination mode
input int            InpBiasEmaPeriod      = 50;         // Bias EMA period (HTF-1)
input bool           InpAllowReversalModel = true;       // Allow Model-B counter-bias reversals
input bool           InpRequireSwingBOS    = false;      // Require an HTF BOS (not just trend state)
input int            InpBiasMaxAgeBars     = 400;        // Max age (HTF bars) of last structure event

input group "=========== 4. LIQUIDITY ENGINE ==========="
input bool           InpUseSwingPools      = true;       // Use swing highs/lows as liquidity
input bool           InpUseEqualHL         = true;       // Use equal highs / equal lows (EQH/EQL)
input double         InpEqTolATR           = 0.18;       // EQH/EQL tolerance (x ATR)
input bool           InpUsePrevDay         = true;       // Use PDH / PDL
input bool           InpUsePrevWeek        = true;       // Use PWH / PWL
input bool           InpUseAsianRange      = true;       // Use Asian session high / low
input int            InpAsianStartHour     = 0;          // Asian session start hour (server time)
input int            InpAsianEndHour       = 7;          // Asian session end hour (server time)
input int            InpSweepLookback      = 14;         // Max bars since sweep for a valid setup
input double         InpSweepMinPenATR     = 0.03;       // Min sweep penetration beyond pool (x ATR)
input double         InpSweepMaxPenATR     = 3.00;       // Max sweep penetration beyond pool (x ATR)
input bool           InpSweepNeedCloseBack = true;       // Require close back inside the pool

input group "=========== 5. CONFIRMATION (CHoCH / MSS) ==========="
input bool           InpRequireCHoCH       = true;       // Require internal CHoCH/MSS after sweep
input int            InpCHoCHMaxAgeBars    = 8;          // Max bars since CHoCH for entry
input bool           InpRequireDisplacement= true;       // Require displacement on the break leg
input double         InpDispATRMult        = 1.15;       // Displacement candle range >= x ATR
input double         InpDispBodyRatio      = 0.50;       // Min body/range ratio of displacement candle
input bool           InpRequireFVG         = true;       // Require a FVG inside the displacement leg
input double         InpFVGMinATR          = 0.08;       // Min FVG size (x ATR)
input int            InpFVGMinPoints       = 0;          // Min FVG size (points, 0=off)

input group "=========== 6. POINT OF INTEREST (OB / FVG / OTE) ==========="
input ENUM_POIMODE   InpPOIMode            = POI_BEST_AVAILABLE; // POI selection mode
input bool           InpOBUseWicks         = true;       // Order block uses full candle (wick to wick)
input int            InpOBMaxLookback      = 25;         // Max bars back to find the order block
input bool           InpEntryAtOBMid       = true;       // Enter at 50% of the POI (else proximal edge)
input double         InpMitigationPct      = 50.0;       // % into zone that counts as mitigated
input bool           InpRequireOB_Strict   = false;      // Require a valid order block (strict)
input bool           InpSkipMitigatedPOI   = true;       // Skip POIs already mitigated by price
input double         InpMaxEntryDistATR    = 2.5;        // Max distance price->POI to still arm (x ATR)

input group "=========== 7. LOCATION FILTER (PREMIUM / DISCOUNT) ==========="
input bool           InpUsePremDisc        = true;       // Longs in discount / shorts in premium only
input double         InpEquilibrium        = 0.50;       // Equilibrium level of dealing range
input bool           InpUseOTEFilter       = false;      // Require entry inside OTE band
input double         InpOTELow             = 0.618;      // OTE lower bound
input double         InpOTEHigh            = 0.790;      // OTE upper bound

input group "=========== 8. CONFLUENCE SCORING ==========="
input int            InpMinScore           = 6;          // Minimum total score to trade
input int            InpScHTFAlign         = 2;          // Score: aligned with HTF bias
input int            InpScHTF2Align        = 1;          // Score: aligned with HTF-2
input int            InpScSweep            = 2;          // Score: liquidity sweep present
input int            InpScEQ               = 1;          // Score: swept pool was EQH/EQL
input int            InpScMajorLevel       = 1;          // Score: swept pool was PDH/PDL/PWH/PWL/Asia
input int            InpScCHoCH            = 2;          // Score: internal CHoCH/MSS
input int            InpScDisplacement     = 1;          // Score: displacement candle
input int            InpScFVG              = 1;          // Score: FVG in the leg
input int            InpScOB               = 1;          // Score: valid order block
input int            InpScOverlap          = 1;          // Score: OB and FVG overlap
input int            InpScDiscount         = 1;          // Score: correct premium/discount
input int            InpScOTE              = 1;          // Score: inside OTE
input int            InpScKillzone         = 1;          // Score: inside a killzone
input int            InpScRR               = 1;          // Score: RR >= InpScRRLevel
input double         InpScRRLevel          = 3.0;        // RR level that grants the RR score

input group "=========== 9. ENTRY EXECUTION ==========="
input ENUM_ENTRYMODE InpEntryMode          = ENTRY_LIMIT_ELSE_MKT; // Order placement mode
input int            InpLimitExpiryBars    = 12;         // Delete unfilled pending after N entry-TF bars
input int            InpEntryOffsetPoints  = 0;          // Extra offset of limit price (points)
input bool           InpOneTradePerSweep   = true;       // Only one trade per liquidity sweep
input bool           InpOneTradePerBar     = true;       // Max one new order per bar
input int            InpMaxSetupsPerDay    = 4;          // Max new setups per day (0=unlimited)
input int            InpMaxPositions       = 1;          // Max simultaneous EA positions
input bool           InpHedgeOppositeClose = true;       // Close opposite EA positions before entry
input int            InpSlippagePoints     = 20;         // Max deviation (points)
input int            InpOrderRetries       = 3;          // Order send retries

input group "=========== 10. RISK & POSITION SIZING ==========="
input ENUM_RISKMODE  InpRiskMode           = RISK_PCT_BALANCE; // Position sizing mode
input double         InpFixedLot           = 0.10;       // Fixed lot (RISK_FIXED_LOT)
input double         InpRiskPercent        = 1.0;        // Risk per trade (%)
input double         InpFixedMoney         = 100.0;      // Risk per trade (account currency)
input double         InpMaxLotCap          = 20.0;       // Hard maximum lot cap
input double         InpMinFreeMarginPct   = 20.0;       // Skip trade if free margin below %

input group "=========== 11. STOP LOSS / TAKE PROFIT ==========="
input ENUM_SLMODE    InpSLMode             = SL_WIDEST;  // Stop loss anchor
input double         InpSLBufferATR        = 0.25;       // SL buffer (x ATR)
input int            InpSLBufferPoints     = 0;          // SL buffer (extra points)
input int            InpMinSLPoints        = 0;          // Minimum SL distance (points, 0=auto)
input int            InpMaxSLPoints        = 0;          // Maximum SL distance (points, 0=off)
input ENUM_TPMODE    InpTPMode             = TP_LIQ_ELSE_RR; // Take profit mode
input double         InpMinRR              = 2.0;        // Minimum acceptable RR to take the trade
input double         InpRRTarget           = 3.0;        // RR used by TP_RR / fallback
input double         InpLiqTPBufferATR     = 0.10;       // Stop short of the liquidity pool (x ATR)

input group "=========== 12. TRADE MANAGEMENT ==========="
input bool           InpUsePartials        = true;       // Take partial profit at TP1
input double         InpTP1RR              = 1.5;        // TP1 level (RR)
input double         InpPartialPercent     = 50.0;       // % of position closed at TP1
input bool           InpUsePartial2        = true;       // Take a 2nd partial at TP2 (let a runner trail beyond it)
input double         InpTP2RR              = 2.75;       // TP2 level (RR)
input double         InpPartial2Percent    = 25.0;       // % of ORIGINAL volume closed at TP2
input bool           InpUseBreakEven       = true;       // Move to break-even
input double         InpBETriggerRR        = 1.0;        // BE trigger (RR)
input int            InpBEOffsetPoints     = 5;          // BE offset (points, locked profit)
input ENUM_TRAILMODE InpTrailMode          = TRAIL_BOTH; // Trailing mode
input double         InpTrailStartRR       = 1.5;        // Start trailing after (RR)
input int            InpTrailATRPeriod     = 14;         // Trailing ATR period
input double         InpTrailATRMult       = 2.0;        // Trailing ATR multiplier
input int            InpTrailStructLen     = 3;          // Structure trailing pivot length
input int            InpTrailStepPoints    = 10;         // Min improvement to modify stop (points)
input bool           InpCloseOnOppCHoCH    = true;       // Close on opposite internal CHoCH
input int            InpTimeStopBars       = 0;          // Close after N entry-TF bars (0=off)
input bool           InpCloseFriday        = false;      // Close all before weekend
input int            InpFridayCloseHour    = 21;         // Friday close hour (server)
input int            InpFridayNoNewHours   = 2;           // Block NEW entries N hours before Friday close
input bool           InpCheckMarketOpen    = true;        // Skip trading if symbol/market is closed or halted
input int            InpStaleDataMinutes   = 0;           // Treat quotes as stale after N minutes (0=auto: 3 entry-TF bars)

input group "=========== 13. ACCOUNT PROTECTION ==========="
input double         InpMaxDailyLossPct    = 3.0;        // Max daily loss % (0=off) - stops for the day
input double         InpMaxDailyProfitPct  = 0.0;        // Daily profit target % (0=off)
input double         InpMaxTotalDDPct      = 15.0;       // Max equity drawdown % from peak (0=off)
input int            InpMaxTradesPerDay    = 6;          // Max closed+open trades per day (0=off)
input int            InpMaxSpreadPoints    = 35;         // Max allowed spread (points, 0=off)
input int            InpMaxConsecLosses    = 0;          // Pause after N consecutive losses (0=off)
input int            InpPauseBarsAfterLoss = 0;          // Bars to pause after a loss (0=off)

input group "=========== 14. SESSIONS & KILLZONES (server time) ==========="
input bool           InpUseSessionFilter   = true;       // Restrict trading to killzones
input bool           InpKZAsia             = false;      // Asia killzone
input int            InpKZAsiaStart        = 0;          // Asia start hour
input int            InpKZAsiaEnd          = 4;          // Asia end hour
input bool           InpKZLondon           = true;       // London killzone
input int            InpKZLondonStart      = 7;          // London start hour
input int            InpKZLondonEnd        = 11;         // London end hour
input bool           InpKZNewYork          = true;       // New York killzone
input int            InpKZNewYorkStart     = 12;         // New York start hour
input int            InpKZNewYorkEnd       = 17;         // New York end hour
input bool           InpTradeMonday        = true;       // Trade Monday
input bool           InpTradeTuesday       = true;       // Trade Tuesday
input bool           InpTradeWednesday     = true;       // Trade Wednesday
input bool           InpTradeThursday      = true;       // Trade Thursday
input bool           InpTradeFriday        = true;       // Trade Friday
input bool           InpTradeSunday        = false;      // Trade Sunday

input group "=========== 15. NEWS FILTER ==========="
input bool           InpUseNewsFilter      = false;      // Use economic calendar filter
input ENUM_NEWSIMP   InpNewsImportance     = NEWS_HIGH;  // Minimum importance
input int            InpNewsMinutesBefore  = 30;         // Block N minutes before event
input int            InpNewsMinutesAfter   = 30;         // Block N minutes after event
input bool           InpNewsCloseTrades    = false;      // Close open trades before news

input group "=========== 16. PROFITABILITY / QUALITY FILTERS ==========="
input bool           InpUseVolFilter       = true;       // Skip trading in dead/compressed or blow-out volatility
input int            InpVolSlowPeriod      = 100;        // Slow ATR period (regime reference)
input double         InpVolRatioMin        = 0.65;       // Min (fast ATR / slow ATR) to allow trading - avoids chop
input double         InpVolRatioMax        = 2.30;       // Max (fast ATR / slow ATR) to allow trading - avoids blow-out spikes
input bool           InpUseCostFilter      = true;       // Reject setups where spread eats too much of the edge
input double         InpMaxSpreadATRPct    = 12.0;       // Max spread as % of entry-TF ATR

input group "=========== 17. VISUALS ==========="
input color          InpColBullStruct      = clrDodgerBlue;   // Bullish structure
input color          InpColBearStruct      = clrTomato;       // Bearish structure
input color          InpColBullOB          = clrSeaGreen;     // Bullish order block
input color          InpColBearOB          = clrFireBrick;    // Bearish order block
input color          InpColBullFVG         = clrDarkSlateGray;// Bullish FVG
input color          InpColBearFVG         = clrDarkSlateBlue;// Bearish FVG
input color          InpColLiquidity       = clrGoldenrod;    // Liquidity pools
input color          InpColSweep           = clrMagenta;      // Sweep marker
input color          InpColPanelBg         = C'20,24,32';     // Panel background
input color          InpColPanelText       = clrWhiteSmoke;   // Panel text
input int            InpPanelX             = 12;              // Panel X
input int            InpPanelY             = 24;              // Panel Y
input int            InpMaxObjects         = 400;             // Max drawn objects (auto-prune)

//+------------------------------------------------------------------+
//| CONSTANTS / MACROS                                               |
//+------------------------------------------------------------------+
#define SMC_PREFIX      "SMC_"
#define MAX_PIVOTS      600
#define MAX_POOLS       200
#define MAX_FVG         120
#define RANGE_WINDOW    120

//+------------------------------------------------------------------+
//| DATA STRUCTURES                                                  |
//+------------------------------------------------------------------+
struct SPivot
  {
   int      bar;            // series index at build time (0 = current bar)
   datetime time;           // bar open time
   double   price;          // pivot price
   bool     isHigh;         // true = pivot high, false = pivot low
   bool     broken;         // body (close) traded through it -> BOS/CHoCH
   bool     swept;          // wick traded through it, close came back -> liquidity grab
   datetime brokenTime;
   datetime sweptTime;
  };

struct SStruct
  {
   bool     valid;
   int      trend;                 // +1 bullish, -1 bearish, 0 undefined
   int      lastDir;               // direction of last structure event
   bool     lastIsCHoCH;           // last event was a change of character
   datetime lastTime;
   double   lastLevel;
   int      lastBar;
   int      events;
   double   refHigh;   int refHighBar;   datetime refHighTime;   // live unbroken reference high
   double   refLow;    int refLowBar;    datetime refLowTime;    // live unbroken reference low
   double   strongHigh; datetime strongHighTime; int strongHighBar;
   double   strongLow;  datetime strongLowTime;  int strongLowBar;
   double   rangeHigh;  datetime rangeHighTime;  int rangeHighBar;
   double   rangeLow;   datetime rangeLowTime;   int rangeLowBar;
   int      lastSweepDir;          // +1 = sell-side liquidity swept, -1 = buy-side swept
   datetime lastSweepTime;  int lastSweepBar;
   double   lastSweepLevel;  double lastSweepExtreme;
   int      bullBreakBar;   datetime bullBreakTime; double bullBreakLevel; bool bullBreakCHoCH;
   int      bearBreakBar;   datetime bearBreakTime; double bearBreakLevel; bool bearBreakCHoCH;
   int      bullLegStart;          // series index of the low that started the bullish break leg
   int      bearLegStart;          // series index of the high that started the bearish break leg
  };

struct SPool                       // liquidity pool
  {
   int      type;                  // 0 swing, 1 equal H/L, 2 prev day, 3 prev week, 4 asian range
   bool     isHigh;                // buy-side (true) or sell-side (false) liquidity
   double   price;
   datetime time;
   bool     swept;
   datetime sweptTime;
   int      strength;              // how many touches / weight
  };

struct SSweep
  {
   bool     found;
   int      dir;                   // +1 bullish implication (SSL swept), -1 bearish (BSL swept)
   int      bar;                   // series index of the sweeping bar (entry TF)
   datetime time;
   double   poolPrice;
   double   extreme;               // wick extreme of the sweep
   int      poolType;
   bool     wasEqual;
   bool     wasMajor;
  };

struct SZone
  {
   bool     found;
   double   top;
   double   bottom;
   datetime time;
   int      bar;
   int      dir;
  };

struct SSetup
  {
   bool     valid;
   int      dir;                   // +1 buy, -1 sell
   int      model;                 // 1 = continuation, 2 = reversal, 3 = MTF level reaction
   double   entry;
   double   sl;
   double   tp;
   double   tp1;
   double   rr;
   int      score;
   SZone    ob;
   SZone    fvg;
   double   oteLow, oteHigh;
   SSweep   sweep;
   datetime chochTime;
   double   chochLevel;
   bool     hasDisplacement;
   bool     inDiscount;
   bool     inOTE;
   bool     obFvgOverlap;
   string   reason;
   double   legHigh, legLow;
   datetime signature;             // unique id of the originating sweep
  };

//+------------------------------------------------------------------+
//| GLOBAL STATE                                                     |
//+------------------------------------------------------------------+
MqlRates      gEntry[];    int gEntryBars   = 0;
MqlRates      gBias[];     int gBiasBars    = 0;
MqlRates      gBias2[];    int gBias2Bars   = 0;
MqlRates      gRange[];    int gRangeBars   = 0;

SPivot        gPivEntry[]; SStruct gStEntry;
SPivot        gPivBias[];  SStruct gStBias;
SPivot        gPivBias2[]; SStruct gStBias2;
SPivot        gPivRange[]; SStruct gStRange;

SPool         gPools[];    int gPoolCount = 0;

int           hATRentry = INVALID_HANDLE;
int           hATRbias  = INVALID_HANDLE;
int           hATRtrail = INVALID_HANDLE;
int           hATRvolSlow = INVALID_HANDLE;
int           hEMAbias  = INVALID_HANDLE;

double        gPoint = 0.0, gTickSize = 0.0, gTickValue = 0.0;
int           gDigits = 5;
double        gVolMin = 0.01, gVolMax = 100.0, gVolStep = 0.01;
int           gStopLevel = 0, gFreezeLevel = 0;

datetime      gLastEntryBar   = 0;      // last processed entry-TF bar
datetime      gLastOrderBar   = 0;      // bar on which an order was last sent
datetime      gLastSweepSig   = 0;      // signature of the sweep already traded
datetime      gPauseUntilBar  = 0;

int           gBiasDir        = 0;
int           gBias2Dir       = 0;
double        gATRentry = 0.0, gATRbias = 0.0, gATRtrail = 0.0, gATRvolSlow = 0.0, gEMAbias = 0.0;
double        gRangeHigh = 0.0, gRangeLow = 0.0;

datetime      gDayStamp       = 0;
double        gDayStartBalance= 0.0;
double        gDayStartEquity = 0.0;
int           gDaySetups      = 0;
int           gDayTrades      = 0;
double        gPeakEquity     = 0.0;
int           gConsecLosses   = 0;
bool          gHaltedToday    = false;
bool          gHaltedTotal    = false;
string        gHaltReason     = "";

double        gPDH=0, gPDL=0, gPWH=0, gPWL=0, gAsiaH=0, gAsiaL=0;
datetime      gPDTime=0, gPWTime=0, gAsiaTime=0;

SSetup        gLastSetup;
string        gStatusLine     = "Initialising...";
int           gObjCounter     = 0;
ulong         gLastDealChecked= 0;

// statistics
int           gStatTrades=0, gStatWins=0, gStatLosses=0;
double        gStatProfit=0.0, gStatGross=0.0, gStatLoss=0.0;

//+------------------------------------------------------------------+
//| FORWARD DECLARATIONS                                             |
//+------------------------------------------------------------------+
int    IMax(const int a, const int b);
int    IMin(const int a, const int b);
bool   InKillzone();
string ActiveSessionName();
bool   DayAllowed();
bool   SpreadOk();
void   DrawPanel();
void   DrawAnalysis();
double MinStopDistance();
void   EnsureStops(const int dir, const double price, double &sl, double &tp);
double NormalizeVolume(double v);
bool   ClosePositionFull(const ulong ticket, const string why);
bool   ClosePositionPartial(const ulong ticket, const double volume);
bool   ModifyPosition(const ulong ticket, const double sl, const double tp);
int    CountPositions(const int dir);
int    CountOrders(const int dir);
double RangePosition(const double price);

//+------------------------------------------------------------------+
//| SMALL UTILITIES                                                  |
//+------------------------------------------------------------------+
void Log(const ENUM_LOGLEVEL lvl, const string msg)
  {
   if((int)InpLogLevel >= (int)lvl)
      Print("[SMC] ", msg);
  }

double Nrm(const double price)
  {
   if(gTickSize > 0.0)
      return(NormalizeDouble(MathRound(price / gTickSize) * gTickSize, gDigits));
   return(NormalizeDouble(price, gDigits));
  }

double Pts(const double points)
  {
   return(points * gPoint);
  }

double AskP() { return(SymbolInfoDouble(_Symbol, SYMBOL_ASK)); }
double BidP() { return(SymbolInfoDouble(_Symbol, SYMBOL_BID)); }

int SpreadPoints()
  {
   double sp = AskP() - BidP();
   if(gPoint <= 0.0) return(0);
   return((int)MathRound(sp / gPoint));
  }

ENUM_TIMEFRAMES TF(const ENUM_TIMEFRAMES tf)
  {
   return(tf == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)Period() : tf);
  }

string TFName(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(TF(tf));
   StringReplace(s, "PERIOD_", "");
   return(s);
  }

int IMax(const int a, const int b) { return(a > b ? a : b); }
int IMin(const int a, const int b) { return(a < b ? a : b); }

double Clamp(const double v, const double lo, const double hi)
  {
   if(v < lo) return(lo);
   if(v > hi) return(hi);
   return(v);
  }

void Notify(const string subject, const string body)
  {
   if(InpAlertPopup) Alert(subject + " | " + body);
   if(InpAlertPush)  SendNotification(subject + " | " + body);
   if(InpAlertEmail) SendMail(subject, body);
  }

//+------------------------------------------------------------------+
//| DATA ACQUISITION                                                 |
//+------------------------------------------------------------------+
bool FetchRates(const ENUM_TIMEFRAMES tf, MqlRates &r[], int &bars)
  {
   ArraySetAsSeries(r, true);
   int want   = IMax(200, InpBarsToAnalyze);
   int copied = CopyRates(_Symbol, TF(tf), 0, want, r);
   if(copied < 60)
     {
      bars = 0;
      return(false);
     }
   bars = copied;
   return(true);
  }

double GetATR(const int handle)
  {
   if(handle == INVALID_HANDLE) return(0.0);
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 1, 1, buf) < 1) return(0.0);
   return(buf[0]);
  }

double GetEMA(const int handle)
  {
   if(handle == INVALID_HANDLE) return(0.0);
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 1, 1, buf) < 1) return(0.0);
   return(buf[0]);
  }

//+------------------------------------------------------------------+
//| PIVOT DETECTION                                                  |
//+------------------------------------------------------------------+
bool IsPivotHigh(const MqlRates &r[], const int bars, const int idx, const int len)
  {
   if(idx - len < 0 || idx + len >= bars) return(false);
   double h = r[idx].high;
   for(int k = 1; k <= len; k++)
     {
      if(r[idx - k].high >  h) return(false);   // newer side: strictly lower allowed only
      if(r[idx + k].high >= h) return(false);   // older side: strict
     }
   return(true);
  }

bool IsPivotLow(const MqlRates &r[], const int bars, const int idx, const int len)
  {
   if(idx - len < 0 || idx + len >= bars) return(false);
   double l = r[idx].low;
   for(int k = 1; k <= len; k++)
     {
      if(r[idx - k].low <  l) return(false);
      if(r[idx + k].low <= l) return(false);
     }
   return(true);
  }

void AddPivot(SPivot &piv[], const int bar, const datetime t, const double price, const bool isHigh)
  {
   int n = ArraySize(piv);
   if(n >= MAX_PIVOTS)
     {
      // drop the oldest (they are stored oldest -> newest)
      for(int i = 0; i < n - 1; i++) piv[i] = piv[i + 1];
      n--;
      ArrayResize(piv, n);
     }
   ArrayResize(piv, n + 1);
   piv[n].bar        = bar;
   piv[n].time       = t;
   piv[n].price      = price;
   piv[n].isHigh     = isHigh;
   piv[n].broken     = false;
   piv[n].swept      = false;
   piv[n].brokenTime = 0;
   piv[n].sweptTime  = 0;
  }

void MarkPivot(SPivot &piv[], const datetime pivTime, const bool broken, const datetime evTime)
  {
   for(int i = ArraySize(piv) - 1; i >= 0; i--)
     {
      if(piv[i].time == pivTime)
        {
         if(broken) { piv[i].broken = true;  piv[i].brokenTime = evTime; }
         else       { piv[i].swept  = true;  piv[i].sweptTime  = evTime; }
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| MARKET STRUCTURE ENGINE (BOS / CHoCH, non repainting)            |
//| side: 0 = both, +1 = bullish only, -1 = bearish only             |
//+------------------------------------------------------------------+
void CheckBreaks(const MqlRates &r[], const int bars, const int i,
                 SStruct &st, SPivot &piv[], const int side)
  {
//--- bullish break of the reference high
   if(side >= 0 && st.refHighBar > i && st.refHighBar > 0)
     {
      if(r[i].close > st.refHigh)
        {
         bool choch = (st.trend == -1);
         st.lastIsCHoCH = choch;
         st.lastDir     = 1;
         st.lastTime    = r[i].time;
         st.lastLevel   = st.refHigh;
         st.lastBar     = i;
         st.trend       = 1;
         st.events++;
         st.bullBreakBar   = i;
         st.bullBreakTime  = r[i].time;
         st.bullBreakLevel = st.refHigh;
         st.bullBreakCHoCH = choch;
         MarkPivot(piv, st.refHighTime, true, r[i].time);
         //--- the protected low = lowest low between the broken high and the break bar
         int    lb = i;
         double lp = r[i].low;
         for(int k = st.refHighBar; k >= i; k--)
            if(r[k].low < lp) { lp = r[k].low; lb = k; }
         st.refLow        = lp;
         st.refLowBar     = lb;
         st.refLowTime    = r[lb].time;
         st.strongLow     = lp;
         st.strongLowBar  = lb;
         st.strongLowTime = r[lb].time;
         st.bullLegStart  = lb;
         st.refHigh       = 0.0;
         st.refHighBar    = -1;
        }
      else
         if(r[i].high > st.refHigh)
           {
            //--- wick took the highs but body closed back -> buy-side liquidity sweep
            MarkPivot(piv, st.refHighTime, false, r[i].time);
            st.lastSweepDir     = -1;
            st.lastSweepTime    = r[i].time;
            st.lastSweepBar     = i;
            st.lastSweepLevel   = st.refHigh;
            st.lastSweepExtreme = r[i].high;
           }
     }
//--- bearish break of the reference low
   if(side <= 0 && st.refLowBar > i && st.refLowBar > 0)
     {
      if(r[i].close < st.refLow)
        {
         bool choch = (st.trend == 1);
         st.lastIsCHoCH = choch;
         st.lastDir     = -1;
         st.lastTime    = r[i].time;
         st.lastLevel   = st.refLow;
         st.lastBar     = i;
         st.trend       = -1;
         st.events++;
         st.bearBreakBar   = i;
         st.bearBreakTime  = r[i].time;
         st.bearBreakLevel = st.refLow;
         st.bearBreakCHoCH = choch;
         MarkPivot(piv, st.refLowTime, true, r[i].time);
         int    hb = i;
         double hp = r[i].high;
         for(int k = st.refLowBar; k >= i; k--)
            if(r[k].high > hp) { hp = r[k].high; hb = k; }
         st.refHigh        = hp;
         st.refHighBar     = hb;
         st.refHighTime    = r[hb].time;
         st.strongHigh     = hp;
         st.strongHighBar  = hb;
         st.strongHighTime = r[hb].time;
         st.bearLegStart   = hb;
         st.refLow         = 0.0;
         st.refLowBar      = -1;
        }
      else
         if(r[i].low < st.refLow)
           {
            MarkPivot(piv, st.refLowTime, false, r[i].time);
            st.lastSweepDir     = 1;
            st.lastSweepTime    = r[i].time;
            st.lastSweepBar     = i;
            st.lastSweepLevel   = st.refLow;
            st.lastSweepExtreme = r[i].low;
           }
     }
  }

void ResetStruct(SStruct &st)
  {
   st.valid = false;  st.trend = 0;   st.lastDir = 0;  st.lastIsCHoCH = false;
   st.lastTime = 0;   st.lastLevel = 0.0; st.lastBar = -1; st.events = 0;
   st.refHigh = 0.0;  st.refHighBar = -1; st.refHighTime = 0;
   st.refLow  = 0.0;  st.refLowBar  = -1; st.refLowTime  = 0;
   st.strongHigh = 0.0; st.strongHighTime = 0; st.strongHighBar = -1;
   st.strongLow  = 0.0; st.strongLowTime  = 0; st.strongLowBar  = -1;
   st.rangeHigh = 0.0; st.rangeLow = 0.0; st.rangeHighTime = 0; st.rangeLowTime = 0;
   st.rangeHighBar = -1; st.rangeLowBar = -1;
   st.lastSweepDir = 0; st.lastSweepTime = 0; st.lastSweepBar = -1;
   st.lastSweepLevel = 0.0; st.lastSweepExtreme = 0.0;
   st.bullBreakBar = -1; st.bullBreakTime = 0; st.bullBreakLevel = 0.0; st.bullBreakCHoCH = false;
   st.bearBreakBar = -1; st.bearBreakTime = 0; st.bearBreakLevel = 0.0; st.bearBreakCHoCH = false;
   st.bullLegStart = -1; st.bearLegStart = -1;
  }

bool BuildStructure(const MqlRates &r[], const int bars, const int len,
                    SStruct &st, SPivot &piv[])
  {
   ResetStruct(st);
   ArrayResize(piv, 0);
   if(bars < (len * 4 + 12)) return(false);

   int start = bars - len - 2;
   if(start < 2) return(false);

   for(int i = start; i >= 1; i--)
     {
      int p = i + len;
      if(p < bars - len)
        {
         if(IsPivotHigh(r, bars, p, len))
           {
            AddPivot(piv, p, r[p].time, r[p].high, true);
            st.refHigh     = r[p].high;
            st.refHighBar  = p;
            st.refHighTime = r[p].time;
            //--- catch up breaks that already happened while the pivot was not yet confirmed
            for(int j = p - 1; j >= i; j--)
              {
               if(st.refHighBar < 0) break;
               CheckBreaks(r, bars, j, st, piv, 1);
              }
           }
         if(IsPivotLow(r, bars, p, len))
           {
            AddPivot(piv, p, r[p].time, r[p].low, false);
            st.refLow     = r[p].low;
            st.refLowBar  = p;
            st.refLowTime = r[p].time;
            for(int j = p - 1; j >= i; j--)
              {
               if(st.refLowBar < 0) break;
               CheckBreaks(r, bars, j, st, piv, -1);
              }
           }
        }
      CheckBreaks(r, bars, i, st, piv, 0);
     }

//--- dealing range (trailing extremes of the recent window)
   int win = IMin(bars - 2, RANGE_WINDOW);
   double hi = -DBL_MAX, lo = DBL_MAX;
   int hib = 1, lob = 1;
   for(int i = 1; i <= win; i++)
     {
      if(r[i].high > hi) { hi = r[i].high; hib = i; }
      if(r[i].low  < lo) { lo = r[i].low;  lob = i; }
     }
   st.rangeHigh     = hi;
   st.rangeLow      = lo;
   st.rangeHighBar  = hib;
   st.rangeLowBar   = lob;
   st.rangeHighTime = r[hib].time;
   st.rangeLowTime  = r[lob].time;

   if(st.strongHigh <= 0.0) { st.strongHigh = hi; st.strongHighBar = hib; st.strongHighTime = r[hib].time; }
   if(st.strongLow  <= 0.0) { st.strongLow  = lo; st.strongLowBar  = lob; st.strongLowTime  = r[lob].time; }

   st.valid = true;
   return(true);
  }

//+------------------------------------------------------------------+
//| SESSION / DAY / WEEK LEVELS                                      |
//+------------------------------------------------------------------+
void BuildKeyLevels()
  {
   gPDH = gPDL = gPWH = gPWL = gAsiaH = gAsiaL = 0.0;
   gPDTime = gPWTime = gAsiaTime = 0;

//--- previous day
   MqlRates d[];
   ArraySetAsSeries(d, true);
   if(CopyRates(_Symbol, PERIOD_D1, 0, 3, d) >= 2)
     {
      gPDH    = d[1].high;
      gPDL    = d[1].low;
      gPDTime = d[1].time;
     }
//--- previous week
   MqlRates w[];
   ArraySetAsSeries(w, true);
   if(CopyRates(_Symbol, PERIOD_W1, 0, 3, w) >= 2)
     {
      gPWH    = w[1].high;
      gPWL    = w[1].low;
      gPWTime = w[1].time;
     }
//--- asian range of the current (or most recent) session
   if(InpUseAsianRange)
     {
      MqlRates h[];
      ArraySetAsSeries(h, true);
      int n = CopyRates(_Symbol, PERIOD_H1, 0, 72, h);
      if(n > 10)
        {
         double ah = -DBL_MAX, al = DBL_MAX;
         datetime at = 0;
         MqlDateTime mt;
         int  dayFound = -1;
         bool started  = false;
         for(int i = 1; i < n; i++)
           {
            TimeToStruct(h[i].time, mt);
            bool inAsia = false;
            if(InpAsianStartHour <= InpAsianEndHour)
               inAsia = (mt.hour >= InpAsianStartHour && mt.hour < InpAsianEndHour);
            else
               inAsia = (mt.hour >= InpAsianStartHour || mt.hour < InpAsianEndHour);
            if(inAsia)
              {
               if(!started) { dayFound = mt.day_of_year; started = true; }
               if(mt.day_of_year != dayFound) break;
               if(h[i].high > ah) ah = h[i].high;
               if(h[i].low  < al) al = h[i].low;
               at = h[i].time;
              }
            else
               if(started) break;
           }
         if(ah > -DBL_MAX && al < DBL_MAX)
           {
            gAsiaH    = ah;
            gAsiaL    = al;
            gAsiaTime = at;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| LIQUIDITY POOL MAP                                               |
//+------------------------------------------------------------------+
void AddPool(const int type, const bool isHigh, const double price,
             const datetime t, const int strength)
  {
   if(price <= 0.0) return;
   int n = ArraySize(gPools);
//--- merge with an existing pool that is at (almost) the same price
   double tol = MathMax(gATRentry * 0.10, gPoint * 5);
   for(int i = 0; i < n; i++)
     {
      if(gPools[i].isHigh == isHigh && MathAbs(gPools[i].price - price) <= tol)
        {
         gPools[i].strength += strength;
         if(type < gPools[i].type) gPools[i].type = type;
         if(t > gPools[i].time)    gPools[i].time = t;
         return;
        }
     }
   if(n >= MAX_POOLS) return;
   ArrayResize(gPools, n + 1);
   gPools[n].type      = type;
   gPools[n].isHigh    = isHigh;
   gPools[n].price     = price;
   gPools[n].time      = t;
   gPools[n].swept     = false;
   gPools[n].sweptTime = 0;
   gPools[n].strength  = strength;
  }

void BuildLiquidityMap()
  {
   ArrayResize(gPools, 0);

//--- 1. swing pools from the entry timeframe and the range timeframe
   if(InpUseSwingPools)
     {
      int n = ArraySize(gPivEntry);
      for(int i = IMax(0, n - 40); i < n; i++)
         AddPool(0, gPivEntry[i].isHigh, gPivEntry[i].price, gPivEntry[i].time, 1);
      int m = ArraySize(gPivRange);
      for(int i = IMax(0, m - 24); i < m; i++)
         AddPool(0, gPivRange[i].isHigh, gPivRange[i].price, gPivRange[i].time, 2);
     }

//--- 2. equal highs / equal lows (stacked liquidity)
   if(InpUseEqualHL && gATRentry > 0.0)
     {
      double tol = gATRentry * InpEqTolATR;
      int n = ArraySize(gPivEntry);
      for(int i = IMax(0, n - 40); i < n; i++)
        {
         for(int j = i + 1; j < n; j++)
           {
            if(gPivEntry[i].isHigh != gPivEntry[j].isHigh) continue;
            if(MathAbs(gPivEntry[i].price - gPivEntry[j].price) <= tol)
              {
               double lvl = MathMax(gPivEntry[i].price, gPivEntry[j].price);
               if(!gPivEntry[i].isHigh) lvl = MathMin(gPivEntry[i].price, gPivEntry[j].price);
               AddPool(1, gPivEntry[i].isHigh, lvl,
                       (datetime)MathMax((long)gPivEntry[i].time,(long)gPivEntry[j].time), 3);
              }
           }
        }
     }

//--- 3. previous day / previous week / asian range
   if(InpUsePrevDay)
     {
      AddPool(2, true,  gPDH, gPDTime, 3);
      AddPool(2, false, gPDL, gPDTime, 3);
     }
   if(InpUsePrevWeek)
     {
      AddPool(3, true,  gPWH, gPWTime, 4);
      AddPool(3, false, gPWL, gPWTime, 4);
     }
   if(InpUseAsianRange)
     {
      AddPool(4, true,  gAsiaH, gAsiaTime, 2);
      AddPool(4, false, gAsiaL, gAsiaTime, 2);
     }

   gPoolCount = ArraySize(gPools);
  }

//+------------------------------------------------------------------+
//| SWEEP / MANIPULATION DETECTION (entry timeframe)                 |
//| dir = +1 -> looking for a sell-side (low) sweep for a long       |
//+------------------------------------------------------------------+
SSweep DetectSweep(const int dir)
  {
   SSweep s;
   s.found = false; s.dir = 0; s.bar = -1; s.time = 0;
   s.poolPrice = 0.0; s.extreme = 0.0; s.poolType = -1;
   s.wasEqual = false; s.wasMajor = false;

   if(gEntryBars < 20 || gATRentry <= 0.0) return(s);

   int    look   = IMin(InpSweepLookback, gEntryBars - 3);
   double minPen = gATRentry * InpSweepMinPenATR;
   double maxPen = gATRentry * InpSweepMaxPenATR;
   int    bestBar = -1;
   int    bestIdx = -1;
   double bestPen = 0.0;

   for(int p = 0; p < ArraySize(gPools); p++)
     {
      if(dir > 0 && gPools[p].isHigh)  continue;   // long needs a LOW pool swept
      if(dir < 0 && !gPools[p].isHigh) continue;   // short needs a HIGH pool swept
      double lvl = gPools[p].price;
      if(lvl <= 0.0) continue;

      for(int i = 1; i <= look; i++)
        {
         double pen = 0.0;
         bool   hit = false;
         if(dir > 0)
           {
            pen = lvl - gEntry[i].low;
            hit = (pen >= minPen && pen <= maxPen);
            if(hit && InpSweepNeedCloseBack && gEntry[i].close < lvl) hit = false;
           }
         else
           {
            pen = gEntry[i].high - lvl;
            hit = (pen >= minPen && pen <= maxPen);
            if(hit && InpSweepNeedCloseBack && gEntry[i].close > lvl) hit = false;
           }
         if(!hit) continue;

         //--- prefer the most recent sweep; on equal recency prefer the deeper one
         if(bestBar < 0 || i < bestBar || (i == bestBar && pen > bestPen))
           {
            bestBar = i;
            bestIdx = p;
            bestPen = pen;
           }
         break;   // only the most recent hit of this pool matters
        }
     }

   if(bestBar > 0 && bestIdx >= 0)
     {
      s.found     = true;
      s.dir       = dir;
      s.bar       = bestBar;
      s.time      = gEntry[bestBar].time;
      s.poolPrice = gPools[bestIdx].price;
      s.extreme   = (dir > 0 ? gEntry[bestBar].low : gEntry[bestBar].high);
      s.poolType  = gPools[bestIdx].type;
      s.wasEqual  = (gPools[bestIdx].type == 1);
      s.wasMajor  = (gPools[bestIdx].type >= 2);
      //--- extend the extreme over the whole manipulation cluster
      for(int i = 1; i <= bestBar; i++)
        {
         if(dir > 0) s.extreme = MathMin(s.extreme, gEntry[i].low);
         else        s.extreme = MathMax(s.extreme, gEntry[i].high);
        }
      gPools[bestIdx].swept     = true;
      gPools[bestIdx].sweptTime = s.time;
     }
   return(s);
  }

//+------------------------------------------------------------------+
//| DISPLACEMENT DETECTION INSIDE A LEG                              |
//+------------------------------------------------------------------+
bool HasDisplacement(const int dir, const int fromBar, const int toBar)
  {
   if(gATRentry <= 0.0) return(false);
   int hi = IMax(fromBar, toBar);
   int lo = IMin(fromBar, toBar);
   if(lo < 1) lo = 1;
   if(hi >= gEntryBars - 1) hi = gEntryBars - 2;
   for(int i = hi; i >= lo; i--)
     {
      double rng  = gEntry[i].high - gEntry[i].low;
      double body = MathAbs(gEntry[i].close - gEntry[i].open);
      if(rng <= 0.0) continue;
      if(rng < gATRentry * InpDispATRMult) continue;
      if(body / rng < InpDispBodyRatio) continue;
      if(dir > 0 && gEntry[i].close > gEntry[i].open) return(true);
      if(dir < 0 && gEntry[i].close < gEntry[i].open) return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| FAIR VALUE GAP INSIDE A LEG (most recent unmitigated)            |
//+------------------------------------------------------------------+
SZone FindFVG(const int dir, const int fromBar, const int toBar)
  {
   SZone z;
   z.found = false; z.top = 0.0; z.bottom = 0.0; z.time = 0; z.bar = -1; z.dir = dir;

   int hi = IMax(fromBar, toBar);
   int lo = IMin(fromBar, toBar);
   if(lo < 2) lo = 2;
   if(hi > gEntryBars - 3) hi = gEntryBars - 3;
   if(hi <= lo) return(z);

   double minSize = MathMax(gATRentry * InpFVGMinATR, Pts(InpFVGMinPoints));

   for(int j = lo; j <= hi; j++)     // j = middle candle, newest first
     {
      double top = 0.0, bot = 0.0;
      if(dir > 0)
        {
         if(gEntry[j - 1].low <= gEntry[j + 1].high) continue;
         bot = gEntry[j + 1].high;
         top = gEntry[j - 1].low;
        }
      else
        {
         if(gEntry[j - 1].high >= gEntry[j + 1].low) continue;
         top = gEntry[j + 1].low;
         bot = gEntry[j - 1].high;
        }
      if(top - bot < minSize) continue;

      //--- reject if already fully mitigated by later price action
      bool mitigated = false;
      for(int k = j - 2; k >= 1; k--)
        {
         if(dir > 0 && gEntry[k].low  <= bot) { mitigated = true; break; }
         if(dir < 0 && gEntry[k].high >= top) { mitigated = true; break; }
        }
      if(mitigated) continue;

      z.found  = true;
      z.top    = top;
      z.bottom = bot;
      z.bar    = j;
      z.time   = gEntry[j].time;
      return(z);                     // newest qualifying gap
     }
   return(z);
  }

//+------------------------------------------------------------------+
//| ORDER BLOCK (last opposing candle before the displacement leg)   |
//+------------------------------------------------------------------+
SZone FindOrderBlock(const int dir, const int legStartBar, const int legEndBar)
  {
   SZone z;
   z.found = false; z.top = 0.0; z.bottom = 0.0; z.time = 0; z.bar = -1; z.dir = dir;
   if(gEntryBars < 20) return(z);

   int anchor = legStartBar;
   if(anchor < 1) anchor = 1;
   if(anchor > gEntryBars - 3) anchor = gEntryBars - 3;

//--- refine the anchor to the extreme of the leg (origin of the impulse)
   int    lo = IMin(legStartBar, legEndBar);
   int    hi = IMax(legStartBar, legEndBar);
   if(lo < 1) lo = 1;
   if(hi > gEntryBars - 3) hi = gEntryBars - 3;
   double ext = (dir > 0 ? DBL_MAX : -DBL_MAX);
   for(int i = hi; i >= lo; i--)
     {
      if(dir > 0 && gEntry[i].low  < ext) { ext = gEntry[i].low;  anchor = i; }
      if(dir < 0 && gEntry[i].high > ext) { ext = gEntry[i].high; anchor = i; }
     }

//--- walk backwards (older) to find the last opposing candle
   int limit = IMin(anchor + InpOBMaxLookback, gEntryBars - 3);
   for(int i = anchor; i <= limit; i++)
     {
      bool opposing = (dir > 0 ? (gEntry[i].close < gEntry[i].open)
                               : (gEntry[i].close > gEntry[i].open));
      if(!opposing) continue;
      double top, bot;
      if(InpOBUseWicks)
        {
         top = gEntry[i].high;
         bot = gEntry[i].low;
        }
      else
        {
         top = MathMax(gEntry[i].open, gEntry[i].close);
         bot = MathMin(gEntry[i].open, gEntry[i].close);
        }
      if(top - bot <= 0.0) continue;
      z.found  = true;
      z.top    = top;
      z.bottom = bot;
      z.bar    = i;
      z.time   = gEntry[i].time;
      return(z);
     }
   return(z);
  }

//+------------------------------------------------------------------+
//| ZONE MITIGATION TEST                                             |
//+------------------------------------------------------------------+
bool ZoneMitigated(const SZone &z, const int sinceBar)
  {
   if(!z.found) return(true);
   double depth = (z.top - z.bottom) * (InpMitigationPct / 100.0);
   double level = (z.dir > 0 ? z.top - depth : z.bottom + depth);
   int    from  = IMax(1, IMin(sinceBar, z.bar - 1));
   for(int i = from; i >= 1; i--)
     {
      if(z.dir > 0 && gEntry[i].low  <= level) return(true);
      if(z.dir < 0 && gEntry[i].high >= level) return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| HIGHER TIMEFRAME BIAS                                            |
//+------------------------------------------------------------------+
int StructTrendWithAge(const SStruct &st)
  {
   if(!st.valid) return(0);
   if(InpRequireSwingBOS && st.events <= 0) return(0);
   if(InpBiasMaxAgeBars > 0 && st.lastBar >= 0 && st.lastBar > InpBiasMaxAgeBars) return(0);
   return(st.trend);
  }

int ComputeBias()
  {
   int stTrend  = StructTrendWithAge(gStBias);
   int st2Trend = StructTrendWithAge(gStBias2);
   int emaTrend = 0;

   if(gEMAbias > 0.0 && gBiasBars > 2)
     {
      if(gBias[1].close > gEMAbias) emaTrend =  1;
      if(gBias[1].close < gEMAbias) emaTrend = -1;
     }

   gBias2Dir = st2Trend;

   switch(InpBiasMode)
     {
      case BIAS_STRUCTURE:
         return(stTrend);

      case BIAS_STRUCT_EMA:
         if(stTrend != 0 && emaTrend != 0 && stTrend == emaTrend) return(stTrend);
         return(0);

      case BIAS_EMA:
         return(emaTrend);

      case BIAS_BOTH_HTF:
         if(stTrend != 0 && stTrend == st2Trend) return(stTrend);
         return(0);

      case BIAS_ANY:
         return(stTrend != 0 ? stTrend : 0);
     }
   return(stTrend);
  }

//+------------------------------------------------------------------+
//| PREMIUM / DISCOUNT OF THE DEALING RANGE                          |
//+------------------------------------------------------------------+
double RangePosition(const double price)
  {
   double hi = gRangeHigh, lo = gRangeLow;
   if(hi - lo <= 0.0) return(0.5);
   return((price - lo) / (hi - lo));
  }

bool InDiscount(const double price)
  {
   return(RangePosition(price) <= InpEquilibrium);
  }

bool InPremium(const double price)
  {
   return(RangePosition(price) >= InpEquilibrium);
  }

//+------------------------------------------------------------------+
//| LIQUIDITY TARGET SELECTION                                       |
//+------------------------------------------------------------------+
double FindLiquidityTarget(const int dir, const double entry, const double risk)
  {
   double best   = 0.0;
   double minDist= risk * InpMinRR;
   double buf    = gATRentry * InpLiqTPBufferATR;

   for(int i = 0; i < ArraySize(gPools); i++)
     {
      if(dir > 0 && !gPools[i].isHigh) continue;
      if(dir < 0 &&  gPools[i].isHigh) continue;
      if(gPools[i].swept) continue;
      double lvl = gPools[i].price;
      if(lvl <= 0.0) continue;
      double tgt = (dir > 0 ? lvl - buf : lvl + buf);
      double dist= (dir > 0 ? tgt - entry : entry - tgt);
      if(dist < minDist) continue;
      if(best == 0.0) { best = tgt; continue; }
      //--- nearest qualifying pool
      if(dir > 0 && tgt < best) best = tgt;
      if(dir < 0 && tgt > best) best = tgt;
     }

//--- fall back to structural extremes
   if(best == 0.0)
     {
      double ext = (dir > 0 ? MathMax(gStEntry.rangeHigh, gStRange.rangeHigh)
                            : MathMin(gStEntry.rangeLow,  gStRange.rangeLow));
      double dist = (dir > 0 ? ext - entry : entry - ext);
      if(dist >= minDist) best = (dir > 0 ? ext - buf : ext + buf);
     }
   return(best);
  }

//+------------------------------------------------------------------+
//| BROKER STOP DISTANCE COMPLIANCE                                  |
//+------------------------------------------------------------------+
double MinStopDistance()
  {
   double lvl = (double)MathMax(gStopLevel, gFreezeLevel) * gPoint;
   double spr = (AskP() - BidP());
   return(MathMax(lvl, spr) + 2.0 * gPoint);
  }

void EnsureStops(const int dir, const double price, double &sl, double &tp)
  {
   double md = MinStopDistance();
   if(dir > 0)
     {
      if(sl > 0.0 && price - sl < md) sl = price - md;
      if(tp > 0.0 && tp - price < md) tp = price + md;
     }
   else
     {
      if(sl > 0.0 && sl - price < md) sl = price + md;
      if(tp > 0.0 && price - tp < md) tp = price - md;
     }
   sl = Nrm(sl);
   tp = Nrm(tp);
  }

//+------------------------------------------------------------------+
//| SETUP CONSTRUCTION - THE CORE SMC MODEL                          |
//+------------------------------------------------------------------+
void ResetSetup(SSetup &s)
  {
   s.valid = false; s.dir = 0; s.model = 0;
   s.entry = 0.0; s.sl = 0.0; s.tp = 0.0; s.tp1 = 0.0; s.rr = 0.0; s.score = 0;
   s.ob.found = false; s.ob.top = 0; s.ob.bottom = 0; s.ob.bar = -1; s.ob.time = 0; s.ob.dir = 0;
   s.fvg.found = false; s.fvg.top = 0; s.fvg.bottom = 0; s.fvg.bar = -1; s.fvg.time = 0; s.fvg.dir = 0;
   s.oteLow = 0.0; s.oteHigh = 0.0;
   s.sweep.found = false; s.sweep.dir = 0; s.sweep.bar = -1; s.sweep.time = 0;
   s.sweep.poolPrice = 0.0; s.sweep.extreme = 0.0; s.sweep.poolType = -1;
   s.sweep.wasEqual = false; s.sweep.wasMajor = false;
   s.chochTime = 0; s.chochLevel = 0.0;
   s.hasDisplacement = false; s.inDiscount = false; s.inOTE = false; s.obFvgOverlap = false;
   s.reason = ""; s.legHigh = 0.0; s.legLow = 0.0; s.signature = 0;
  }

SSetup BuildSetup(const int dir, const int model)
  {
   SSetup s;
   ResetSetup(s);
   s.dir   = dir;
   s.model = model;

   if(gEntryBars < 40 || gATRentry <= 0.0)
     {
      s.reason = "no data";
      return(s);
     }

//--- 1) MANIPULATION : liquidity sweep in the required direction -------------
   SSweep sw = DetectSweep(dir);
   if(!sw.found)
     {
      s.reason = "no liquidity sweep";
      return(s);
     }
   s.sweep     = sw;
   s.signature = sw.time;

//--- 2) CONFIRMATION : internal CHoCH / MSS in the trade direction -----------
   if(!gStEntry.valid)
     {
      s.reason = "no entry structure";
      return(s);
     }
   int      breakBar   = (dir > 0 ? gStEntry.bullBreakBar  : gStEntry.bearBreakBar);
   datetime breakTime  = (dir > 0 ? gStEntry.bullBreakTime : gStEntry.bearBreakTime);
   double   breakLevel = (dir > 0 ? gStEntry.bullBreakLevel: gStEntry.bearBreakLevel);
   bool     wasCHoCH   = (dir > 0 ? gStEntry.bullBreakCHoCH: gStEntry.bearBreakCHoCH);
   int      legStart   = (dir > 0 ? gStEntry.bullLegStart  : gStEntry.bearLegStart);

   if(breakBar < 0)
     {
      s.reason = "no structure break in direction";
      return(s);
     }
   if(breakBar > sw.bar)                 // break must be AFTER (newer than) the sweep
     {
      s.reason = "structure break older than sweep";
      return(s);
     }
   if(InpCHoCHMaxAgeBars > 0 && breakBar > InpCHoCHMaxAgeBars)
     {
      s.reason = "confirmation too old";
      return(s);
     }
   if(InpRequireCHoCH && !wasCHoCH && gStEntry.trend != dir)
     {
      s.reason = "no CHoCH/MSS";
      return(s);
     }
   s.chochTime  = breakTime;
   s.chochLevel = breakLevel;

//--- leg boundaries (manipulation extreme -> break bar) ----------------------
   int legFrom = IMax(sw.bar, (legStart > 0 ? legStart : sw.bar));
   int legTo   = breakBar;
   if(legFrom <= legTo) legFrom = IMin(gEntryBars - 3, legTo + 2);

   double lh = -DBL_MAX, ll = DBL_MAX;
   for(int i = legFrom; i >= legTo; i--)
     {
      if(gEntry[i].high > lh) lh = gEntry[i].high;
      if(gEntry[i].low  < ll) ll = gEntry[i].low;
     }
   s.legHigh = lh;
   s.legLow  = ll;

//--- 3) DISPLACEMENT ---------------------------------------------------------
   s.hasDisplacement = HasDisplacement(dir, legFrom, legTo);
   if(InpRequireDisplacement && !s.hasDisplacement)
     {
      s.reason = "no displacement";
      return(s);
     }

//--- 4) IMBALANCE / FVG ------------------------------------------------------
   s.fvg = FindFVG(dir, legFrom, legTo);
   if(InpRequireFVG && !s.fvg.found)
     {
      s.reason = "no FVG in leg";
      return(s);
     }

//--- 5) ORDER BLOCK ----------------------------------------------------------
   s.ob = FindOrderBlock(dir, legFrom, legTo);

//--- 6) OTE band of the confirmation leg ------------------------------------
   if(lh > ll)
     {
      double span = lh - ll;
      if(dir > 0)
        {
         s.oteHigh = lh - span * InpOTELow;    // 0.618 retracement
         s.oteLow  = lh - span * InpOTEHigh;   // 0.79  retracement
        }
      else
        {
         s.oteLow  = ll + span * InpOTELow;
         s.oteHigh = ll + span * InpOTEHigh;
        }
     }

//--- overlap of OB and FVG (highest quality POI) -----------------------------
   if(s.ob.found && s.fvg.found)
     {
      double ovTop = MathMin(s.ob.top, s.fvg.top);
      double ovBot = MathMax(s.ob.bottom, s.fvg.bottom);
      s.obFvgOverlap = (ovTop > ovBot);
     }

//--- 7) POI SELECTION AND ENTRY PRICE ---------------------------------------
   double poiTop = 0.0, poiBot = 0.0;
   bool   poiOk  = false;

   if(InpPOIMode == POI_OB && s.ob.found)
     { poiTop = s.ob.top; poiBot = s.ob.bottom; poiOk = true; }
   else if(InpPOIMode == POI_FVG && s.fvg.found)
     { poiTop = s.fvg.top; poiBot = s.fvg.bottom; poiOk = true; }
   else if(InpPOIMode == POI_OB_FVG_OVERLAP && s.obFvgOverlap)
     {
      poiTop = MathMin(s.ob.top, s.fvg.top);
      poiBot = MathMax(s.ob.bottom, s.fvg.bottom);
      poiOk  = true;
     }
   else if(InpPOIMode == POI_OTE && s.oteHigh > s.oteLow)
     { poiTop = s.oteHigh; poiBot = s.oteLow; poiOk = true; }
   else if(InpPOIMode == POI_BEST_AVAILABLE)
     {
      if(s.obFvgOverlap)
        {
         poiTop = MathMin(s.ob.top, s.fvg.top);
         poiBot = MathMax(s.ob.bottom, s.fvg.bottom);
         poiOk  = true;
        }
      else if(s.ob.found)
        { poiTop = s.ob.top; poiBot = s.ob.bottom; poiOk = true; }
      else if(s.fvg.found)
        { poiTop = s.fvg.top; poiBot = s.fvg.bottom; poiOk = true; }
      else if(s.oteHigh > s.oteLow)
        { poiTop = s.oteHigh; poiBot = s.oteLow; poiOk = true; }
     }

   if(InpRequireOB_Strict && !s.ob.found)
     {
      s.reason = "no order block";
      return(s);
     }
   if(!poiOk || poiTop <= poiBot)
     {
      s.reason = "no valid POI";
      return(s);
     }

//--- reject a POI that price has already consumed --------------------------
   if(InpSkipMitigatedPOI)
     {
      SZone poiZone;
      poiZone.found  = true;
      poiZone.top    = poiTop;
      poiZone.bottom = poiBot;
      poiZone.dir    = dir;
      poiZone.bar    = breakBar;
      poiZone.time   = breakTime;
      if(ZoneMitigated(poiZone, breakBar - 1) && InpEntryMode != ENTRY_MARKET)
        {
         s.reason = "POI already mitigated";
         return(s);
        }
     }

   double poiMid = (poiTop + poiBot) * 0.5;
   double entry;
   if(InpEntryMode == ENTRY_MARKET)
      entry = (dir > 0 ? AskP() : BidP());
   else
     {
      if(InpEntryAtOBMid) entry = poiMid;
      else                entry = (dir > 0 ? poiTop : poiBot);   // proximal edge
      entry += (dir > 0 ? -Pts(InpEntryOffsetPoints) : Pts(InpEntryOffsetPoints));
     }
   entry = Nrm(entry);

//--- distance sanity: do not arm a POI that is miles away --------------------
   double ref  = (dir > 0 ? AskP() : BidP());
   double dist = MathAbs(ref - entry);
   if(InpMaxEntryDistATR > 0.0 && dist > gATRentry * InpMaxEntryDistATR)
     {
      s.reason = "POI too far (" + DoubleToString(dist / gATRentry, 2) + " ATR)";
      return(s);
     }

//--- 8) LOCATION FILTER ------------------------------------------------------
   double pos = RangePosition(entry);
   s.inDiscount = (dir > 0 ? (pos <= InpEquilibrium) : (pos >= InpEquilibrium));
   if(InpUsePremDisc && !s.inDiscount)
     {
      s.reason = "wrong premium/discount (" + DoubleToString(pos * 100.0, 1) + "%)";
      return(s);
     }
   s.inOTE = (s.oteHigh > s.oteLow && entry >= s.oteLow && entry <= s.oteHigh);
   if(InpUseOTEFilter && !s.inOTE)
     {
      s.reason = "entry outside OTE";
      return(s);
     }

//--- 9) STOP LOSS ------------------------------------------------------------
   double buffer = gATRentry * InpSLBufferATR + Pts(InpSLBufferPoints);
   double slSweep = (dir > 0 ? sw.extreme - buffer : sw.extreme + buffer);
   double slPOI   = (dir > 0 ? poiBot   - buffer   : poiTop   + buffer);
   double slStruct= (dir > 0 ? (gStEntry.strongLow  > 0.0 ? gStEntry.strongLow  - buffer : slSweep)
                             : (gStEntry.strongHigh > 0.0 ? gStEntry.strongHigh + buffer : slSweep));
   double sl = slSweep;
   switch(InpSLMode)
     {
      case SL_SWEEP:     sl = slSweep;  break;
      case SL_POI:       sl = slPOI;    break;
      case SL_STRUCTURE: sl = slStruct; break;
      case SL_ATR:       sl = (dir > 0 ? entry - gATRentry * MathMax(0.5, InpSLBufferATR * 4.0)
                                       : entry + gATRentry * MathMax(0.5, InpSLBufferATR * 4.0)); break;
      case SL_WIDEST:
         sl = (dir > 0 ? MathMin(MathMin(slSweep, slPOI), slStruct)
                       : MathMax(MathMax(slSweep, slPOI), slStruct));
         break;
     }
   sl = Nrm(sl);

   double risk = MathAbs(entry - sl);
   if(risk <= 0.0)
     {
      s.reason = "invalid stop";
      return(s);
     }
   double minSL = (InpMinSLPoints > 0 ? Pts(InpMinSLPoints) : MinStopDistance());
   if(risk < minSL)
     {
      sl   = (dir > 0 ? entry - minSL : entry + minSL);
      sl   = Nrm(sl);
      risk = MathAbs(entry - sl);
     }
   if(InpMaxSLPoints > 0 && risk > Pts(InpMaxSLPoints))
     {
      s.reason = "stop too wide (" + DoubleToString(risk / gPoint, 0) + " pts)";
      return(s);
     }

//--- 10) TAKE PROFIT ---------------------------------------------------------
   double tp = 0.0;
   double liq = FindLiquidityTarget(dir, entry, risk);
   switch(InpTPMode)
     {
      case TP_LIQUIDITY:
         tp = liq;
         break;
      case TP_RR:
         tp = (dir > 0 ? entry + risk * InpRRTarget : entry - risk * InpRRTarget);
         break;
      case TP_LIQ_ELSE_RR:
         tp = (liq > 0.0 ? liq : (dir > 0 ? entry + risk * InpRRTarget : entry - risk * InpRRTarget));
         break;
      case TP_RANGE_EXTREME:
         tp = (dir > 0 ? gRangeHigh - gATRentry * InpLiqTPBufferATR
                       : gRangeLow  + gATRentry * InpLiqTPBufferATR);
         break;
     }
   if(tp <= 0.0)
     {
      s.reason = "no valid target";
      return(s);
     }
   double reward = (dir > 0 ? tp - entry : entry - tp);
   s.rr = (risk > 0.0 ? reward / risk : 0.0);
   if(s.rr < InpMinRR)
     {
      s.reason = "RR " + DoubleToString(s.rr, 2) + " < min";
      return(s);
     }

   s.entry = entry;
   s.sl    = sl;
   s.tp    = Nrm(tp);
   s.tp1   = Nrm(dir > 0 ? entry + risk * InpTP1RR : entry - risk * InpTP1RR);

//--- 11) CONFLUENCE SCORE ----------------------------------------------------
   int sc = 0;
   if(gBiasDir == dir)  sc += InpScHTFAlign;
   if(gBias2Dir == dir) sc += InpScHTF2Align;
   if(sw.found)      sc += InpScSweep;
   if(sw.wasEqual)   sc += InpScEQ;
   if(sw.wasMajor)   sc += InpScMajorLevel;
   if(wasCHoCH)      sc += InpScCHoCH;
   if(s.hasDisplacement) sc += InpScDisplacement;
   if(s.fvg.found)   sc += InpScFVG;
   if(s.ob.found)    sc += InpScOB;
   if(s.obFvgOverlap)sc += InpScOverlap;
   if(s.inDiscount)  sc += InpScDiscount;
   if(s.inOTE)       sc += InpScOTE;
   if(InKillzone())  sc += InpScKillzone;
   if(s.rr >= InpScRRLevel) sc += InpScRR;
   s.score = sc;

   if(sc < InpMinScore)
     {
      s.reason = "score " + IntegerToString(sc) + " < " + IntegerToString(InpMinScore);
      return(s);
     }

   s.valid  = true;
   s.reason = "OK";
   return(s);
  }

//+------------------------------------------------------------------+
//| FILTERS : SESSIONS, DAYS, SPREAD, NEWS                           |
//+------------------------------------------------------------------+
bool HourInWindow(const int h, const int start, const int end)
  {
   if(start == end) return(true);
   if(start < end)  return(h >= start && h < end);
   return(h >= start || h < end);      // window crossing midnight
  }

bool InKillzone()
  {
   if(!InpUseSessionFilter) return(true);
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(InpKZAsia    && HourInWindow(t.hour, InpKZAsiaStart,    InpKZAsiaEnd))    return(true);
   if(InpKZLondon  && HourInWindow(t.hour, InpKZLondonStart,  InpKZLondonEnd))  return(true);
   if(InpKZNewYork && HourInWindow(t.hour, InpKZNewYorkStart, InpKZNewYorkEnd)) return(true);
   return(false);
  }

string ActiveSessionName()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   string s = "";
   if(HourInWindow(t.hour, InpKZAsiaStart,    InpKZAsiaEnd))    s += "ASIA ";
   if(HourInWindow(t.hour, InpKZLondonStart,  InpKZLondonEnd))  s += "LONDON ";
   if(HourInWindow(t.hour, InpKZNewYorkStart, InpKZNewYorkEnd)) s += "NY ";
   if(s == "") s = "OUT-OF-KZ";
   return(s);
  }

bool DayAllowed()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   switch(t.day_of_week)
     {
      case 0: return(InpTradeSunday);
      case 1: return(InpTradeMonday);
      case 2: return(InpTradeTuesday);
      case 3: return(InpTradeWednesday);
      case 4: return(InpTradeThursday);
      case 5: return(InpTradeFriday);
     }
   return(false);
  }

bool SpreadOk()
  {
   if(InpMaxSpreadPoints <= 0) return(true);
   return(SpreadPoints() <= InpMaxSpreadPoints);
  }

//--- regime filter: refuses new entries when the market is either too
//--- compressed (dead chop -> most SMC "sweeps" are just noise there) or in
//--- an abnormal blow-out (news spike -> stops get run, fills get slipped) --
bool VolatilityRegimeOk(string &why)
  {
   why = "";
   if(!InpUseVolFilter) return(true);
   if(gATRentry <= 0.0 || gATRvolSlow <= 0.0) return(true);   // not enough data yet - don't block
   double ratio = gATRentry / gATRvolSlow;
   if(ratio < InpVolRatioMin)
     { why = StringFormat("volatility too low (%.2fx)", ratio); return(false); }
   if(ratio > InpVolRatioMax)
     { why = StringFormat("volatility blow-out (%.2fx)", ratio); return(false); }
   return(true);
  }

//--- cost filter: rejects a setup when the spread alone already consumes a
//--- large slice of the typical bar range - such trades have a structurally
//--- worse net edge even if the raw signal looks fine ------------------------
bool CostFilterOk(string &why)
  {
   why = "";
   if(!InpUseCostFilter) return(true);
   if(gATRentry <= 0.0) return(true);
   double spreadPrice = AskP() - BidP();
   double pct = spreadPrice / gATRentry * 100.0;
   if(pct > InpMaxSpreadATRPct)
     { why = StringFormat("spread %.1f%% of ATR too costly", pct); return(false); }
   return(true);
  }

//--- blocks NEW entries during the pre-close window on Fridays (and, once the
//--- weekend-flat rule has fired, for the rest of the Friday session) -------
bool FridayEntryWindowOk()
  {
   if(!InpCloseFriday) return(true);
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.day_of_week != 5) return(true);
   int noNewFromHour = InpFridayCloseHour - IMax(0, InpFridayNoNewHours);
   if(noNewFromHour < 0) noNewFromHour = 0;
   return(t.hour < noNewFromHour);
  }

//--- broker-side halt / holiday guard: refuses new entries when the symbol
//--- is not tradable or when quotes have stopped updating (exchange holiday,
//--- feed outage, end-of-week gap, etc.) --------------------------------------
bool MarketOpenOk(string &why)
  {
   why = "";
   if(!InpCheckMarketOpen) return(true);

   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
     { why = "symbol trading disabled"; return(false); }
   if(tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
     { why = "symbol close-only (halted)"; return(false); }

   datetime lastTick = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
   int staleSecs = (InpStaleDataMinutes > 0
                    ? InpStaleDataMinutes * 60
                    : PeriodSeconds(TF(InpEntryTF)) * 3);
   if(lastTick > 0 && TimeCurrent() - lastTick > staleSecs)
     { why = "stale quotes (market likely closed/holiday)"; return(false); }

   return(true);
  }

//--- economic calendar (skipped silently where unsupported) -------------------
bool NewsBlocked(string &evName)
  {
   evName = "";
   if(!InpUseNewsFilter) return(false);
//--- note: the strategy tester does not deliver calendar data, the filter
//--- simply stays inactive there instead of blocking every trade
   string base = StringSubstr(_Symbol, 0, 3);
   string quot = StringSubstr(_Symbol, 3, 3);
   datetime from = TimeCurrent() - (InpNewsMinutesAfter + 5) * 60;
   datetime to   = TimeCurrent() + (InpNewsMinutesBefore + 5) * 60;
   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, NULL, NULL);
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      MqlCalendarCountry ct;
      if(!CalendarCountryById(ev.country_id, ct)) continue;
      string cur = ct.currency;
      if(cur != base && cur != quot) continue;
      bool impOk = false;
      if(InpNewsImportance == NEWS_HIGH)      impOk = (ev.importance == CALENDAR_IMPORTANCE_HIGH);
      else if(InpNewsImportance == NEWS_MED_HIGH) impOk = (ev.importance >= CALENDAR_IMPORTANCE_MODERATE);
      else                                    impOk = (ev.importance != CALENDAR_IMPORTANCE_NONE);
      if(!impOk) continue;
      datetime et = values[i].time;
      if(TimeCurrent() >= et - InpNewsMinutesBefore * 60 &&
         TimeCurrent() <= et + InpNewsMinutesAfter  * 60)
        {
         evName = cur + ": " + ev.name;
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| ACCOUNT / RISK GUARDS                                            |
//+------------------------------------------------------------------+
void RollDailyCounters()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0; t.min = 0; t.sec = 0;
   datetime today = StructToTime(t);
   if(today != gDayStamp)
     {
      gDayStamp        = today;
      gDayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      gDayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      gDaySetups       = 0;
      gDayTrades       = 0;
      gHaltedToday     = false;
      if(gHaltReason != "" && !gHaltedTotal) gHaltReason = "";
      Log(LOG_SIGNALS, "New trading day. Start balance = " + DoubleToString(gDayStartBalance, 2));
     }
  }

double DayProfit()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(gDayStartBalance <= 0.0) return(0.0);
   return(eq - gDayStartBalance);
  }

double DayProfitPct()
  {
   if(gDayStartBalance <= 0.0) return(0.0);
   return(DayProfit() / gDayStartBalance * 100.0);
  }

bool RiskGuardsOk(string &why)
  {
   why = "";
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > gPeakEquity) gPeakEquity = eq;

   if(InpMaxTotalDDPct > 0.0 && gPeakEquity > 0.0)
     {
      double dd = (gPeakEquity - eq) / gPeakEquity * 100.0;
      if(dd >= InpMaxTotalDDPct)
        {
         gHaltedTotal = true;
         gHaltReason  = "MAX DD " + DoubleToString(dd, 2) + "%";
        }
     }
   if(gHaltedTotal) { why = "halted: " + gHaltReason; return(false); }

   if(InpMaxDailyLossPct > 0.0 && DayProfitPct() <= -InpMaxDailyLossPct)
     {
      gHaltedToday = true;
      gHaltReason  = "daily loss " + DoubleToString(DayProfitPct(), 2) + "%";
     }
   if(InpMaxDailyProfitPct > 0.0 && DayProfitPct() >= InpMaxDailyProfitPct)
     {
      gHaltedToday = true;
      gHaltReason  = "daily target " + DoubleToString(DayProfitPct(), 2) + "%";
     }
   if(gHaltedToday) { why = "halted today: " + gHaltReason; return(false); }

   if(InpMaxTradesPerDay > 0 && gDayTrades >= InpMaxTradesPerDay)
     { why = "max trades/day"; return(false); }
   if(InpMaxSetupsPerDay > 0 && gDaySetups >= InpMaxSetupsPerDay)
     { why = "max setups/day"; return(false); }
   if(InpMaxConsecLosses > 0 && gConsecLosses >= InpMaxConsecLosses)
     { why = "consecutive losses"; return(false); }
   if(gPauseUntilBar > 0 && TimeCurrent() < gPauseUntilBar)
     { why = "cool-down"; return(false); }

   double freeMarginPct = 0.0;
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   if(eq > 0.0) freeMarginPct = (eq - margin) / eq * 100.0;
   if(InpMinFreeMarginPct > 0.0 && freeMarginPct < InpMinFreeMarginPct)
     { why = "free margin " + DoubleToString(freeMarginPct, 1) + "%"; return(false); }

   return(true);
  }

//+------------------------------------------------------------------+
//| POSITION / ORDER COUNTING                                        |
//+------------------------------------------------------------------+
int CountPositions(const int dir)
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(dir > 0 && type != POSITION_TYPE_BUY)  continue;
      if(dir < 0 && type != POSITION_TYPE_SELL) continue;
      c++;
     }
   return(c);
  }

int CountOrders(const int dir)
  {
   int c = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      long type = OrderGetInteger(ORDER_TYPE);
      bool isBuy = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP);
      if(dir > 0 && !isBuy) continue;
      if(dir < 0 &&  isBuy) continue;
      c++;
     }
   return(c);
  }

//+------------------------------------------------------------------+
//| POSITION SIZING                                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(double v)
  {
   if(gVolStep <= 0.0) gVolStep = 0.01;
   v = MathFloor(v / gVolStep + 0.0000001) * gVolStep;
   if(v < gVolMin) v = gVolMin;
   if(v > gVolMax) v = gVolMax;
   if(InpMaxLotCap > 0.0 && v > InpMaxLotCap) v = InpMaxLotCap;
   int  dgt = 2;
   if(gVolStep >= 1.0)       dgt = 0;
   else if(gVolStep >= 0.1)  dgt = 1;
   else if(gVolStep >= 0.01) dgt = 2;
   else                      dgt = 3;
   return(NormalizeDouble(v, dgt));
  }

double MoneyPerLotForDistance(const double distance)
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0) tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0) ts = gPoint;
   if(ts <= 0.0 || tv <= 0.0) return(0.0);
   return(distance / ts * tv);
  }

double CalcLot(const int dir, const double entry, const double sl)
  {
   double distance = MathAbs(entry - sl);
   if(distance <= 0.0) return(0.0);

   double lots = InpFixedLot;
   if(InpRiskMode != RISK_FIXED_LOT)
     {
      double riskMoney = 0.0;
      if(InpRiskMode == RISK_PCT_BALANCE)
         riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      else if(InpRiskMode == RISK_PCT_EQUITY)
         riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
      else
         riskMoney = InpFixedMoney;

      double perLot = MoneyPerLotForDistance(distance);
      if(perLot <= 0.0)
        {
         Log(LOG_TRADES, "Cannot compute tick value - falling back to fixed lot");
         lots = InpFixedLot;
        }
      else
         lots = riskMoney / perLot;
     }

   lots = NormalizeVolume(lots);

//--- margin validation, step down until affordable
   ENUM_ORDER_TYPE ot = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double price = (dir > 0 ? AskP() : BidP());
   double margin = 0.0;
   int guard = 0;
   while(lots >= gVolMin && guard < 200)
     {
      if(!OrderCalcMargin(ot, _Symbol, lots, price, margin)) break;
      if(margin <= AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9) break;
      lots = NormalizeVolume(lots - gVolStep);
      guard++;
      if(lots <= gVolMin) break;
     }
   return(lots);
  }

//+------------------------------------------------------------------+
//| ORDER EXECUTION                                                  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING PickFilling()
  {
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return(ORDER_FILLING_FOK);
   if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return(ORDER_FILLING_IOC);
   return(ORDER_FILLING_RETURN);
  }

bool SendMarket(const int dir, const double lots, const double sl, const double tp, const string tag)
  {
   MqlTradeRequest  req;
   MqlTradeResult   res;
   for(int attempt = 0; attempt < IMax(1, InpOrderRetries); attempt++)
     {
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.volume       = lots;
      req.type         = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      req.price        = Nrm(dir > 0 ? AskP() : BidP());
      double s = sl, t = tp;
      EnsureStops(dir, req.price, s, t);
      req.sl           = s;
      req.tp           = t;
      req.deviation    = InpSlippagePoints;
      req.magic        = InpMagic;
      req.comment      = InpComment + "|" + tag;
      req.type_filling = PickFilling();

      if(OrderSend(req, res))
        {
         if(res.retcode == TRADE_RETCODE_DONE     ||
            res.retcode == TRADE_RETCODE_PLACED   ||
            res.retcode == TRADE_RETCODE_DONE_PARTIAL)
           {
            Log(LOG_TRADES, StringFormat("MARKET %s %.2f lots @ %.*f SL %.*f TP %.*f (%s)",
                (dir > 0 ? "BUY" : "SELL"), lots, gDigits, res.price, gDigits, s, gDigits, t, tag));
            return(true);
           }
        }
      Log(LOG_TRADES, StringFormat("Order attempt %d failed: retcode=%d %s",
          attempt + 1, res.retcode, res.comment));
      if(res.retcode == TRADE_RETCODE_NO_MONEY ||
         res.retcode == TRADE_RETCODE_INVALID_VOLUME ||
         res.retcode == TRADE_RETCODE_TRADE_DISABLED ||
         res.retcode == TRADE_RETCODE_MARKET_CLOSED) break;
      Sleep(300);
     }
   return(false);
  }

bool SendLimit(const int dir, const double lots, const double price,
               const double sl, const double tp, const string tag)
  {
   MqlTradeRequest req;
   MqlTradeResult  res;
   double md   = MinStopDistance();
   double ref  = (dir > 0 ? AskP() : BidP());
   double px   = Nrm(price);

//--- a limit must sit on the correct side of the market
   if(dir > 0 && px > ref - md) return(false);
   if(dir < 0 && px < ref + md) return(false);

   for(int attempt = 0; attempt < IMax(1, InpOrderRetries); attempt++)
     {
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_PENDING;
      req.symbol       = _Symbol;
      req.volume       = lots;
      req.type         = (dir > 0 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
      req.price        = px;
      double s = sl, t = tp;
      EnsureStops(dir, px, s, t);
      req.sl           = s;
      req.tp           = t;
      req.magic        = InpMagic;
      req.comment      = InpComment + "|" + tag;
      req.type_filling = PickFilling();
      req.type_time    = ORDER_TIME_GTC;

      if(OrderSend(req, res))
        {
         if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
           {
            Log(LOG_TRADES, StringFormat("LIMIT %s %.2f lots @ %.*f SL %.*f TP %.*f (%s)",
                (dir > 0 ? "BUY" : "SELL"), lots, gDigits, px, gDigits, s, gDigits, t, tag));
            return(true);
           }
        }
      Log(LOG_TRADES, StringFormat("Pending attempt %d failed: retcode=%d %s",
          attempt + 1, res.retcode, res.comment));
      if(res.retcode == TRADE_RETCODE_NO_MONEY ||
         res.retcode == TRADE_RETCODE_INVALID_VOLUME ||
         res.retcode == TRADE_RETCODE_TRADE_DISABLED ||
         res.retcode == TRADE_RETCODE_MARKET_CLOSED) break;
      Sleep(300);
     }
   return(false);
  }

bool ModifyPosition(const ulong ticket, const double sl, const double tp)
  {
   if(!PositionSelectByTicket(ticket)) return(false);
   double cs = PositionGetDouble(POSITION_SL);
   double ct = PositionGetDouble(POSITION_TP);
   double ns = Nrm(sl), nt = Nrm(tp);
   if(MathAbs(cs - ns) < gPoint * 0.5 && MathAbs(ct - nt) < gPoint * 0.5) return(true);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.position = ticket;
   req.sl       = ns;
   req.tp       = nt;
   if(!OrderSend(req, res))
     {
      Log(LOG_DEBUG, StringFormat("Modify failed ticket=%I64u retcode=%d", ticket, res.retcode));
      return(false);
     }
   return(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
  }

bool ClosePositionPartial(const ulong ticket, const double volume)
  {
   if(!PositionSelectByTicket(ticket)) return(false);
   long   type = PositionGetInteger(POSITION_TYPE);
   double vol  = NormalizeVolume(volume);
   double have = PositionGetDouble(POSITION_VOLUME);
   if(vol > have) vol = have;
   if(vol < gVolMin) return(false);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.position     = ticket;
   req.volume       = vol;
   req.type         = (type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   req.price        = Nrm(type == POSITION_TYPE_BUY ? BidP() : AskP());
   req.deviation    = InpSlippagePoints;
   req.magic        = InpMagic;
   req.comment      = InpComment + "|partial";
   req.type_filling = PickFilling();
   if(!OrderSend(req, res)) return(false);
   return(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL);
  }

bool ClosePositionFull(const ulong ticket, const string why)
  {
   if(!PositionSelectByTicket(ticket)) return(false);
   double vol = PositionGetDouble(POSITION_VOLUME);
   bool ok = ClosePositionPartial(ticket, vol);
   if(ok) Log(LOG_TRADES, StringFormat("Closed #%I64u : %s", ticket, why));
   return(ok);
  }

void CloseAllPositions(const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      ClosePositionFull(tk, why);
     }
  }

void DeleteAllPendings(const string why)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action = TRADE_ACTION_REMOVE;
      req.order  = tk;
      if(OrderSend(req, res))
         Log(LOG_TRADES, StringFormat("Deleted pending #%I64u : %s", tk, why));
     }
  }

void ExpirePendings()
  {
   if(InpLimitExpiryBars <= 0) return;
   int    secs = PeriodSeconds(TF(InpEntryTF)) * InpLimitExpiryBars;
   datetime now = TimeCurrent();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(now - setup >= secs)
        {
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         req.action = TRADE_ACTION_REMOVE;
         req.order  = tk;
         if(OrderSend(req, res))
            Log(LOG_TRADES, StringFormat("Pending #%I64u expired after %d bars", tk, InpLimitExpiryBars));
        }
     }
  }

//+------------------------------------------------------------------+
//| OPEN POSITION STATE TRACKING                                     |
//+------------------------------------------------------------------+
struct SPosState
  {
   ulong    ticket;
   bool     partialDone;
   bool     partial2Done;
   bool     beDone;
   double   initSL;
   double   initRisk;
   double   entryPrice;
   double   origVolume;
   datetime openTime;
   int      dir;
  };

SPosState gPos[];

int FindPosState(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(gPos); i++)
      if(gPos[i].ticket == ticket) return(i);
   return(-1);
  }

int RegisterPosState(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return(-1);
   int n = ArraySize(gPos);
   ArrayResize(gPos, n + 1);
   gPos[n].ticket      = ticket;
   gPos[n].partialDone = false;
   gPos[n].partial2Done= false;
   gPos[n].beDone      = false;
   gPos[n].entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   gPos[n].origVolume  = PositionGetDouble(POSITION_VOLUME);
   gPos[n].initSL      = PositionGetDouble(POSITION_SL);
   gPos[n].dir         = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
   gPos[n].openTime    = (datetime)PositionGetInteger(POSITION_TIME);
   gPos[n].initRisk    = (gPos[n].initSL > 0.0
                          ? MathAbs(gPos[n].entryPrice - gPos[n].initSL)
                          : gATRentry);
   if(gPos[n].initRisk <= 0.0) gPos[n].initRisk = MathMax(gATRentry, Pts(100));
   return(n);
  }

void PurgePosStates()
  {
   int n = ArraySize(gPos);
   for(int i = n - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(gPos[i].ticket))
        {
         for(int j = i; j < ArraySize(gPos) - 1; j++) gPos[j] = gPos[j + 1];
         ArrayResize(gPos, ArraySize(gPos) - 1);
        }
     }
  }

//+------------------------------------------------------------------+
//| STRUCTURE TRAILING REFERENCE                                     |
//+------------------------------------------------------------------+
double LastSwingForTrail(const int dir)
  {
   int len = IMax(1, InpTrailStructLen);
   for(int i = len + 1; i < IMin(gEntryBars - len - 1, 120); i++)
     {
      if(dir > 0 && IsPivotLow(gEntry, gEntryBars, i, len))  return(gEntry[i].low);
      if(dir < 0 && IsPivotHigh(gEntry, gEntryBars, i, len)) return(gEntry[i].high);
     }
   return(0.0);
  }

//+------------------------------------------------------------------+
//| TRADE MANAGEMENT                                                 |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   PurgePosStates();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      int idx = FindPosState(tk);
      if(idx < 0) idx = RegisterPosState(tk);
      if(idx < 0) continue;

      int    dir    = gPos[idx].dir;
      double open   = gPos[idx].entryPrice;
      double risk   = gPos[idx].initRisk;
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      double vol    = PositionGetDouble(POSITION_VOLUME);
      double price  = (dir > 0 ? BidP() : AskP());
      double profit = (dir > 0 ? price - open : open - price);
      double rMult  = (risk > 0.0 ? profit / risk : 0.0);
      double newSL  = curSL;

      //--- 1) partial take profit --------------------------------------------
      if(InpUsePartials && !gPos[idx].partialDone && rMult >= InpTP1RR)
        {
         double part = NormalizeVolume(vol * InpPartialPercent / 100.0);
         if(part >= gVolMin && vol - part >= gVolMin)
           {
            if(ClosePositionPartial(tk, part))
              {
               gPos[idx].partialDone = true;
               Log(LOG_TRADES, StringFormat("Partial %.2f lots closed on #%I64u at %.2fR", part, tk, rMult));
               Notify("SMC partial", _Symbol + " partial close at " + DoubleToString(rMult, 2) + "R");
              }
           }
         else
            gPos[idx].partialDone = true;   // too small to split
        }

      //--- 1b) second partial - bank more profit while a small runner keeps
      //---     trailing beyond TP2; this only fires after the first partial
      //---     (or immediately at TP2 level if partials were skipped) and
      //---     is sized off the ORIGINAL volume so it does not keep eating
      //---     an ever-shrinking remainder ------------------------------------
      if(InpUsePartial2 && !gPos[idx].partial2Done && rMult >= InpTP2RR)
        {
         vol = PositionGetDouble(POSITION_VOLUME);   // refresh after 1st partial
         double part2 = NormalizeVolume(gPos[idx].origVolume * InpPartial2Percent / 100.0);
         if(part2 >= gVolMin && vol - part2 >= gVolMin)
           {
            if(ClosePositionPartial(tk, part2))
              {
               gPos[idx].partial2Done = true;
               Log(LOG_TRADES, StringFormat("Partial-2 %.2f lots closed on #%I64u at %.2fR", part2, tk, rMult));
               Notify("SMC partial-2", _Symbol + " 2nd partial close at " + DoubleToString(rMult, 2) + "R");
              }
           }
         else
            gPos[idx].partial2Done = true;   // remainder too small to split further
         vol = PositionGetDouble(POSITION_VOLUME);   // refresh again for the rest of this pass
        }

      //--- 2) break even -----------------------------------------------------
      bool beApplied = false;
      if(InpUseBreakEven && !gPos[idx].beDone && rMult >= InpBETriggerRR)
        {
         double be = (dir > 0 ? open + Pts(InpBEOffsetPoints) : open - Pts(InpBEOffsetPoints));
         bool better = (curSL == 0.0) || (dir > 0 && be > curSL) || (dir < 0 && be < curSL);
         if(better)
           {
            newSL     = be;
            beApplied = true;
           }
        }

      //--- 3) trailing -------------------------------------------------------
      if(InpTrailMode != TRAIL_NONE && rMult >= InpTrailStartRR)
        {
         double atrSL = 0.0, strSL = 0.0;
         if(InpTrailMode == TRAIL_ATR || InpTrailMode == TRAIL_BOTH)
           {
            double a = (gATRtrail > 0.0 ? gATRtrail : gATRentry);
            if(a > 0.0) atrSL = (dir > 0 ? price - a * InpTrailATRMult : price + a * InpTrailATRMult);
           }
         if(InpTrailMode == TRAIL_STRUCTURE || InpTrailMode == TRAIL_BOTH)
           {
            double sw = LastSwingForTrail(dir);
            if(sw > 0.0)
              {
               double buf = gATRentry * MathMax(0.05, InpSLBufferATR * 0.5);
               strSL = (dir > 0 ? sw - buf : sw + buf);
              }
           }
         double cand = 0.0;
         if(atrSL > 0.0 && strSL > 0.0)
            cand = (dir > 0 ? MathMax(atrSL, strSL) : MathMin(atrSL, strSL));  // tightest
         else
            cand = (atrSL > 0.0 ? atrSL : strSL);

         if(cand > 0.0)
           {
            bool better = (newSL == 0.0) ||
                          (dir > 0 && cand > newSL + Pts(InpTrailStepPoints)) ||
                          (dir < 0 && cand < newSL - Pts(InpTrailStepPoints));
            //--- never trail into a loss once BE was applied
            bool safe = (dir > 0 ? cand < price : cand > price);
            if(better && safe) newSL = cand;
           }
        }

      //--- apply stop modification ------------------------------------------
      if(newSL != curSL && newSL > 0.0)
        {
         double s = newSL, t = curTP;
         EnsureStops(dir, price, s, t);
         bool improving = (curSL == 0.0) || (dir > 0 && s > curSL) || (dir < 0 && s < curSL);
         if(improving && ModifyPosition(tk, s, curTP))
           {
            if(beApplied)
              {
               gPos[idx].beDone = true;
               Log(LOG_TRADES, StringFormat("Break-even set on #%I64u at %.*f", tk, gDigits, s));
              }
           }
        }

      //--- 4) opposite change of character -----------------------------------
      if(InpCloseOnOppCHoCH && gStEntry.valid && gStEntry.lastIsCHoCH &&
         gStEntry.lastDir == -dir && gStEntry.lastTime > gPos[idx].openTime)
        {
         ClosePositionFull(tk, "opposite CHoCH");
         continue;
        }

      //--- 5) time stop ------------------------------------------------------
      if(InpTimeStopBars > 0)
        {
         int secs = PeriodSeconds(TF(InpEntryTF)) * InpTimeStopBars;
         if(TimeCurrent() - gPos[idx].openTime >= secs && rMult < InpBETriggerRR)
           {
            ClosePositionFull(tk, "time stop");
            continue;
           }
        }
     }

//--- 6) friday / weekend flat ----------------------------------------------
   if(InpCloseFriday)
     {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      if(t.day_of_week == 5 && t.hour >= InpFridayCloseHour)
        {
         if(CountPositions(0) > 0) CloseAllPositions("weekend flat");
         DeleteAllPendings("weekend flat");
        }
     }
  }

//+------------------------------------------------------------------+
//| DRAWING HELPERS                                                  |
//+------------------------------------------------------------------+
bool CanDraw()
  {
   if(!InpDrawObjects) return(false);
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return(false);
   return(true);
  }

void DeleteOurObjects(const string filter)
  {
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, SMC_PREFIX) != 0) continue;
      if(filter != "" && StringFind(nm, filter) < 0) continue;
      ObjectDelete(0, nm);
     }
  }

void DrawBox(const string name, const datetime t1, const double p1,
             const datetime t2, const double p2, const color clr, const bool fill)
  {
   if(!CanDraw()) return;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawHLine(const string name, const datetime t1, const datetime t2,
               const double price, const color clr, const int style, const int width)
  {
   if(!CanDraw()) return;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawText(const string name, const datetime t, const double price,
              const string txt, const color clr, const int anchor)
  {
   if(!CanDraw()) return;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, price);
   ObjectSetString (0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawArrowObj(const string name, const datetime t, const double price,
                  const int code, const color clr)
  {
   if(!CanDraw()) return;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| CHART VISUALISATION OF THE CURRENT MARKET READ                   |
//+------------------------------------------------------------------+
void DrawAnalysis()
  {
   if(!CanDraw()) return;
   if(gEntryBars < 10) return;

//--- keep the chart clean: purge our objects when the budget is exceeded
   if(InpMaxObjects > 0 && ObjectsTotal(0, -1, -1) > InpMaxObjects)
      DeleteOurObjects("liq_");

   datetime tNow   = gEntry[0].time;
   datetime tRight = tNow + PeriodSeconds(TF(InpEntryTF)) * 12;

//--- structure levels
   if(gStEntry.valid)
     {
      if(gStEntry.refHigh > 0.0)
         DrawHLine(SMC_PREFIX + "refHigh", gStEntry.refHighTime, tRight,
                   gStEntry.refHigh, InpColBearStruct, STYLE_DOT, 1);
      if(gStEntry.refLow > 0.0)
         DrawHLine(SMC_PREFIX + "refLow", gStEntry.refLowTime, tRight,
                   gStEntry.refLow, InpColBullStruct, STYLE_DOT, 1);
      if(gStEntry.lastTime > 0)
        {
         color c = (gStEntry.lastDir > 0 ? InpColBullStruct : InpColBearStruct);
         DrawHLine(SMC_PREFIX + "lastEvent", gStEntry.lastTime, tRight,
                   gStEntry.lastLevel, c, STYLE_SOLID, 2);
         DrawText(SMC_PREFIX + "lastEventTx", tRight, gStEntry.lastLevel,
                  (gStEntry.lastIsCHoCH ? " CHoCH" : " BOS"), c, ANCHOR_LEFT);
        }
     }

//--- dealing range: premium / equilibrium / discount
   if(gRangeHigh > gRangeLow)
     {
      double eq = gRangeLow + (gRangeHigh - gRangeLow) * InpEquilibrium;
      datetime tl = gEntry[IMin(gEntryBars - 1, 100)].time;
      DrawHLine(SMC_PREFIX + "rngHigh", tl, tRight, gRangeHigh, clrSilver, STYLE_DASH, 1);
      DrawHLine(SMC_PREFIX + "rngLow",  tl, tRight, gRangeLow,  clrSilver, STYLE_DASH, 1);
      DrawHLine(SMC_PREFIX + "rngEq",   tl, tRight, eq,         clrGray,   STYLE_DASHDOT, 1);
      DrawText(SMC_PREFIX + "rngEqTx",  tRight, eq, " EQ 50%", clrGray, ANCHOR_LEFT);
     }

//--- liquidity pools
   for(int i = 0; i < ArraySize(gPools) && i < 40; i++)
     {
      if(gPools[i].price <= 0.0) continue;
      string nm = SMC_PREFIX + "liq_" + IntegerToString(i);
      color  c  = (gPools[i].swept ? clrDimGray : InpColLiquidity);
      int    st = (gPools[i].type >= 2 ? STYLE_SOLID : STYLE_DOT);
      datetime t0 = (gPools[i].time > 0 ? gPools[i].time : gEntry[IMin(gEntryBars - 1, 60)].time);
      DrawHLine(nm, t0, tRight, gPools[i].price, c, st, 1);
      string tag = "";
      switch(gPools[i].type)
        {
         case 1: tag = (gPools[i].isHigh ? "EQH" : "EQL"); break;
         case 2: tag = (gPools[i].isHigh ? "PDH" : "PDL"); break;
         case 3: tag = (gPools[i].isHigh ? "PWH" : "PWL"); break;
         case 4: tag = (gPools[i].isHigh ? "ASIA-H" : "ASIA-L"); break;
         default: tag = (gPools[i].isHigh ? "BSL" : "SSL"); break;
        }
      DrawText(nm + "_t", tRight, gPools[i].price, " " + tag, c, ANCHOR_LEFT);
     }

//--- last evaluated setup zones
   if(gLastSetup.dir != 0)
     {
      datetime tEnd = tRight;
      if(gLastSetup.ob.found)
        {
         color c = (gLastSetup.dir > 0 ? InpColBullOB : InpColBearOB);
         DrawBox(SMC_PREFIX + "OB", gLastSetup.ob.time, gLastSetup.ob.top,
                 tEnd, gLastSetup.ob.bottom, c, true);
         DrawText(SMC_PREFIX + "OB_t", gLastSetup.ob.time, gLastSetup.ob.top,
                  (gLastSetup.dir > 0 ? "Bull OB" : "Bear OB"), c, ANCHOR_LEFT_LOWER);
        }
      if(gLastSetup.fvg.found)
        {
         color c = (gLastSetup.dir > 0 ? InpColBullFVG : InpColBearFVG);
         DrawBox(SMC_PREFIX + "FVG", gLastSetup.fvg.time, gLastSetup.fvg.top,
                 tEnd, gLastSetup.fvg.bottom, c, true);
         DrawText(SMC_PREFIX + "FVG_t", gLastSetup.fvg.time, gLastSetup.fvg.bottom,
                  "FVG", c, ANCHOR_LEFT_UPPER);
        }
      if(gLastSetup.sweep.found)
        {
         DrawArrowObj(SMC_PREFIX + "sweep", gLastSetup.sweep.time, gLastSetup.sweep.extreme,
                      (gLastSetup.dir > 0 ? 233 : 234), InpColSweep);
         DrawText(SMC_PREFIX + "sweep_t", gLastSetup.sweep.time, gLastSetup.sweep.extreme,
                  "sweep", InpColSweep,
                  (gLastSetup.dir > 0 ? ANCHOR_UPPER : ANCHOR_LOWER));
        }
      if(gLastSetup.oteHigh > gLastSetup.oteLow)
         DrawBox(SMC_PREFIX + "OTE", gEntry[IMin(gEntryBars - 1, 30)].time, gLastSetup.oteHigh,
                 tEnd, gLastSetup.oteLow, clrDarkOliveGreen, false);
     }
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| DASHBOARD                                                        |
//+------------------------------------------------------------------+
void PanelLine(const int idx, const string txt, const color clr)
  {
   string nm = SMC_PREFIX + "pnl_" + IntegerToString(idx);
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, InpPanelX + 8);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, InpPanelY + 8 + idx * 14);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 8);
   ObjectSetString (0, nm, OBJPROP_FONT, "Consolas");
   ObjectSetString (0, nm, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }

string DirStr(const int d)
  {
   if(d > 0) return("BULLISH");
   if(d < 0) return("BEARISH");
   return("NEUTRAL");
  }

void DrawPanel()
  {
   if(!InpShowPanel) return;
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return;

   string bg = SMC_PREFIX + "pnl_bg";
   if(ObjectFind(0, bg) < 0)
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, 330);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, 292);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, InpColPanelBg);
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);

   color cTxt  = InpColPanelText;
   color cBull = InpColBullStruct;
   color cBear = InpColBearStruct;
   int   ln    = 0;

   PanelLine(ln++, "SMART MONEY CONCEPTS EA  v1.00", clrGold);
   PanelLine(ln++, "-------------------------------------------", clrDimGray);
   PanelLine(ln++, StringFormat("%-11s %s  spread %d pts", _Symbol,
                                TFName(InpEntryTF), SpreadPoints()), cTxt);
   PanelLine(ln++, StringFormat("HTF1 %-5s bias : %s",
                                TFName(InpBiasTF), DirStr(gBiasDir)),
             (gBiasDir > 0 ? cBull : (gBiasDir < 0 ? cBear : clrSilver)));
   PanelLine(ln++, StringFormat("HTF2 %-5s      : %s",
                                TFName(InpBiasTF2), DirStr(gBias2Dir)),
             (gBias2Dir > 0 ? cBull : (gBias2Dir < 0 ? cBear : clrSilver)));
   PanelLine(ln++, StringFormat("Entry structure : %s  %s",
                                DirStr(gStEntry.trend),
                                (gStEntry.lastIsCHoCH ? "(CHoCH)" : "(BOS)")),
             (gStEntry.trend > 0 ? cBull : (gStEntry.trend < 0 ? cBear : clrSilver)));
   double pos = RangePosition((AskP() + BidP()) * 0.5) * 100.0;
   PanelLine(ln++, StringFormat("Range position  : %.1f%%  (%s)", pos,
                                (pos > InpEquilibrium * 100.0 ? "PREMIUM" : "DISCOUNT")), cTxt);
   PanelLine(ln++, StringFormat("Dealing range   : %.*f / %.*f",
                                gDigits, gRangeHigh, gDigits, gRangeLow), cTxt);
   PanelLine(ln++, StringFormat("ATR(%s)        : %.*f", TFName(InpEntryTF), gDigits, gATRentry), cTxt);
   PanelLine(ln++, StringFormat("Liquidity pools : %d   session: %s",
                                ArraySize(gPools), ActiveSessionName()), cTxt);
   PanelLine(ln++, "-------------------------------------------", clrDimGray);
   PanelLine(ln++, "LAST SETUP EVALUATION", clrGold);
   if(gLastSetup.dir != 0)
     {
      color cs = (gLastSetup.dir > 0 ? cBull : cBear);
      PanelLine(ln++, StringFormat("%s  model %d  score %d/%d",
                                   (gLastSetup.dir > 0 ? "LONG" : "SHORT"),
                                   gLastSetup.model, gLastSetup.score, InpMinScore), cs);
      PanelLine(ln++, StringFormat("sweep %s  CHoCH %s  disp %s  FVG %s  OB %s",
                                   (gLastSetup.sweep.found ? "Y" : "-"),
                                   (gLastSetup.chochTime > 0 ? "Y" : "-"),
                                   (gLastSetup.hasDisplacement ? "Y" : "-"),
                                   (gLastSetup.fvg.found ? "Y" : "-"),
                                   (gLastSetup.ob.found ? "Y" : "-")), cTxt);
      PanelLine(ln++, StringFormat("entry %.*f  sl %.*f  tp %.*f  RR %.2f",
                                   gDigits, gLastSetup.entry, gDigits, gLastSetup.sl,
                                   gDigits, gLastSetup.tp, gLastSetup.rr), cTxt);
      PanelLine(ln++, "state : " + gLastSetup.reason,
                (gLastSetup.valid ? clrLime : clrSilver));
     }
   else
     {
      PanelLine(ln++, "no setup candidate yet", clrSilver);
      PanelLine(ln++, "", cTxt);
      PanelLine(ln++, "", cTxt);
      PanelLine(ln++, "", cTxt);
     }
   PanelLine(ln++, "-------------------------------------------", clrDimGray);
   PanelLine(ln++, StringFormat("Positions %d   pendings %d   today %d",
                                CountPositions(0), CountOrders(0), gDayTrades), cTxt);
   PanelLine(ln++, StringFormat("Day P/L %.2f (%.2f%%)   peak eq %.2f",
                                DayProfit(), DayProfitPct(), gPeakEquity),
             (DayProfit() >= 0 ? clrLime : clrTomato));
   PanelLine(ln++, StringFormat("Trades %d  W %d  L %d  PF %.2f",
                                gStatTrades, gStatWins, gStatLosses,
                                (gStatLoss > 0.0 ? gStatGross / gStatLoss : 0.0)), cTxt);
   PanelLine(ln++, "status: " + gStatusLine,
             (StringFind(gStatusLine, "HALT") >= 0 ? clrRed : clrSilver));
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| DEAL HISTORY -> STATISTICS AND LOSS STREAK                       |
//+------------------------------------------------------------------+
void UpdateStatsFromHistory()
  {
   datetime from = TimeCurrent() - 60 * 60 * 24 * 30;
   if(!HistorySelect(from, TimeCurrent() + 60)) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0 || dt <= gLastDealChecked) continue;
      if(HistoryDealGetString(dt, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(dt, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(dt, DEAL_ENTRY) != DEAL_ENTRY_OUT &&
         HistoryDealGetInteger(dt, DEAL_ENTRY) != DEAL_ENTRY_OUT_BY) continue;

      gLastDealChecked = dt;
      double p = HistoryDealGetDouble(dt, DEAL_PROFIT)
                 + HistoryDealGetDouble(dt, DEAL_SWAP)
                 + HistoryDealGetDouble(dt, DEAL_COMMISSION);
      gStatTrades++;
      gStatProfit += p;
      if(p >= 0.0)
        {
         gStatWins++;
         gStatGross += p;
         gConsecLosses = 0;
        }
      else
        {
         gStatLosses++;
         gStatLoss += MathAbs(p);
         gConsecLosses++;
         if(InpPauseBarsAfterLoss > 0)
            gPauseUntilBar = TimeCurrent() + PeriodSeconds(TF(InpEntryTF)) * InpPauseBarsAfterLoss;
        }
     }
  }

//+------------------------------------------------------------------+
//| ANALYSIS PIPELINE (executed once per closed entry-TF bar)        |
//+------------------------------------------------------------------+
bool Analyze()
  {
   if(!FetchRates(InpEntryTF, gEntry, gEntryBars)) return(false);
   FetchRates(InpBiasTF,  gBias,  gBiasBars);
   FetchRates(InpBiasTF2, gBias2, gBias2Bars);
   FetchRates(InpRangeTF, gRange, gRangeBars);

   gATRentry = GetATR(hATRentry);
   gATRbias  = GetATR(hATRbias);
   gATRtrail = GetATR(hATRtrail);
   gATRvolSlow = GetATR(hATRvolSlow);
   gEMAbias  = GetEMA(hEMAbias);
   if(gATRentry <= 0.0) return(false);

   BuildStructure(gEntry, gEntryBars, InpSwingLenEntry, gStEntry, gPivEntry);
   if(gBiasBars  > 60) BuildStructure(gBias,  gBiasBars,  InpSwingLenHTF,   gStBias,  gPivBias);
   if(gBias2Bars > 60) BuildStructure(gBias2, gBias2Bars, InpSwingLenHTF,   gStBias2, gPivBias2);
   if(gRangeBars > 60) BuildStructure(gRange, gRangeBars, InpSwingLenRange, gStRange, gPivRange);

   gBiasDir = ComputeBias();

//--- dealing range comes from the range timeframe, fallback to entry TF
   if(gStRange.valid && gStRange.rangeHigh > gStRange.rangeLow)
     {
      gRangeHigh = gStRange.rangeHigh;
      gRangeLow  = gStRange.rangeLow;
     }
   else
     {
      gRangeHigh = gStEntry.rangeHigh;
      gRangeLow  = gStEntry.rangeLow;
     }

   BuildKeyLevels();
   BuildLiquidityMap();
   return(true);
  }

//+------------------------------------------------------------------+
//| SETUP SEARCH + EXECUTION                                         |
//+------------------------------------------------------------------+
void LookForTrades()
  {
   string why = "";

//--- hard gates -------------------------------------------------------------
   if(!RiskGuardsOk(why))          { gStatusLine = "HALT - " + why;      return; }
   if(!DayAllowed())               { gStatusLine = "day filter";         return; }
   string mwhy = "";
   if(!MarketOpenOk(mwhy))         { gStatusLine = "market: " + mwhy;    return; }
   if(!FridayEntryWindowOk())      { gStatusLine = "weekend flat window - no new entries"; return; }
   if(!InKillzone())               { gStatusLine = "outside killzone";   return; }
   if(!SpreadOk())                 { gStatusLine = StringFormat("spread %d pts too high", SpreadPoints()); return; }
   string vwhy = "";
   if(!VolatilityRegimeOk(vwhy))   { gStatusLine = "regime: " + vwhy;    return; }
   string cwhy = "";
   if(!CostFilterOk(cwhy))         { gStatusLine = "cost: " + cwhy;      return; }

   string ev = "";
   if(NewsBlocked(ev))
     {
      gStatusLine = "news lock: " + ev;
      if(InpNewsCloseTrades) { CloseAllPositions("news"); DeleteAllPendings("news"); }
      return;
     }

   if(CountPositions(0) >= InpMaxPositions)
     {
      gStatusLine = "max positions reached";
      return;
     }
   if(InpOneTradePerBar && gLastOrderBar == gEntry[0].time)
     {
      gStatusLine = "already traded this bar";
      return;
     }

//--- direction candidates ---------------------------------------------------
   int dirs[2];
   int models[2];
   int nd = 0;
   if(gBiasDir != 0)
     {
      dirs[nd]   = gBiasDir;
      models[nd] = 1;                 // Model A - continuation with HTF bias
      nd++;
     }
   if(InpAllowReversalModel)
     {
      int rd = (gBiasDir != 0 ? -gBiasDir : 0);
      if(rd != 0) { dirs[nd] = rd; models[nd] = 2; nd++; }         // Model B - reversal
      else
        {
         dirs[0] = 1;  models[0] = 3;
         dirs[1] = -1; models[1] = 3;                              // Model C - no bias, level reaction
         nd = 2;
        }
     }
   if(nd == 0)
     {
      gStatusLine = "no HTF bias";
      return;
     }

   SSetup best;
   ResetSetup(best);
   bool haveCandidate = false;

   //--- evaluate EVERY candidate direction/model first, then pick the highest
   //--- scoring VALID setup. The previous version stopped at the first valid
   //--- candidate (always the bias-aligned continuation model, since it is
   //--- placed first in dirs[]/models[]), so a higher-scoring reversal/level
   //--- reaction setup could never be chosen even when it was objectively
   //--- better. Falls back to the best-scoring invalid candidate (for the
   //--- dashboard "reason" message) only when nothing valid was found.
   for(int k = 0; k < nd; k++)
     {
      SSetup s = BuildSetup(dirs[k], models[k]);
      //--- reversal model requires stricter evidence
      if(s.valid && models[k] == 2)
        {
         if(!s.sweep.wasMajor && !s.sweep.wasEqual)
           {
            s.valid  = false;
            s.reason = "reversal needs major/EQ pool sweep";
           }
         else if(!s.hasDisplacement)
           {
            s.valid  = false;
            s.reason = "reversal needs displacement";
           }
        }

      if(!haveCandidate)
        {
         best = s;
         haveCandidate = true;
         continue;
        }

      bool takeIt;
      if(s.valid && !best.valid)
         takeIt = true;               // any valid setup beats an invalid one
      else if(s.valid == best.valid)
         takeIt = (s.score > best.score); // among equally-valid candidates, highest score wins
      else
         takeIt = false;              // best is already valid and s is not -> keep best

      if(takeIt) best = s;
     }

   gLastSetup = best;

   if(!best.valid)
     {
      gStatusLine = "scan: " + best.reason;
      return;
     }

//--- do not fire twice on the same manipulation -----------------------------
   if(InpOneTradePerSweep && best.signature == gLastSweepSig)
     {
      gStatusLine = "sweep already traded";
      return;
     }

//--- optional flattening of the opposite side -------------------------------
   if(InpHedgeOppositeClose && CountPositions(-best.dir) > 0)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || !PositionSelectByTicket(tk)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         int pd = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
         if(pd == -best.dir) ClosePositionFull(tk, "opposite signal");
        }
     }

//--- sizing -----------------------------------------------------------------
   double lots = CalcLot(best.dir, best.entry, best.sl);
   if(lots < gVolMin)
     {
      gStatusLine = "lot size below minimum";
      Log(LOG_SIGNALS, "Lot below minimum - trade skipped");
      return;
     }

   string tag = StringFormat("M%d|S%d|RR%.1f", best.model, best.score, best.rr);
   bool sent = false;
   double mkt = (best.dir > 0 ? AskP() : BidP());
   bool insidePOI = (best.dir > 0 ? mkt <= best.entry : mkt >= best.entry);

   if(InpEntryMode == ENTRY_MARKET)
      sent = SendMarket(best.dir, lots, best.sl, best.tp, tag);
   else
      if(InpEntryMode == ENTRY_LIMIT_POI)
        {
         if(CountOrders(best.dir) == 0)
            sent = SendLimit(best.dir, lots, best.entry, best.sl, best.tp, tag);
        }
      else   // ENTRY_LIMIT_ELSE_MKT
        {
         if(insidePOI)
           {
            //--- price already inside / beyond the POI -> execute at market,
            //    recomputing the risk from the live price
            double risk = MathAbs(mkt - best.sl);
            if(risk > 0.0)
              {
               double rew = MathAbs(best.tp - mkt);
               if(rew / risk >= InpMinRR * 0.75)
                 {
                  lots = CalcLot(best.dir, mkt, best.sl);
                  if(lots >= gVolMin)
                     sent = SendMarket(best.dir, lots, best.sl, best.tp, tag + "|mkt");
                 }
               else
                  gStatusLine = "POI already run, RR gone";
              }
           }
         else
            if(CountOrders(best.dir) == 0)
               sent = SendLimit(best.dir, lots, best.entry, best.sl, best.tp, tag);
        }

   if(sent)
     {
      gLastOrderBar = gEntry[0].time;
      gLastSweepSig = best.signature;
      gDaySetups++;
      gDayTrades++;
      gStatusLine = StringFormat("ORDER SENT %s score %d RR %.2f",
                                 (best.dir > 0 ? "LONG" : "SHORT"), best.score, best.rr);
      Log(LOG_SIGNALS, StringFormat(
          "SETUP %s model=%d score=%d entry=%.*f sl=%.*f tp=%.*f RR=%.2f sweep=%s poolType=%d",
          (best.dir > 0 ? "LONG" : "SHORT"), best.model, best.score,
          gDigits, best.entry, gDigits, best.sl, gDigits, best.tp, best.rr,
          TimeToString(best.sweep.time, TIME_DATE | TIME_MINUTES), best.sweep.poolType));
      Notify("SMC signal " + _Symbol,
             StringFormat("%s %s  entry %.*f  sl %.*f  tp %.*f  RR %.2f  score %d",
                          (best.dir > 0 ? "LONG" : "SHORT"), TFName(InpEntryTF),
                          gDigits, best.entry, gDigits, best.sl, gDigits, best.tp,
                          best.rr, best.score));
     }
   else
      if(gStatusLine == "") gStatusLine = "order not sent";
  }

//+------------------------------------------------------------------+
//| INITIALISATION                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   gPoint      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   gDigits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   gTickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   gTickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   gVolMin     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   gVolMax     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   gVolStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   gStopLevel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   gFreezeLevel= (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(gTickSize <= 0.0) gTickSize = gPoint;
   if(gVolStep  <= 0.0) gVolStep  = 0.01;

   if(gPoint <= 0.0)
     {
      Print("[SMC] FATAL: symbol point size unavailable.");
      return(INIT_FAILED);
     }

//--- input sanity -----------------------------------------------------------
   if(InpSwingLenEntry < 1 || InpSwingLenHTF < 1 || InpSwingLenRange < 1)
     {
      Print("[SMC] FATAL: pivot lengths must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpRiskPercent <= 0.0 && InpRiskMode != RISK_FIXED_LOT && InpRiskMode != RISK_FIXED_MONEY)
     {
      Print("[SMC] FATAL: risk percent must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpMinRR <= 0.0)
     {
      Print("[SMC] FATAL: minimum RR must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpOTELow >= InpOTEHigh)
     {
      Print("[SMC] FATAL: OTE low must be smaller than OTE high.");
      return(INIT_PARAMETERS_INCORRECT);
     }

//--- indicator handles ------------------------------------------------------
   hATRentry = iATR(_Symbol, TF(InpEntryTF), 14);
   hATRbias  = iATR(_Symbol, TF(InpBiasTF),  14);
   hATRtrail = iATR(_Symbol, TF(InpEntryTF), IMax(2, InpTrailATRPeriod));
   hATRvolSlow = iATR(_Symbol, TF(InpEntryTF), IMax(20, InpVolSlowPeriod));
   hEMAbias  = iMA (_Symbol, TF(InpBiasTF), IMax(2, InpBiasEmaPeriod), 0, MODE_EMA, PRICE_CLOSE);

   if(hATRentry == INVALID_HANDLE || hATRbias == INVALID_HANDLE ||
      hATRtrail == INVALID_HANDLE || hATRvolSlow == INVALID_HANDLE || hEMAbias == INVALID_HANDLE)
     {
      Print("[SMC] FATAL: could not create indicator handles.");
      return(INIT_FAILED);
     }

   ResetStruct(gStEntry);
   ResetStruct(gStBias);
   ResetStruct(gStBias2);
   ResetStruct(gStRange);
   ResetSetup(gLastSetup);
   ArrayResize(gPos, 0);

   gPeakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
   gDayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   gDayStartEquity  = gPeakEquity;
   gDayStamp        = 0;
   gHaltedToday     = false;
   gHaltedTotal     = false;
   gStatusLine      = "initialised";

   RollDailyCounters();

   if(!MQLInfoInteger(MQL_OPTIMIZATION))
      EventSetTimer(2);

   Print("[SMC] Smart Money Concepts EA initialised on ", _Symbol,
         "  entry TF ", TFName(InpEntryTF),
         "  bias ", TFName(InpBiasTF), "/", TFName(InpBiasTF2),
         "  magic ", (string)InpMagic);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| DEINITIALISATION                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeleteOurObjects("");
   if(hATRentry != INVALID_HANDLE) IndicatorRelease(hATRentry);
   if(hATRbias  != INVALID_HANDLE) IndicatorRelease(hATRbias);
   if(hATRtrail != INVALID_HANDLE) IndicatorRelease(hATRtrail);
   if(hATRvolSlow != INVALID_HANDLE) IndicatorRelease(hATRvolSlow);
   if(hEMAbias  != INVALID_HANDLE) IndicatorRelease(hEMAbias);
   Comment("");
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| TIMER : panel refresh only                                       |
//+------------------------------------------------------------------+
void OnTimer()
  {
   DrawPanel();
  }

//+------------------------------------------------------------------+
//| MAIN TICK HANDLER                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   RollDailyCounters();

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > gPeakEquity) gPeakEquity = eq;

//--- per tick housekeeping --------------------------------------------------
   ManagePositions();
   ExpirePendings();

//--- new closed bar on the entry timeframe ----------------------------------
   datetime bt = (datetime)SeriesInfoInteger(_Symbol, TF(InpEntryTF), SERIES_LASTBAR_DATE);
   if(bt == 0 || bt == gLastEntryBar) return;
   gLastEntryBar = bt;

   UpdateStatsFromHistory();

   if(!Analyze())
     {
      gStatusLine = "waiting for data";
      return;
     }

   gStatusLine = "";
   LookForTrades();

   DrawAnalysis();
   DrawPanel();
  }

//+------------------------------------------------------------------+
//| TRADE TRANSACTIONS : register fills, log results                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      if(trans.symbol != _Symbol) return;
      if(!HistoryDealSelect(trans.deal)) return;
      if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;

      long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
        {
         ulong posId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
         if(PositionSelectByTicket(posId) && FindPosState(posId) < 0)
            RegisterPosState(posId);
         Log(LOG_TRADES, StringFormat("Filled position #%I64u at %.*f",
             posId, gDigits, HistoryDealGetDouble(trans.deal, DEAL_PRICE)));
        }
      else
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
           {
            double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            Log(LOG_TRADES, StringFormat("Exit deal %I64u  P/L %.2f", trans.deal, p));
           }
     }
  }

//+------------------------------------------------------------------+
//| CHART EVENTS                                                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE) DrawPanel();
  }

//+------------------------------------------------------------------+
//| OPTIMISATION CRITERION                                           |
//| Balanced score: net profit weighted by profit factor,            |
//| penalised by drawdown and rewarded for sample size.              |
//+------------------------------------------------------------------+
double OnTester()
  {
   double profit = TesterStatistics(STAT_PROFIT);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double trades = TesterStatistics(STAT_TRADES);
   double expct  = TesterStatistics(STAT_EXPECTED_PAYOFF);

   if(trades < 10) return(0.0);
   if(dd <= 0.0)   dd = 0.1;
   if(pf <= 0.0)   pf = 0.01;

   double score = (profit / dd) * MathSqrt(trades) * MathMin(pf, 5.0);
   if(expct <= 0.0) score = score * 0.1;
   return(score);
  }
//+------------------------------------------------------------------+
