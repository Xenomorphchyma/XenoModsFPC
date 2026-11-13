unit XenoDomRangers;

{$I GameOptions.inc}

// Port of XenoDomRangers.XenoPlugin.dll 2.3.0. The RScript part of the mod
// recruits specialist NPC rangers; this unit supplies its script library and
// extends TKling.IsPlayerCamouflageEffective to the NPCs the script registered.
// The Delphi plugin detoured that method and wrote the Player-only
// ChameleonLogic byte into the ranger object; here the per-series logic lives
// in the session table and the kling check calls XenoDomRangersCamouflage.
interface

{$IFDEF XENO_MODS}
uses
  aShip;

procedure RegisterXenoDomRangers;
// Returns True when Target is a registered NPC specialist; Effective then
// holds the decision. False means the stock player-only check applies.
function XenoDomRangersCamouflage(Kling: TShip; Target: TShip; out Effective: Boolean): Boolean;
// For XenoSelfTest.
function IsConfusedByChameleon(AttackerSeries: Integer; CamouflageActive: Boolean; CamouflageSeries: Integer; Detected: Boolean;
    LogicMode: Integer): Boolean;
{$ENDIF}

implementation

{$IFDEF XENO_MODS}
uses
  SysUtils,
  EC_Expression,
  NativeScriptLibrary,
  GameObjectRegistry,
  aGalaxyStruct,
  aKling,

  XenoPluginHost,
  XenoModsHost;

const
  ModName = 'XenoDomRangers';
  IniPath = 'Native\XenoDomRangers.XenoPlugin.ini';
  MaxSessions = 8;

type
  TMaskSession = record
    Ship: TShip;
    ShipId: Integer;
    RangerType, KlingType: Byte;
    OldActive: Boolean;
    OldSeries: TDominatorSeries;
    OldDetected: array[TDominatorSeries] of Boolean;
    Logic: array[TDominatorSeries] of Byte;
    LastTouched: QWord;
    Occupied: Boolean;
  end;
  PMaskSession = ^TMaskSession;

  TUserConfig = record
    RecruitmentCheckTurns, RecruitmentChancePercent, MaximumSpecialists, MinimumFreeCargo: Integer;
    MaximumRecruitHullDamage, ReplacementDelayTurns: Integer;
    CamouflageCostPercent, CamouflageLifetimeTurns, RestTurns, MaximumSalvageTurns, EmptyLootChecks: Integer;
    MinimumLootCostPercent: Integer;
    SafeLootStarRadius, SolarCarefulRadius, SolarApproachStep, SolarRetreatRadius, SolarRetreatHullDamage: Integer;
    SolarStallChecks: Integer;
  end;

var
  SessionLock: TRTLCriticalSection;
  Sessions: array[0..MaxSessions - 1] of TMaskSession;
  SessionSerial: QWord = 0;
  ConfigGeneration: Cardinal = 0;
  Ready: Boolean = False;
  Config: TUserConfig;
  WorldPlayer: Pointer = nil;
  WorldPlayerId: Integer = 0;
  WorldTurn: Integer = -1;

procedure LoadConfig;
var
  Generation: Cardinal;
  Ini: TXenoIni;

  function ReadInt(const Section, Key: WideString; Default, Minimum, Maximum: Integer): Integer;
  begin
    if Ini = nil then
      Result := Default
    else
      Result := Ini.ReadInt(Section, Key, Default, Minimum, Maximum);
  end;

begin
  Generation := XenoModsGeneration;
  if Generation = ConfigGeneration then
    Exit;
  ConfigGeneration := Generation;
  Ready := XenoPluginEnabled(ModName, IniPath);
  if not Ready then
    Exit;
  Ini := XenoOpenModIni(ModName, IniPath);
  try
    Config.RecruitmentCheckTurns := ReadInt('Recruitment', 'CheckIntervalTurns', 100, 10, 1000);
    Config.RecruitmentChancePercent := ReadInt('Recruitment', 'ChancePercent', 10, 0, 100);
    Config.MaximumSpecialists := ReadInt('Recruitment', 'MaximumSpecialists', 3, 0, 3);
    Config.MinimumFreeCargo := ReadInt('Recruitment', 'MinimumFreeCargo', 20, 0, 500);
    Config.MaximumRecruitHullDamage := ReadInt('Recruitment', 'MaximumHullDamage', 40, 0, 90);
    Config.ReplacementDelayTurns := ReadInt('Recruitment', 'ReplacementDelayTurns', 1000, 0, 10000);
    Config.CamouflageCostPercent := ReadInt('Mission', 'CamouflageCostPercent', 100, 0, 1000);
    Config.CamouflageLifetimeTurns := ReadInt('Mission', 'CamouflageLifetimeTurns', 300, 10, 3000);
    Config.RestTurns := ReadInt('Mission', 'RestTurns', 300, 1, 3000);
    Config.MaximumSalvageTurns := ReadInt('Mission', 'MaximumSalvageTurns', 20, 1, 100);
    Config.EmptyLootChecks := ReadInt('Mission', 'EmptyLootChecks', 3, 1, 20);
    Config.MinimumLootCostPercent := ReadInt('Mission', 'MinimumLootCostPercent', 100, 0, 1000);
    Config.SafeLootStarRadius := ReadInt('Safety', 'SafeLootStarRadius', 400, 300, 2000);
    Config.SolarCarefulRadius := ReadInt('Safety', 'SolarCarefulRadius', 600, 350, 3000);
    Config.SolarApproachStep := ReadInt('Safety', 'SolarApproachStep', 100, 10, 500);
    Config.SolarRetreatRadius := ReadInt('Safety', 'SolarRetreatRadius', 450, 350, 2000);
    Config.SolarRetreatHullDamage := ReadInt('Safety', 'SolarRetreatHullDamage', 60, 10, 95);
    Config.SolarStallChecks := ReadInt('Safety', 'SolarStallChecks', 3, 1, 20);
  finally
    Ini.Free;
  end;
  // Keep the normal-flight perimeter outside the loot and retreat radii.
  if Config.SolarCarefulRadius < Config.SafeLootStarRadius + 100 then
    Config.SolarCarefulRadius := Config.SafeLootStarRadius + 100;
  if Config.SolarCarefulRadius < Config.SolarRetreatRadius + 100 then
    Config.SolarCarefulRadius := Config.SolarRetreatRadius + 100;
  XenoLog(ModName, 'ready max_specialists=' + IntToStr(Config.MaximumSpecialists) + ' recruit_chance='
      + IntToStr(Config.RecruitmentChancePercent) + ' salvage_turns=' + IntToStr(Config.MaximumSalvageTurns));
end;

function IsReady: Boolean;
begin
  LoadConfig;
  Result := Ready;
end;

function GetConfigValue(Key: Integer): Integer;
begin
  case Key of
    1: Result := Config.RecruitmentCheckTurns;
    2: Result := Config.RecruitmentChancePercent;
    3: Result := Config.MaximumSpecialists;
    4: Result := Config.MinimumFreeCargo;
    5: Result := Config.MaximumRecruitHullDamage;
    6: Result := Config.ReplacementDelayTurns;
    10: Result := Config.CamouflageCostPercent;
    11: Result := Config.CamouflageLifetimeTurns;
    12: Result := Config.RestTurns;
    13: Result := Config.MaximumSalvageTurns;
    14: Result := Config.EmptyLootChecks;
    15: Result := Config.MinimumLootCostPercent;
    20: Result := Config.SafeLootStarRadius;
    21: Result := Config.SolarCarefulRadius;
    22: Result := Config.SolarApproachStep;
    23: Result := Config.SolarRetreatRadius;
    24: Result := Config.SolarRetreatHullDamage;
    25: Result := Config.SolarStallChecks;
  else
    Result := -1;
  end;
end;

// Same decision as the stock player check with an explicit logic byte.
function IsConfusedByChameleon(AttackerSeries: Integer; CamouflageActive: Boolean; CamouflageSeries: Integer; Detected: Boolean;
    LogicMode: Integer): Boolean;
begin
  if (AttackerSeries < 0) or (AttackerSeries > 2) then
    Exit(False);
  if Detected and (LogicMode < 2) then
    Exit(False);
  if (not CamouflageActive or (CamouflageSeries <> AttackerSeries)) and (LogicMode = 0) then
    Exit(False);
  Result := True;
end;

function ShipObject(Value: PtrUInt): TShip;
begin
  Result := nil;
  if (Value = 0) or not IsLiveGameObject(Pointer(Value)) then
    Exit;
  if TObject(Value) is TShip then
    Result := TShip(Value);
end;

function IsExpectedShip(Ship: TShip; ExpectedType: Byte): Boolean;
begin
  Result := (Ship <> nil) and IsLiveGameObject(Ship) and (Ord(Ship.TypeId) = ExpectedType);
end;

function FindSession(Ship: TShip): PMaskSession;
var
  I: Integer;
begin
  for I := 0 to High(Sessions) do
    if Sessions[I].Occupied and (Sessions[I].Ship = Ship) then
      Exit(@Sessions[I]);
  Result := nil;
end;

function FindSessionById(ShipId: Integer): PMaskSession;
var
  I: Integer;
begin
  for I := 0 to High(Sessions) do
    if Sessions[I].Occupied and (Sessions[I].ShipId = ShipId) then
      Exit(@Sessions[I]);
  Result := nil;
end;

function FindFreeSession: PMaskSession;
var
  I: Integer;
begin
  for I := 0 to High(Sessions) do
    if not Sessions[I].Occupied then
      Exit(@Sessions[I]);
  Result := nil;
end;

function FindOldestSession: PMaskSession;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(Sessions) do
    if Sessions[I].Occupied and ((Result = nil) or (Sessions[I].LastTouched < Result^.LastTouched)) then
      Result := @Sessions[I];
end;

procedure ClearSession(var Session: TMaskSession);
begin
  FillChar(Session, SizeOf(Session), 0);
end;

procedure CaptureBaseline(var Session: TMaskSession; Ship: TShip; Series: TDominatorSeries; ResumeExisting: Boolean);
var
  S: TDominatorSeries;
begin
  // A save stores the active mask in the ranger's own chameleon fields. When
  // the script resumes such a mission, that pattern is ours: restore to clean.
  if ResumeExisting and Ship.ChameleonActive and (Ship.ChameleonSeries = Series) and not Ship.ChameleonDetected[Series] then
  begin
    Session.OldActive := False;
    Session.OldSeries := Low(TDominatorSeries);
    for S := Low(TDominatorSeries) to High(TDominatorSeries) do
      Session.OldDetected[S] := False;
    Exit;
  end;
  Session.OldActive := Ship.ChameleonActive;
  Session.OldSeries := Ship.ChameleonSeries;
  for S := Low(TDominatorSeries) to High(TDominatorSeries) do
    Session.OldDetected[S] := Ship.ChameleonDetected[S];
end;

procedure WriteActiveMask(var Session: TMaskSession; Series: TDominatorSeries);
begin
  Session.Ship.ChameleonActive := True;
  Session.Ship.ChameleonSeries := Series;
  Session.Ship.ChameleonDetected[Series] := False;
  Session.Logic[Series] := 2;
  Inc(SessionSerial);
  Session.LastTouched := SessionSerial;
end;

procedure RestoreMask(var Session: TMaskSession);
var
  S: TDominatorSeries;
begin
  if IsExpectedShip(Session.Ship, Session.RangerType) then
  begin
    Session.Ship.ChameleonActive := Session.OldActive;
    Session.Ship.ChameleonSeries := Session.OldSeries;
    for S := Low(TDominatorSeries) to High(TDominatorSeries) do
      Session.Ship.ChameleonDetected[S] := Session.OldDetected[S];
  end;
  ClearSession(Session);
end;

function XenoDomRangersCamouflage(Kling: TShip; Target: TShip; out Effective: Boolean): Boolean;
var
  Session: PMaskSession;
  Series: Integer;
begin
  Result := False;
  Effective := False;
  if (Kling = nil) or (Target = nil) or not (Kling is TKling) then
    Exit;
  EnterCriticalSection(SessionLock);
  try
    if not Ready then
      Exit;
    Session := FindSession(Target);
    if (Session = nil) or not IsExpectedShip(Target, Session^.RangerType) or (Ord(Kling.TypeId) <> Session^.KlingType) then
      Exit;
    Series := Ord(TKling(Kling).DominatorSeries);
    if (Series < 0) or (Series > 2) then
      Exit;
    Effective := IsConfusedByChameleon(Series, Target.ChameleonActive, Ord(Target.ChameleonSeries),
        Target.ChameleonDetected[TDominatorSeries(Series)], Session^.Logic[TDominatorSeries(Series)]);
    Result := True;
  finally
    LeaveCriticalSection(SessionLock);
  end;
end;

procedure SF_IsReady(av: array of TVarEC; Code: TCodeEC);
begin
  av[0].SetInt(Ord(IsReady));
end;

procedure SF_GetConfigInt(av: array of TVarEC; Code: TCodeEC);
begin
  if IsReady then
    av[0].SetInt(GetConfigValue(av[1].GetInt))
  else
    av[0].SetInt(-1);
end;

procedure SF_SetNpcChameleon(av: array of TVarEC; Code: TCodeEC);
var
  Ship: TShip;
  ShipId, Series, RangerType, KlingType: Integer;
  ResumeExisting: Boolean;
  Session: PMaskSession;
begin
  av[0].SetInt(0);
  Ship := ShipObject(av[1].GetDword);
  ShipId := av[2].GetInt;
  Series := av[3].GetInt;
  RangerType := av[4].GetInt;
  KlingType := av[5].GetInt;
  ResumeExisting := av[6].GetInt <> 0;
  if not IsReady or (Ship = nil) or (ShipId <= 1) or (Series < 0) or (Series > 2) or (RangerType < 0) or (RangerType > 255)
      or (KlingType < 0) or (KlingType > 255) or not IsExpectedShip(Ship, RangerType) then
    Exit;
  EnterCriticalSection(SessionLock);
  try
    Session := FindSession(Ship);
    if (Session <> nil) and (Session^.ShipId <> ShipId) then
    begin
      // Pointer reuse after a destroyed or reloaded ship.
      ClearSession(Session^);
      Session := nil;
    end;
    if Session = nil then
    begin
      Session := FindSessionById(ShipId);
      if Session <> nil then
        Session^.Ship := Ship;
    end;
    if Session = nil then
    begin
      Session := FindFreeSession;
      if Session = nil then
      begin
        Session := FindOldestSession;
        if Session <> nil then
          RestoreMask(Session^);
      end;
      if Session <> nil then
      begin
        Session^.Ship := Ship;
        Session^.ShipId := ShipId;
        Session^.RangerType := RangerType;
        Session^.KlingType := KlingType;
        CaptureBaseline(Session^, Ship, TDominatorSeries(Series), ResumeExisting);
        Inc(SessionSerial);
        Session^.LastTouched := SessionSerial;
        Session^.Occupied := True;
      end;
    end;
    if (Session <> nil) and (Session^.ShipId = ShipId) and (Session^.RangerType = RangerType) and (Session^.KlingType = KlingType) then
    begin
      WriteActiveMask(Session^, TDominatorSeries(Series));
      av[0].SetInt(1);
    end;
  finally
    LeaveCriticalSection(SessionLock);
  end;
end;

procedure SF_ClearNpcChameleon(av: array of TVarEC; Code: TCodeEC);
var
  Ship: TShip;
  ShipId, RangerType: Integer;
  Session: PMaskSession;
  Series: TDominatorSeries;
begin
  av[0].SetInt(0);
  Ship := ShipObject(av[1].GetDword);
  ShipId := av[2].GetInt;
  RangerType := av[3].GetInt;
  if (Ship = nil) or (ShipId <= 1) or (RangerType < 0) or (RangerType > 255) then
    Exit;
  EnterCriticalSection(SessionLock);
  try
    Session := FindSession(Ship);
    if Session = nil then
    begin
      Session := FindSessionById(ShipId);
      if Session <> nil then
        Session^.Ship := Ship;
    end;
    if (Session <> nil) and (Session^.ShipId = ShipId) and (Session^.RangerType = RangerType) then
    begin
      RestoreMask(Session^);
      av[0].SetInt(1);
    end
    else if (Session = nil) and IsExpectedShip(Ship, RangerType) then
    begin
      // A save loaded before the script re-registered the specialist: clear
      // only the exact managed pattern (active, matching series, undetected).
      Series := Ship.ChameleonSeries;
      if Ship.ChameleonActive and not Ship.ChameleonDetected[Series] then
      begin
        Ship.ChameleonActive := False;
        Ship.ChameleonSeries := Low(TDominatorSeries);
        av[0].SetInt(1);
      end;
    end;
  finally
    LeaveCriticalSection(SessionLock);
  end;
end;

procedure DropAllSessions;
var
  I: Integer;
begin
  for I := 0 to High(Sessions) do
    ClearSession(Sessions[I]);
end;

procedure SF_ResetSessions(av: array of TVarEC; Code: TCodeEC);
begin
  EnterCriticalSection(SessionLock);
  try
    // Loading a save invalidates old objects; the script re-registers them.
    DropAllSessions;
  finally
    LeaveCriticalSection(SessionLock);
  end;
  av[0].SetInt(Ord(IsReady));
end;

procedure SF_WorldTick(av: array of TVarEC; Code: TCodeEC);
var
  Player: Pointer;
  PlayerId, Turn: Integer;
  WorldChanged: Boolean;
begin
  Player := Pointer(av[1].GetDword);
  PlayerId := av[2].GetInt;
  Turn := av[3].GetInt;
  if not IsReady or (Player = nil) or (PlayerId <= 1) or (Turn < 0) then
  begin
    av[0].SetInt(0);
    Exit;
  end;
  EnterCriticalSection(SessionLock);
  try
    WorldChanged := (WorldPlayer <> nil) and ((WorldPlayer <> Player) or (WorldPlayerId <> PlayerId) or (Turn <= WorldTurn));
    if WorldChanged then
      DropAllSessions;
    WorldPlayer := Player;
    WorldPlayerId := PlayerId;
    WorldTurn := Turn;
  finally
    LeaveCriticalSection(SessionLock);
  end;
  if WorldChanged then
    av[0].SetInt(2)
  else
    av[0].SetInt(1);
end;

procedure RegisterXenoDomRangers;
const
  LibraryName = 'XenoDomRangers.XenoPlugin';
begin
  RegisterNativeScriptFunction(LibraryName, 'int,XenoDomRangers_IsReady', @SF_IsReady);
  RegisterNativeScriptFunction(LibraryName, 'int,XenoDomRangers_SetNpcChameleon,dword,int,int,int,int,int', @SF_SetNpcChameleon);
  RegisterNativeScriptFunction(LibraryName, 'int,XenoDomRangers_ClearNpcChameleon,dword,int,int', @SF_ClearNpcChameleon);
  RegisterNativeScriptFunction(LibraryName, 'int,XenoDomRangers_ResetSessions', @SF_ResetSessions);
  RegisterNativeScriptFunction(LibraryName, 'int,XenoDomRangers_GetConfigInt,int', @SF_GetConfigInt);
  RegisterNativeScriptFunction(LibraryName, 'int,XenoDomRangers_WorldTick,dword,int,int', @SF_WorldTick);
end;

procedure OnCamouflage(User, Payload: Pointer); cdecl;
var
  IsEffective: Boolean;
begin
  with TXenoFpcCamouflageEvent(Payload^) do
    if (Handled = 0) and XenoDomRangersCamouflage(TShip(Kling), TShip(Target), IsEffective) then
    begin
      Handled := 1;
      Effective := Ord(IsEffective);
    end;
end;

initialization
  InitCriticalSection(SessionLock);
  RegisterXenoDomRangers;
  XenoSubscribe('Kling.Camouflage', @OnCamouflage, nil);

finalization
  DoneCriticalSection(SessionLock);
{$ENDIF}
end.
