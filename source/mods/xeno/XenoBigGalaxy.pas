unit XenoBigGalaxy;

{$I GameOptions.inc}
{$LEGACYPC24 OFF}
{$EXCESSPRECISION OFF}
{$DELPHIORDER OFF}

// Port of the native part of XenoBigGalaxy: XenoGalaxyGenerator.XenoPlugin.dll
// 1.6.3 and XenoNextDay.XenoPlugin.dll. The mod's Lang.dat describes the
// galaxy under Constellations.Generator (SectorCount=55, 200 stars, weighted
// distribution); this unit applies it inside TGalaxy:
//  - TGalaxy.Create: ConstellationCount := SectorCount and the star plan;
//  - GenerateGalaxyLayout: each star's sector comes from the plan (the stock
//    area balancing still follows), and after RetryLimit the stock area/axis
//    criteria are waived while layouts whose sector borders cross are still
//    regenerated (GeometryRetryLimit attempts or GeometryRetryBudgetMs);
//  - HideSpecialConstellation: ContourFallback removes a vertex when the
//    star-safe ear trimming finds no ear (the stock loop never ends there);
//  - NextDay stage 8: station spawning runs at the rate of a 73-star galaxy.
// XenoNextDay's default Compatible mode keeps the stock daily behavior, so it
// needs no code here; its experimental Dominator* modes are not ported.
// The SolEngine generator bridge and the HexGrid test geometry are not ported.
interface

{$IFDEF XENO_MODS}
uses
  aGalaxy;

// TGalaxy.Create; returns the constellation count to use.
function XenoBigGalaxySectorCount(Default: Integer): Integer;
// Star distribution; ConstellationIndex for star I or -1 for the stock rule.
function XenoBigGalaxyPlannedSector(StarIndex: Integer): Integer;
// Replaces "GenerationAttempts > 1000" in the first layout loop.
function XenoBigGalaxyLayoutDone(Galaxy: TGalaxy; Attempts: Integer): Boolean;
// Star-safe ear trimming found nothing: True forces a vertex removal.
function XenoBigGalaxyContourFallback: Boolean;
// NextDay stage 8: False skips ProcessStationSpawning this day.
function XenoBigGalaxyRunStationSpawning(Galaxy: TGalaxy): Boolean;
// For XenoSelfTest.
function VanillaSectorForStar(StarIndex, Count: Integer): Integer;
function XenoBigGalaxyCrossings(Galaxy: TGalaxy): Integer;
function XenoBigGalaxySegmentsCross(AX1, AY1, AX2, AY2, BX1, BY1, BX2, BY2: Double): Boolean;
function XenoBigGalaxyPlanLength: Integer;
{$ENDIF}

implementation

{$IFDEF XENO_MODS}
uses
  SysUtils,
  Math,
  Classes,
  aVector,
  EC_Struct,
  EC_BlockPar,
  EC_Str,
  GameSystem,
  GR_Main,
  XenoPluginHost,
  XenoModsHost;

const
  ModName = 'XenoBigGalaxy';
  GeneratorIni = 'Native\XenoGalaxyGenerator.XenoPlugin.ini';
  NextDayIni = 'Native\XenoNextDay.XenoPlugin.ini';
  PointTolerance = 0.1;
  ParallelEpsilon = 1E-9;

type
  TSectorRule = record
    Enabled: Boolean;
    Weight, MinimumStars, MaximumStars: Integer;
  end;

  TOutlinePoint = record
    X, Y: Double;
  end;

  TOutlineRing = record
    Sector, First, Count: Integer;
    MinX, MinY, MaxX, MaxY: Double;
  end;

var
  Active: Boolean = False;
  PlanReady: Boolean = False;
  StarPlan: array of Integer;
  SectorCount: Integer = 20;
  RetryLimit: Integer = 1;
  GeometryRetryLimit: Integer = 1000;
  GeometryRetryBudgetMs: Cardinal = 20000;
  ContourFallbackEnabled: Boolean = True;
  LayoutStartTick: QWord = 0;
  LayoutGeometryRejects: Integer = 0;
  ThrottleEnabled: Boolean = True;
  ReferenceStars: Integer = 73;
  FirstGameplayDay: Integer = 301;

{ Lang.dat access }

function HasParam(const Path: WideString): Boolean;
begin
  Result := (LanguageDataConfig <> nil) and (LanguageDataConfig.CountParamsByPath(Path) > 0);
end;

function ReadText(const Path: WideString; out Value: WideString): Boolean;
begin
  Result := HasParam(Path);
  if Result then
    Value := TrimWideString(LanguageDataConfig.GetParamByPath(Path));
end;

function ReadInt(const Path: WideString; Default: Integer): Integer;
var
  Text: WideString;
  Code: Integer;
begin
  Result := Default;
  if ReadText(Path, Text) then
  begin
    Val(Text, Result, Code);
    if Code <> 0 then
      Result := Default;
  end;
end;

function ReadBool(const Path: WideString; Default: Boolean): Boolean;
var
  Text: WideString;
begin
  Result := Default;
  if not ReadText(Path, Text) then
    Exit;
  Text := LowerCase(Text);
  if (Text = '1') or (Text = 'true') or (Text = 'yes') or (Text = 'on') then
    Result := True
  else if (Text = '0') or (Text = 'false') or (Text = 'no') or (Text = 'off') then
    Result := False;
end;

{ Star plan (generator_plan.cpp) }

function VanillaSectorForStar(StarIndex, Count: Integer): Integer;
begin
  if Count <= 0 then
    Exit(0);
  if StarIndex < 65 then
    Result := StarIndex mod Min(18, Count)
  else if StarIndex <= 68 then
    Result := Min(18, Count - 1)
  else if StarIndex = 69 then
    Result := Min(12, Count - 1)
  else if (StarIndex = 70) or (StarIndex = 71) then
    Result := Min(19, Count - 1)
  else
    Result := StarIndex mod Count;
end;

procedure BuildPlan;
const
  Prefix = 'Constellations.Generator.';
var
  StarCount, FirstCustomSector, PreservedCount, I, Sector, Star, Selected, Weight: Integer;
  PreserveVanillaStars, RoundRobin: Boolean;
  Mode: WideString;
  Rules: array of TSectorRule;
  Defaults: TSectorRule;
  Loads: array of Integer;
  Eligible: array of Integer;
  Scores: array of Int64;
  TotalWeight, SelectedScore: Int64;
  NextUnassigned: Integer;

  function HasCapacity(Index: Integer): Boolean;
  begin
    Result := (Rules[Index].MaximumStars <= 0) or (Loads[Index] < Rules[Index].MaximumStars);
  end;

  function TakeNextUnassigned: Integer;
  begin
    while (NextUnassigned < Length(StarPlan)) and (StarPlan[NextUnassigned] >= 0) do
      Inc(NextUnassigned);
    if NextUnassigned < Length(StarPlan) then
    begin
      Result := NextUnassigned;
      Inc(NextUnassigned);
    end
    else
      Result := -1;
  end;

begin
  StarCount := EnsureRange(ReadInt('Constellations.GalaxyCountStars', 73), 1, 4096);
  SectorCount := EnsureRange(ReadInt(Prefix + 'SectorCount', 20), 20, 127);
  FirstCustomSector := EnsureRange(ReadInt(Prefix + 'FirstCustomSector', 20), 0, SectorCount);
  PreserveVanillaStars := ReadBool(Prefix + 'PreserveVanillaStars', True);
  RoundRobin := ReadText(Prefix + 'DistributionMode', Mode)
      and ((LowerCase(Mode) = 'roundrobin') or (LowerCase(Mode) = 'round-robin'));
  RetryLimit := EnsureRange(ReadInt(Prefix + 'RetryLimit', 1), 1, 100000);
  GeometryRetryLimit := EnsureRange(ReadInt(Prefix + 'GeometryRetryLimit', 1000), 0, 1000);
  GeometryRetryBudgetMs := EnsureRange(ReadInt(Prefix + 'GeometryRetryBudgetMs', 20000), 0, 600000);
  ContourFallbackEnabled := ReadBool(Prefix + 'ContourFallback', True);

  Defaults.Enabled := ReadBool(Prefix + 'SectorDefaults.Enabled', True);
  Defaults.Weight := EnsureRange(ReadInt(Prefix + 'SectorDefaults.Weight', 1), 0, 100000);
  Defaults.MinimumStars := EnsureRange(ReadInt(Prefix + 'SectorDefaults.MinStars', 0), 0, StarCount);
  Defaults.MaximumStars := EnsureRange(ReadInt(Prefix + 'SectorDefaults.MaxStars', 0), 0, StarCount);
  SetLength(Rules, SectorCount);
  for I := 0 to SectorCount - 1 do
  begin
    Rules[I].Enabled := ReadBool(Prefix + 'Sectors.' + IntToStr(I) + '.Enabled', Defaults.Enabled);
    Rules[I].Weight := EnsureRange(ReadInt(Prefix + 'Sectors.' + IntToStr(I) + '.Weight', Defaults.Weight), 0, 100000);
    Rules[I].MinimumStars := EnsureRange(ReadInt(Prefix + 'Sectors.' + IntToStr(I) + '.MinStars', Defaults.MinimumStars), 0, StarCount);
    Rules[I].MaximumStars := EnsureRange(ReadInt(Prefix + 'Sectors.' + IntToStr(I) + '.MaxStars', Defaults.MaximumStars), 0, StarCount);
  end;

  SetLength(StarPlan, StarCount);
  SetLength(Loads, SectorCount);
  for I := 0 to High(StarPlan) do
    StarPlan[I] := -1;
  for I := 0 to High(Loads) do
    Loads[I] := 0;
  if PreserveVanillaStars then
    PreservedCount := Min(72, StarCount)
  else
    PreservedCount := 0;
  for Star := 0 to PreservedCount - 1 do
  begin
    Sector := VanillaSectorForStar(Star, SectorCount);
    StarPlan[Star] := Sector;
    Inc(Loads[Sector]);
  end;
  // Explicit entries run after the compatibility mapping, so a DAT author can
  // override even one of the original 72 systems.
  for Star := 0 to StarCount - 1 do
  begin
    Sector := ReadInt(Prefix + 'Stars.' + IntToStr(Star) + '.Sector', -1);
    if (Sector < 0) or (Sector >= SectorCount) then
      Continue;
    if StarPlan[Star] >= 0 then
      Dec(Loads[StarPlan[Star]]);
    StarPlan[Star] := Sector;
    Inc(Loads[Sector]);
  end;

  SetLength(Eligible, 0);
  if not PreserveVanillaStars then
    FirstCustomSector := 0;
  for Sector := FirstCustomSector to SectorCount - 1 do
    if Rules[Sector].Enabled and (Rules[Sector].Weight > 0) then
    begin
      SetLength(Eligible, Length(Eligible) + 1);
      Eligible[High(Eligible)] := Sector;
    end;
  if Length(Eligible) = 0 then
  begin
    SetLength(Eligible, SectorCount);
    for Sector := 0 to SectorCount - 1 do
      Eligible[Sector] := Sector;
    XenoLogWarning(ModName, 'no enabled sector remained; all sectors were used as fallback');
  end;

  NextUnassigned := 0;
  for I := 0 to High(Eligible) do
  begin
    Sector := Eligible[I];
    while (Loads[Sector] < Rules[Sector].MinimumStars) and HasCapacity(Sector) do
    begin
      Star := TakeNextUnassigned;
      if Star < 0 then
        Break;
      StarPlan[Star] := Sector;
      Inc(Loads[Sector]);
    end;
  end;

  SetLength(Scores, SectorCount);
  for I := 0 to High(Scores) do
    Scores[I] := 0;
  repeat
    Star := TakeNextUnassigned;
    if Star < 0 then
      Break;
    TotalWeight := 0;
    Selected := -1;
    SelectedScore := Low(Int64);
    for I := 0 to High(Eligible) do
    begin
      Sector := Eligible[I];
      if not HasCapacity(Sector) then
        Continue;
      if RoundRobin then
        Weight := 1
      else
        Weight := EnsureRange(Rules[Sector].Weight, 1, 100000);
      Inc(TotalWeight, Weight);
      Inc(Scores[Sector], Weight);
      if Scores[Sector] > SelectedScore then
      begin
        Selected := Sector;
        SelectedScore := Scores[Sector];
      end;
    end;
    if Selected < 0 then
    begin
      Selected := Eligible[Star mod Length(Eligible)];
      XenoLogWarning(ModName, 'sector maximums were exhausted; remaining stars ignored maximums');
    end
    else
      Dec(Scores[Selected], TotalWeight);
    StarPlan[Star] := Selected;
    Inc(Loads[Selected]);
  until False;
  PlanReady := True;
end;

procedure LoadNativeSettings;
var
  Ini: TXenoIni;
  Mode: WideString;
begin
  ThrottleEnabled := True;
  ReferenceStars := 73;
  FirstGameplayDay := 301;
  Ini := XenoOpenModIni(ModName, GeneratorIni);
  if Ini <> nil then
    try
      ThrottleEnabled := Ini.ReadInt('RuntimeBases', 'Enabled', 1, 0, 1) <> 0;
      ReferenceStars := Ini.ReadInt('RuntimeBases', 'ReferenceStars', 73, 1, 4096);
      FirstGameplayDay := Ini.ReadInt('RuntimeBases', 'FirstGameplayDay', 301, 0, 1000000);
    finally
      Ini.Free;
    end;
  Ini := XenoOpenModIni(ModName, NextDayIni);
  if Ini <> nil then
    try
      Mode := LowerCase(Ini.ReadString('NextDay', 'Mode', 'Compatible'));
      if (Ini.ReadInt('Plugin', 'Enabled', 1, 0, 1) <> 0) and (Mode <> 'compatible') and (Mode <> 'profile') then
        XenoLogWarning(ModName, 'XenoNextDay Mode=' + Mode + ' is not ported; the stock daily processing runs');
    finally
      Ini.Free;
    end;
end;

function XenoBigGalaxySectorCount(Default: Integer): Integer;
begin
  Result := Default;
  Active := XenoPluginEnabled(ModName, GeneratorIni);
  PlanReady := False;
  if not Active then
    Exit;
  try
    LoadNativeSettings;
    BuildPlan;
    Result := SectorCount;
    XenoLog(ModName, 'generator sectors=' + IntToStr(SectorCount) + ' stars=' + IntToStr(Length(StarPlan)) + ' retry_limit='
        + IntToStr(RetryLimit) + ' geometry_retries=' + IntToStr(GeometryRetryLimit) + ' station_throttle=' + IntToStr(Ord(ThrottleEnabled)));
  except
    on E: Exception do
    begin
      // Same fallback as the DLL: vanilla 20 sectors.
      XenoLogWarning(ModName, 'generator configuration failed: ' + E.Message);
      SectorCount := 20;
      RetryLimit := 1;
      GeometryRetryLimit := 1000;
      GeometryRetryBudgetMs := 20000;
      ContourFallbackEnabled := True;
      PlanReady := False;
      Result := Default;
    end;
  end;
end;

function XenoBigGalaxyPlannedSector(StarIndex: Integer): Integer;
begin
  if not Active then
    Exit(-1);
  if PlanReady and (StarIndex >= 0) and (StarIndex < Length(StarPlan)) then
    Result := StarPlan[StarIndex]
  else
    Result := VanillaSectorForStar(StarIndex, SectorCount);
  Result := EnsureRange(Result, 0, SectorCount - 1);
end;

{ Outline crossings (layout_geometry.cpp) }

function NearPoint(X, Y: Double; const P: TOutlinePoint): Boolean;
begin
  Result := (Abs(X - P.X) < PointTolerance) and (Abs(Y - P.Y) < PointTolerance);
end;

function SegmentsCross(const A1, A2, B1, B2: TOutlinePoint): Boolean;
var
  RX, RY, SX, SY, Denominator, QX, QY, T, U, X, Y: Double;
begin
  RX := A2.X - A1.X;
  RY := A2.Y - A1.Y;
  SX := B2.X - B1.X;
  SY := B2.Y - B1.Y;
  Denominator := RX * SY - RY * SX;
  if Abs(Denominator) < ParallelEpsilon then
    Exit(False);
  QX := B1.X - A1.X;
  QY := B1.Y - A1.Y;
  T := (QX * SY - QY * SX) / Denominator;
  U := (QX * RY - QY * RX) / Denominator;
  if (T < 0) or (T > 1) or (U < 0) or (U > 1) then
    Exit(False);
  X := A1.X + T * RX;
  Y := A1.Y + T * RY;
  Result := not NearPoint(X, Y, A1) and not NearPoint(X, Y, A2) and not NearPoint(X, Y, B1) and not NearPoint(X, Y, B2);
end;

// Proper crossings between sector outline edges. Shared vertices,
// T-junctions and collinear shared borders of adjacent sectors are normal.
function CountOutlineCrossings(Galaxy: TGalaxy; out FirstSector, SecondSector: Integer): Integer;
var
  Points: array of TOutlinePoint;
  Rings: array of TOutlineRing;
  Sector, I, J, EdgeA, EdgeB, StartB, Depth: Integer;
  Polygon: TPolygon2D;
  Point: PPointF;
  A, B: TOutlineRing;
begin
  Result := 0;
  FirstSector := -1;
  SecondSector := -1;
  SetLength(Points, 0);
  SetLength(Rings, 0);
  for Sector := 0 to Galaxy.Constellations.Count - 1 do
  begin
    Polygon := TConstellation(Galaxy.Constellations[Sector]).OutlinePolygons;
    Depth := 0;
    while (Polygon <> nil) and (Depth < 64) do
    begin
      SetLength(Rings, Length(Rings) + 1);
      with Rings[High(Rings)] do
      begin
        First := Length(Points);
        Count := 0;
        if Polygon.Points <> nil then
          Count := Polygon.Points.Count;
        SetLength(Points, First + Count);
        for J := 0 to Count - 1 do
        begin
          Point := Polygon.Points[J];
          Points[First + J].X := Point^.X;
          Points[First + J].Y := Point^.Y;
          if J = 0 then
          begin
            MinX := Point^.X;
            MaxX := Point^.X;
            MinY := Point^.Y;
            MaxY := Point^.Y;
          end
          else
          begin
            MinX := Min(MinX, Point^.X);
            MaxX := Max(MaxX, Point^.X);
            MinY := Min(MinY, Point^.Y);
            MaxY := Max(MaxY, Point^.Y);
          end;
        end;
      end;
      Rings[High(Rings)].Sector := Sector;
      Polygon := Polygon.Next;
      Inc(Depth);
    end;
  end;
  for I := 0 to High(Rings) do
  begin
    A := Rings[I];
    if A.Count < 2 then
      Continue;
    for J := I to High(Rings) do
    begin
      B := Rings[J];
      if (B.Count < 2) or (A.MinX > B.MaxX + PointTolerance) or (B.MinX > A.MaxX + PointTolerance)
          or (A.MinY > B.MaxY + PointTolerance) or (B.MinY > A.MaxY + PointTolerance) then
        Continue;
      for EdgeA := 0 to A.Count - 1 do
      begin
        // A ring is compared with itself once per edge pair.
        if I = J then
          StartB := EdgeA + 1
        else
          StartB := 0;
        for EdgeB := StartB to B.Count - 1 do
          if SegmentsCross(Points[A.First + EdgeA], Points[A.First + (EdgeA + 1) mod A.Count], Points[B.First + EdgeB],
              Points[B.First + (EdgeB + 1) mod B.Count]) then
          begin
            if Result = 0 then
            begin
              FirstSector := A.Sector;
              SecondSector := B.Sector;
            end;
            Inc(Result);
          end;
      end;
    end;
  end;
end;

function XenoBigGalaxyLayoutDone(Galaxy: TGalaxy; Attempts: Integer): Boolean;
var
  Crossings, FirstSector, SecondSector: Integer;
  Elapsed: QWord;
  Exhausted: Boolean;
begin
  if not Active then
    Exit(Attempts > 1000);
  if Attempts <= 1 then
  begin
    LayoutStartTick := GetTickCount64;
    LayoutGeometryRejects := 0;
  end;
  // Up to RetryLimit the stock criteria decide alone.
  if Attempts <= RetryLimit then
    Exit(False);
  if GeometryRetryLimit = 0 then
    Exit(True);
  Elapsed := GetTickCount64 - LayoutStartTick;
  Crossings := CountOutlineCrossings(Galaxy, FirstSector, SecondSector);
  Exhausted := (Attempts > GeometryRetryLimit) or (Elapsed >= GeometryRetryBudgetMs);
  if (Crossings > 0) and not Exhausted then
  begin
    Inc(LayoutGeometryRejects);
    Exit(False);
  end;
  if Crossings > 0 then
    XenoLogWarning(ModName, 'layout_geometry=accepted_with_crossings attempts=' + IntToStr(Attempts) + ' crossings='
        + IntToStr(Crossings) + ' sectors=' + IntToStr(FirstSector) + ',' + IntToStr(SecondSector))
  else
    XenoLog(ModName, 'layout_geometry=clean attempts=' + IntToStr(Attempts) + ' rejects=' + IntToStr(LayoutGeometryRejects)
        + ' ms=' + IntToStr(Elapsed));
  Result := True;
end;

function XenoBigGalaxyCrossings(Galaxy: TGalaxy): Integer;
var
  FirstSector, SecondSector: Integer;
begin
  Result := CountOutlineCrossings(Galaxy, FirstSector, SecondSector);
end;

function XenoBigGalaxySegmentsCross(AX1, AY1, AX2, AY2, BX1, BY1, BX2, BY2: Double): Boolean;
var
  A1, A2, B1, B2: TOutlinePoint;
begin
  A1.X := AX1; A1.Y := AY1; A2.X := AX2; A2.Y := AY2;
  B1.X := BX1; B1.Y := BY1; B2.X := BX2; B2.Y := BY2;
  Result := SegmentsCross(A1, A2, B1, B2);
end;

function XenoBigGalaxyPlanLength: Integer;
begin
  if PlanReady then
    Result := Length(StarPlan)
  else
    Result := 0;
end;

function XenoBigGalaxyContourFallback: Boolean;
begin
  Result := Active and ContourFallbackEnabled;
end;

function XenoBigGalaxyRunStationSpawning(Galaxy: TGalaxy): Boolean;
var
  Day, StarCount: Integer;
  Slot, Previous, Current: Int64;
begin
  Result := True;
  if not Active or not ThrottleEnabled or (Galaxy = nil) then
    Exit;
  Day := Galaxy.CurrentTurn;
  StarCount := Galaxy.Stars.Count;
  if (Day < FirstGameplayDay) or (StarCount <= ReferenceStars) or (ReferenceStars <= 0) then
    Exit;
  // Station spawning scans every star; spread it so a big galaxy spawns at
  // the rate of the reference one.
  Slot := Int64(Day) - FirstGameplayDay;
  Previous := (Slot * ReferenceStars) div StarCount;
  Current := ((Slot + 1) * ReferenceStars) div StarCount;
  Result := Current <> Previous;
end;

procedure OnGalaxyCreated(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcGalaxyCreatedEvent(Payload^) do
    SectorCount := XenoBigGalaxySectorCount(SectorCount);
end;

procedure OnPlanStar(User, Payload: Pointer); cdecl;
var
  Planned: Integer;
begin
  with TXenoFpcGalaxyPlanStarEvent(Payload^) do
  begin
    Planned := XenoBigGalaxyPlannedSector(StarIndex);
    if Planned >= 0 then
      Sector := Planned;
  end;
end;

procedure OnLayoutDone(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcGalaxyLayoutEvent(Payload^) do
    if Active then
      Done := Ord(XenoBigGalaxyLayoutDone(TGalaxy(Galaxy), Attempts));
end;

procedure OnContourNoEar(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcContourEvent(Payload^) do
    if XenoBigGalaxyContourFallback then
      RemoveVertex := 1;
end;

procedure OnStationSpawning(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcStationSpawningEvent(Payload^) do
    if (Run <> 0) and not XenoBigGalaxyRunStationSpawning(TGalaxy(Galaxy)) then
      Run := 0;
end;

initialization
  XenoSubscribe('Galaxy.Created', @OnGalaxyCreated, nil);
  XenoSubscribe('Galaxy.PlanStar', @OnPlanStar, nil);
  XenoSubscribe('Galaxy.LayoutDone', @OnLayoutDone, nil);
  XenoSubscribe('Galaxy.ContourNoEar', @OnContourNoEar, nil);
  XenoSubscribe('Galaxy.StationSpawning', @OnStationSpawning, nil);
{$ENDIF}
end.
