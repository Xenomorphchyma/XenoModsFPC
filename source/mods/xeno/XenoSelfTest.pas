unit XenoSelfTest;

{$I GameOptions.inc}

// In-game test run for XenoModsFPC: Rangers.exe --xeno-selftest
// Once the main menu is up it checks the pure mod logic (the cases of the
// original native_tests.cpp files), the plugin host (field map, events,
// plugin script functions), then generates a real new game with the selected
// mods, runs galaxy turns, exercises the mod script libraries and a
// save/load round trip. Results go to rangers-fpc.log and to
// <user dir>\xeno_selftest.txt; the process exits with 0 (pass) or 1.
interface

implementation

{$IFDEF XENO_MODS}
uses
  Classes,
  SysUtils,
  Math,
  GameDiagnostics,
  EC_Str,
  EC_Expression,
  NativeScriptLibrary,
  GR_Main,
  Globals,
  GlobalsV,
  ThreadCalc,
  fGameSettings,
  aGalaxy,
  aGalaxyStruct,
  aShip,
  aKling,
  aRanger,
  aPlayer,
  aItem,
  aSaveLoad,
  aPlanet,
  fHangar,
  GameInput,
  GI_MessageLoop,
  GI_GraphButton,
  GR_Music,
  XenoModsHost,
  XenoPluginHost,
  XenoBigGalaxy,
  XenoEquipmentInflation,
  XenoMusicFlow,
  XenoDomRangers;

var
  Requested: Boolean = False;
  Started: Boolean = False;
  TurnCount: Integer = 5;
  Report: TStringList;
  Failures, Passes, Skips: Integer;
  Stage: WideString = '';

procedure Line(const Text: WideString; Level: TGameLogLevel = gllInfo);
begin
  Report.Add(UTF8Encode(Text));
  LogGameMessage(Level, 'xeno-test', Text);
end;

procedure Check(Condition: Boolean; const Name: WideString; const Detail: WideString = '');
begin
  if Condition then
  begin
    Inc(Passes);
    Line('PASS ' + Name);
  end
  else
  begin
    Inc(Failures);
    if Detail <> '' then
      Line('FAIL ' + Name + ': ' + Detail, gllError)
    else
      Line('FAIL ' + Name, gllError);
  end;
end;

procedure Skip(const Name, Reason: WideString);
begin
  Inc(Skips);
  Line('SKIP ' + Name + ': ' + Reason, gllWarning);
end;

{ Script library calls through the same path RScript uses }

function CallScript(const LibraryName, Signature: WideString; const Args: array of PtrInt; out Value: PtrInt): Boolean;
var
  Handle: Cardinal;
  Cell: TVarEC;
  Values: array of TVarEC;
  I: Integer;
begin
  Result := False;
  Value := 0;
  Handle := LoadNativeScriptLibrary(LibraryName);
  if Handle = 0 then
    Exit;
  Cell := TVarEC.Create(vkEmpty);
  SetLength(Values, Length(Args) + 1);
  try
    for I := 0 to High(Values) do
      Values[I] := TVarEC.Create(vkEmpty);
    if not InitNativeScriptFunction(Cell, Handle, ExtractDelimitedPartW(Signature, 1, ','), Signature) then
      Exit;
    for I := 0 to High(Args) do
      if LowerCase(ExtractDelimitedPartW(Signature, I + 2, ',')) = 'dword' then
        Values[I + 1].SetDword(PtrUInt(Args[I]))
      else
        Values[I + 1].SetInt(Integer(Args[I]));
    InvokeNativeScriptFunction(Cell, Values, nil);
    if LowerCase(ExtractDelimitedPartW(Signature, 0, ',')) = 'dword' then
      Value := PtrInt(Values[0].GetDword)
    else
      Value := Values[0].GetInt;
    Result := True;
  finally
    for I := 0 to High(Values) do
      Values[I].Free;
    Cell.Free;
  end;
end;

function ScriptValue(const LibraryName, Signature: WideString; const Args: array of PtrInt): PtrInt;
begin
  if not CallScript(LibraryName, Signature, Args, Result) then
    Result := Low(Integer);
end;

{ Pure logic: the cases of the original native tests }

procedure TestInflationMath;
begin
  Check(EffectiveFactor(100, 110) = 100, 'inflation: 100% does not drift');
  Check(EffectiveFactor(200, 80) = 180, 'inflation: artefact elasticity');
  Check(EffectiveFactor(200, 90) = 190, 'inflation: hull elasticity');
  Check(EffectiveFactor(200, 100) = 200, 'inflation: system elasticity');
  Check(EffectiveFactor(200, 110) = 210, 'inflation: weapon elasticity');
  Check(ApplyFactors(1000, 210, 130) = 2730, 'inflation: factor product');
  Check(RecoverBase(2730, 210, 130) = 1000, 'inflation: base recovery');
  Check(ApplyFactors(1000, 180, 70) = 1260, 'inflation: market discount');
  Check(ApplyFactors(High(Integer), 100000, 130) = High(Integer), 'inflation: overflow clamps to MaxInt');
  Check(ApplyFactors(1, 1, 1) = 1, 'inflation: minimum price 1');
end;

procedure TestGeneratorLogic;
var
  I, Count: Integer;
begin
  Check(VanillaSectorForStar(0, 20) = 0, 'generator: star 0 vanilla sector');
  Check(VanillaSectorForStar(17, 20) = 17, 'generator: star 17 vanilla sector');
  Check(VanillaSectorForStar(18, 20) = 0, 'generator: star 18 wraps mod 18');
  Check(VanillaSectorForStar(66, 20) = 18, 'generator: stars 65..68 go to sector 18');
  Check(VanillaSectorForStar(69, 20) = 12, 'generator: star 69 goes to sector 12');
  Check(VanillaSectorForStar(70, 55) = 19, 'generator: stars 70/71 go to sector 19');
  Count := 0;
  for I := 0 to 199 do
    if (VanillaSectorForStar(I, 55) < 0) or (VanillaSectorForStar(I, 55) >= 55) then
      Inc(Count);
  Check(Count = 0, 'generator: vanilla mapping stays in range for 55 sectors');
  // Outline crossings: a proper crossing, a shared vertex, a T-junction, collinear borders.
  Check(XenoBigGalaxySegmentsCross(0, 0, 10, 10, 0, 10, 10, 0), 'geometry: X crossing is reported');
  Check(not XenoBigGalaxySegmentsCross(0, 0, 10, 0, 10, 0, 10, 10), 'geometry: shared vertex is not a crossing');
  Check(not XenoBigGalaxySegmentsCross(0, 0, 10, 0, 5, 0, 5, 10), 'geometry: T-junction is not a crossing');
  Check(not XenoBigGalaxySegmentsCross(0, 0, 10, 0, 2, 0, 8, 0), 'geometry: collinear shared border is not a crossing');
  Check(not XenoBigGalaxySegmentsCross(0, 0, 1, 1, 5, 5, 6, 7), 'geometry: distant segments do not cross');
end;

procedure TestMusicLogic;
begin
  if not XenoMusicFlowEnabled then
  begin
    Skip('musicflow', 'XenoMusicFlow is not selected');
    Exit;
  end;
  Check(XenoMusicFlowIsPlaceCategory('StarMap'), 'music: space is a place');
  Check(XenoMusicFlowIsPlaceCategory('Nation.PelengPirate'), 'music: planet is a place');
  Check(XenoMusicFlowIsPlaceCategory('RC'), 'music: game station is a place');
  Check(XenoMusicFlowIsPlaceCategory('SSB_licensed'), 'music: mod station is a place');
  Check(not XenoMusicFlowIsPlaceCategory('battle'), 'music: battle switches at once (any case)');
  Check(not XenoMusicFlowIsPlaceCategory('QuestSoundtrack.ForQuest_Gaal'), 'music: quest soundtrack prefix');
  Check(not XenoMusicFlowIsPlaceCategory(''), 'music: playlist reset');
  // 0 = wait, 1 = crossfade, 2 = let end (defaults 45/8/40 s).
  Check(XenoMusicFlowDecide(44999, 200000) = 0, 'music: hold');
  Check(XenoMusicFlowDecide(45000, 200000) = 1, 'music: long rest crossfades');
  Check(XenoMusicFlowDecide(45000, 48000) = 2, 'music: ends soon');
  Check(XenoMusicFlowDecide(45000, 48001) = 1, 'music: just enough to crossfade');
  Check(XenoMusicFlowDecide(45000, -1) = 1, 'music: unknown rest crossfades');
end;

procedure TestCamouflageLogic;
begin
  Check(IsConfusedByChameleon(0, True, 0, False, 2), 'camouflage: managed mask confuses');
  Check(not IsConfusedByChameleon(1, True, 0, False, 0), 'camouflage: other series sees through');
  Check(not IsConfusedByChameleon(0, True, 0, True, 1), 'camouflage: detected and not upgraded');
  Check(IsConfusedByChameleon(0, True, 0, True, 2), 'camouflage: upgraded logic survives detection');
  Check(not IsConfusedByChameleon(3, True, 0, False, 2), 'camouflage: invalid series');
end;

{ Host }

procedure TestHost;
var
  Size: Integer;
  TypeText: AnsiString;
  Value: PtrInt;
begin
  Check(XenoFieldOffset('TItem', 'Cost', Size, TypeText) = PtrInt(PtrUInt(@TItem(nil).Cost)), 'host: TItem.Cost offset',
      IntToStr(XenoFieldOffset('TItem', 'Cost', Size, TypeText)));
  Check((Size = SizeOf(Integer)) and SameText(TypeText, 'Integer'), 'host: TItem.Cost size and type', TypeText);
  Check(XenoFieldOffset('TRanger', 'ChameleonActive', Size, TypeText) = PtrInt(PtrUInt(@TShip(nil).ChameleonActive)),
      'host: inherited field TRanger.ChameleonActive');
  Check(XenoFieldOffset('TShip', 'NoSuchField', Size, TypeText) = -1, 'host: unknown field');
  Check(XenoFieldOffset('THangarShipSlot', 'ShipId', Size, TypeText) >= 0, 'host: record field THangarShipSlot.ShipId');
  if XenoModActive('XenoFpcExample') then
  begin
    Check(XenoLoadedPluginCount >= 1, 'host: example plugin loaded', IntToStr(XenoLoadedPluginCount));
    Check(CallScript('XenoFpcExample', 'int,XenoFpcExample_Add,int,int', [2, 3], Value) and (Value = 5),
        'host: plugin script function through the script engine', IntToStr(Value));
  end
  else
    Skip('host: external plugin', 'select a mod with XenoFpcExample.XenoPlugin.dll to test it');
end;

{ Integration }

function FindItem(out Item: TItem): Boolean;
var
  I: Integer;
  Player: TPlayer;
begin
  Result := False;
  Item := nil;
  Player := GetPlayer;
  if Player = nil then
    Exit;
  for I := 0 to Player.Inventory.Count - 1 do
    if (TObject(Player.Inventory[I]) is TEquipment) and (TItem(Player.Inventory[I]).Cost > 10) then
    begin
      Item := TItem(Player.Inventory[I]);
      Exit(True);
    end;
end;

procedure GenerateGame;
var
  I: Integer;
  Started: QWord;
begin
  Started := GetTickCount64;
  NewGameGenerationThread := TThreadCreateNewGame.Create('generation');
  NewGameGenerationThread.PlayerRace := oiHuman;
  for I := 0 to 7 do
    NewGameGenerationThread.DifficultyLevels[I] := 2;
  NewGameGenerationThread.CaptainPortraitIndex := 0;
  NewGameGenerationThread.PlayerName := 'XenoSelfTest';
  NewGameGenerationThread.CharacterPreset := 3;
  NewGameGenerationThread.StartingItemTypes[0] := 43;
  NewGameGenerationThread.StartingItemTypes[1] := 44;
  NewGameGenerationThread.StartingSkills[0] := psAccuracy;
  NewGameGenerationThread.StartingSkills[1] := psTrading;
  NewGameGenerationThread.Start;
  NewGameGenerationThread.WaitForIdle(INFINITE);
  Line('new game generated in ' + IntToStr(GetTickCount64 - Started) + ' ms; turn=' + IntToStr(Galaxy.CurrentTurn));
end;

procedure TestGalaxy;
var
  Crossings, Runs, Day, I, Empty: Integer;
begin
  if not XenoModActive('XenoBigGalaxy') then
  begin
    Skip('biggalaxy', 'XenoBigGalaxy is not selected');
    Exit;
  end;
  Check(Galaxy.ConstellationCount = 55, 'biggalaxy: 55 sectors', IntToStr(Galaxy.ConstellationCount));
  Check(Galaxy.Constellations.Count = Galaxy.ConstellationCount, 'biggalaxy: constellation objects',
      IntToStr(Galaxy.Constellations.Count));
  Check(XenoBigGalaxyPlanLength = Galaxy.Stars.Count, 'biggalaxy: star plan covers every star',
      IntToStr(XenoBigGalaxyPlanLength) + '/' + IntToStr(Galaxy.Stars.Count));
  Crossings := XenoBigGalaxyCrossings(Galaxy);
  Check(Crossings = 0, 'biggalaxy: sector borders do not cross', IntToStr(Crossings));
  Empty := 0;
  for I := 0 to Galaxy.Constellations.Count - 1 do
    if TConstellation(Galaxy.Constellations[I]).Stars.Count = 0 then
      Inc(Empty);
  Line('biggalaxy: sectors without stars=' + IntToStr(Empty));
  Runs := 0;
  for Day := 301 to 300 + Galaxy.Stars.Count do
  begin
    Galaxy.CurrentTurn := Day;
    if XenoBigGalaxyRunStationSpawning(Galaxy) then
      Inc(Runs);
  end;
  Check(Runs = 73, 'biggalaxy: station spawning keeps the 73-star rate', IntToStr(Runs) + ' runs per ' + IntToStr(Galaxy.Stars.Count) + ' days');
end;

procedure RunTurns(Count: Integer);
var
  I: Integer;
  StartTurn: Integer;
  Started: QWord;
begin
  StartTurn := Galaxy.CurrentTurn;
  Started := GetTickCount64;
  for I := 1 to Count do
  begin
    StartGalaxyTurnCalculation;
    WaitForTurnCalculation;
    TurnCalculationThread.CheckFailure;
  end;
  Check(Galaxy.CurrentTurn = StartTurn + Count, 'turns: galaxy advanced ' + IntToStr(Count) + ' days',
      IntToStr(StartTurn) + ' -> ' + IntToStr(Galaxy.CurrentTurn));
  Line('turns: ' + IntToStr(Count) + ' days in ' + IntToStr(GetTickCount64 - Started) + ' ms');
end;

procedure TestScriptLibraries;
var
  Ranger: TRanger;
  Kling: TKling;
  I, J: Integer;
  Ship: TShip;
  Effective: Boolean;
begin
  if XenoModActive('XenoCoalitionSupplyLines') then
  begin
    Check(ScriptValue('XenoCoalitionSupplyLines.XenoPlugin', 'int,XenoCoalitionSupplyLines_GetConfigInt,int', [101]) = 2,
        'supplylines: CargoPerEnhancedShip from INI');
    Check(ScriptValue('XenoCoalitionSupplyLines.XenoPlugin', 'int,XenoCoalitionSupplyLines_GetConfigInt,int', [11]) = 4,
        'supplylines: Band80To100 TransportMin');
    Check(ScriptValue('XenoCoalitionSupplyLines.XenoPlugin', 'int,XenoCoalitionSupplyLines_GetConfigInt,int', [999]) = -1,
        'supplylines: unknown key');
  end
  else
    Skip('supplylines', 'not selected');

  if XenoModActive('XenoDomRangers') then
  begin
    Check(ScriptValue('XenoDomRangers.XenoPlugin', 'int,XenoDomRangers_IsReady', []) = 1, 'domrangers: ready');
    Check(ScriptValue('XenoDomRangers.XenoPlugin', 'int,XenoDomRangers_GetConfigInt,int', [3]) = 3, 'domrangers: MaximumSpecialists');
    Ranger := nil;
    Kling := nil;
    for I := 0 to Galaxy.Rangers.Count - 1 do
      if (TObject(Galaxy.Rangers[I]) is TRanger) and not (TObject(Galaxy.Rangers[I]) is TPlayer) then
      begin
        Ranger := TRanger(Galaxy.Rangers[I]);
        Break;
      end;
    for I := 0 to Galaxy.Stars.Count - 1 do
    begin
      for J := 0 to TStar(Galaxy.Stars[I]).Ships.Count - 1 do
      begin
        Ship := TStar(Galaxy.Stars[I]).Ships[J];
        if Ship is TKling then
        begin
          Kling := TKling(Ship);
          Break;
        end;
      end;
      if Kling <> nil then
        Break;
    end;
    if (Ranger = nil) or (Kling = nil) then
      Skip('domrangers: camouflage', 'no NPC ranger or dominator in this galaxy')
    else
    begin
      Check(not Kling.IsPlayerCamouflageEffective(Ranger), 'domrangers: unregistered NPC is seen');
      Check(ScriptValue('XenoDomRangers.XenoPlugin', 'int,XenoDomRangers_SetNpcChameleon,dword,int,int,int,int,int',
          [PtrInt(Ranger), Ranger.Id, Ord(Kling.DominatorSeries), Ord(Ranger.TypeId), Ord(Kling.TypeId), 0]) = 1,
          'domrangers: SetNpcChameleon');
      Check(Ranger.ChameleonActive and (Ranger.ChameleonSeries = Kling.DominatorSeries), 'domrangers: mask written to the ranger');
      Check(Kling.IsPlayerCamouflageEffective(Ranger), 'domrangers: dominator is confused by the registered NPC');
      Effective := False;
      Check(XenoRaiseCamouflage(Kling, Ranger, Effective) and Effective, 'domrangers: Kling.Camouflage event handled');
      Check(ScriptValue('XenoDomRangers.XenoPlugin', 'int,XenoDomRangers_ClearNpcChameleon,dword,int,int',
          [PtrInt(Ranger), Ranger.Id, Ord(Ranger.TypeId)]) = 1, 'domrangers: ClearNpcChameleon');
      Check(not Ranger.ChameleonActive, 'domrangers: mask restored');
      Check(not Kling.IsPlayerCamouflageEffective(Ranger), 'domrangers: cleared NPC is seen again');
    end;
  end
  else
    Skip('domrangers', 'not selected');
end;

procedure TestInflation;
var
  Item: TItem;
  ItemId: Cardinal;
  CostBefore, Factor: Integer;
  SavePath: WideString;
begin
  if not XenoModActive('XenoEquipmentInflation') then
  begin
    Skip('inflation', 'not selected');
    Exit;
  end;
  Check(XenoInflationTrackedCount > 1000, 'inflation: items tracked', IntToStr(XenoInflationTrackedCount));
  Factor := XenoInflationGlobalFactor;
  Check(Factor >= 100, 'inflation: the mod script configured and pulsed the library', IntToStr(Factor));
  if not FindItem(Item) then
  begin
    Skip('inflation: save/load', 'player carries no equipment');
    Exit;
  end;
  ItemId := Item.Id;
  CostBefore := Item.Cost;
  // Raise the factor so that the saved base price differs from the live price.
  Check(ScriptValue('XenoEquipmentInflation.XenoPlugin', 'int,XenoEquipmentInflation_Pulse,int', [Max(Factor, 100) + 50]) > 0,
      'inflation: Pulse accepted');
  Check(Item.Cost > CostBefore, 'inflation: live price follows the factor', IntToStr(CostBefore) + ' -> ' + IntToStr(Item.Cost));
  Check(XenoRaiseItemSaveCost(Item, Item.Cost) < Item.Cost, 'inflation: Item.SaveCost stores the base price',
      IntToStr(XenoRaiseItemSaveCost(Item, Item.Cost)) + ' vs ' + IntToStr(Item.Cost));
  CostBefore := Item.Cost;
  SavePath := GetGameUserDirectory + 'Save\xeno_selftest.sav';
  Check(SaveGameToFile(SavePath, 'XenoSelfTest'), 'save: written');
  Check(LoadGameFromFile(SavePath), 'load: read back');
  Item := TItem(Galaxy.IdToItem(ItemId, False));
  if Item = nil then
    Check(False, 'inflation: item survives save/load', 'item ' + IntToStr(ItemId) + ' missing')
  else
    Check(Item.Cost = CostBefore, 'inflation: price after load is not inflated twice',
        IntToStr(CostBefore) + ' -> ' + IntToStr(Item.Cost));
  if XenoModActive('XenoBigGalaxy') then
    Check(Galaxy.ConstellationCount = 55, 'biggalaxy: 55 sectors after load', IntToStr(Galaxy.ConstellationCount));
  DeleteFile(UTF8Encode(SavePath));
end;

{ Hangar paging on the real hangar screen (no rendering loop needed) }

procedure SortById(List: TList);
var
  I, J: Integer;
  Value: Pointer;
begin
  for I := 1 to List.Count - 1 do
  begin
    Value := List[I];
    J := I;
    while (J > 0) and (TShip(List[J - 1]).Id > TShip(Value).Id) do
    begin
      List[J] := List[J - 1];
      Dec(J);
    end;
    List[J] := Value;
  end;
end;

function SlotsShow(Hangar: TfHangar; Candidates: TList; First: Integer): Boolean;
var
  Slot, Index: Integer;
begin
  Result := True;
  for Slot := 1 to 8 do
  begin
    Index := First + Slot - 1;
    if Index < Candidates.Count then
      Result := Result and (Hangar.ShipSlots[Slot].ShipId = TShip(Candidates[Index]).Id)
          and (Hangar.ShipSlots[Slot].AnimationState in [1, 2])
    else
      Result := Result and (Hangar.ShipSlots[Slot].ShipId = 0);
  end;
end;

function SlotText(Hangar: TfHangar): WideString;
var
  Slot: Integer;
begin
  Result := '';
  for Slot := 1 to 8 do
    Result := Result + IntToStr(Hangar.ShipSlots[Slot].ShipId) + ' ';
end;

procedure TestHangarPaging;
var
  Hangar: TfHangar;
  Player: TPlayer;
  Star, Other: TStar;
  Planet: TPlanet;
  Borrowed, Landed, Candidates: TList;
  Ship: TShip;
  I, J, Pages, Slot: Integer;
  Button: TObjectGI;
begin
  if not XenoModActive('XenoHangarPaging') then
  begin
    Skip('hangarpaging', 'not selected');
    Exit;
  end;
  Hangar := HangarScreen;
  Player := GetPlayer;
  Star := Player.CurrentStar;
  Planet := nil;
  for I := 0 to Star.Planets.Count - 1 do
    if TPlanet(Star.Planets[I]).OwnerId <> oiUninhabited then
      Planet := TPlanet(Star.Planets[I]);
  if (Hangar = nil) or (Planet = nil) then
  begin
    Skip('hangarpaging', 'no hangar screen or inhabited planet');
    Exit;
  end;
  Borrowed := TList.Create;
  Landed := TList.Create;
  Candidates := TList.Create;
  try
    // Land 13 foreign ships on the player's planet: two pages of eight.
    for J := 0 to Galaxy.Stars.Count - 1 do
    begin
      Other := TStar(Galaxy.Stars[J]);
      I := Other.Ships.Count - 1;
      while (I >= 0) and (Landed.Count < 13) do
      begin
        Ship := TShip(Other.Ships[I]);
        Dec(I);
        if (Ship = TShip(Player)) or (Ship is TKling) or (Ship.CurrentPlanet <> nil) or (Ship.DockedTo <> nil)
            or (Ship.GetShipPortraitImagePath = WideString('')) then
          Continue;
        if Other <> Star then
        begin
          Other.Ships.Extract(Ship);
          Star.Ships.Add(Ship);
          Borrowed.Add(Ship);
          Borrowed.Add(Other);
        end;
        Ship.CurrentPlanet := Planet;
        Landed.Add(Ship);
      end;
      if Landed.Count >= 13 then
        Break;
    end;
    Player.DockedTo := nil;
    Player.CurrentPlanet := Planet;
    for I := 0 to Star.Ships.Count - 1 do
    begin
      Ship := TShip(Star.Ships[I]);
      if (Ship <> TShip(Player)) and (Ship.CurrentPlanet = Planet) and (Ship.Id <> 0)
          and (Ship.GetShipPortraitImagePath <> WideString('')) then
        Candidates.Add(Ship);
    end;
    for I := 0 to Planet.Warriors.Count - 1 do
    begin
      Ship := TShip(Planet.Warriors[I]);
      if (Ship.CurrentPlanet = Planet) and (Candidates.IndexOf(Ship) < 0) and (Ship.GetShipPortraitImagePath <> WideString('')) then
        Candidates.Add(Ship);
    end;
    SortById(Candidates);
    Pages := (Candidates.Count + 7) div 8;
    Line('hangarpaging: candidates=' + IntToStr(Candidates.Count) + ' pages=' + IntToStr(Pages));
    if Candidates.Count <= 8 then
    begin
      Skip('hangarpaging', 'could not land more than eight ships');
      Exit;
    end;
    for Slot := 0 to High(Hangar.ShipSlots) do
    begin
      Hangar.ShipSlots[Slot].AnimationState := 0;
      Hangar.ShipSlots[Slot].ShipId := 0;
    end;
    XenoRaiseHangar(xeHangarOpened, Hangar);
    Check(Hangar.FindControlByPath('HangarPagingPanel') <> nil, 'hangarpaging: paging strip from the mod CFG');
    Check(XenoRaiseHangarRefresh(Hangar), 'hangarpaging: Hangar.Refresh handled with more than eight ships');
    Check(SlotsShow(Hangar, Candidates, 0), 'hangarpaging: page 1 shows the first eight ships by Id', SlotText(Hangar));
    Check(XenoRaiseHangarRefresh(Hangar) and SlotsShow(Hangar, Candidates, 0), 'hangarpaging: page stays stable on refresh');
    Check(XenoRaiseHangarKey(Hangar, VK_RIGHT), 'hangarpaging: Right arrow handled');
    Check(SlotsShow(Hangar, Candidates, 8), 'hangarpaging: page 2 shows the rest', SlotText(Hangar));
    Check((Hangar.FindControlByPath('HangarPageNumber2') <> nil) and Hangar.FindControlByPath('HangarPageNumber2').Active
        and not Hangar.FindControlByPath('HangarPageNumber1').Active, 'hangarpaging: page number label 2');
    Sleep(350); // the arrows ignore input repeated within 300 ms
    XenoRaiseHangarKey(Hangar, VK_RIGHT);
    Check(SlotsShow(Hangar, Candidates, 0), 'hangarpaging: Right on the last page wraps to page 1', SlotText(Hangar));
    Button := Hangar.FindControlByPath('HangarPagePrev');
    Check((Button is TGraphButtonGI) and Assigned(TGraphButtonGI(Button).UpCallback), 'hangarpaging: Prev button bound');
    if (Button is TGraphButtonGI) and Assigned(TGraphButtonGI(Button).UpCallback) then
    begin
      TGraphButtonGI(Button).UpCallback(Button);
      Check(SlotsShow(Hangar, Candidates, (Pages - 1) * 8), 'hangarpaging: Prev button goes to the last page', SlotText(Hangar));
    end;
    XenoRaiseHangar(xeHangarClosed, Hangar);
  finally
    for I := 0 to Landed.Count - 1 do
      TShip(Landed[I]).CurrentPlanet := nil;
    I := 0;
    while I < Borrowed.Count do
    begin
      Star.Ships.Extract(Borrowed[I]);
      TStar(Borrowed[I + 1]).Ships.Add(Borrowed[I]);
      Inc(I, 2);
    end;
    Player.CurrentPlanet := nil;
    Borrowed.Free;
    Landed.Free;
    Candidates.Free;
  end;
end;

{ MusicFlow on the live music manager }

function WaitMusicRunning(TimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(TimeoutMs);
  repeat
    if (MusicManager.Current <> nil) and MusicManager.Current.IsRunning and (MusicManager.Current.GetFileName <> '') then
      Exit(True);
    Sleep(50);
  until GetTickCount64 > Deadline;
  Result := False;
end;

procedure TestMusicFlowRuntime;
var
  Before: WideString;
begin
  if not XenoMusicFlowEnabled then
  begin
    Skip('musicflow runtime', 'not selected');
    Exit;
  end;
  if (MusicManager = nil) or (MusicManager.Current = nil) then
  begin
    Skip('musicflow runtime', 'music is disabled');
    Exit;
  end;
  MusicManager.StopImmediately;
  Sleep(300);
  MusicManager.PlayCategory('StarMap');
  if not WaitMusicRunning(5000) then
  begin
    Skip('musicflow runtime', 'no space track started');
    Exit;
  end;
  Before := MusicManager.Current.GetFileName;
  Check(not XenoRaiseMusicPlayCategory('Nation.Human'), 'musicflow: landing defers the planet music', Before);
  Check(MusicManager.Current.GetFileName = Before, 'musicflow: the space track keeps playing');
  Check(not XenoRaiseMusicPlayCategory('StarMap'), 'musicflow: returning to space cancels the pending switch');
  Check(XenoRaiseMusicPlaceFade, 'musicflow: takeoff/loading fade keeps a place track');
  Check(XenoRaiseMusicPlayCategory('Battle'), 'musicflow: battle music switches at once');
  MusicManager.StopImmediately;
end;

procedure RunSelfTest;
var
  Path: WideString;
begin
  Report := TStringList.Create;
  Failures := 0;
  Passes := 0;
  Skips := 0;
  Line('XenoModsFPC self-test; active mods: ' + SelectedMods);
  try
    Stage := 'inflation math';
    TestInflationMath;
    Stage := 'generator logic';
    TestGeneratorLogic;
    Stage := 'music logic';
    TestMusicLogic;
    Stage := 'camouflage logic';
    TestCamouflageLogic;
    Stage := 'host';
    TestHost;
    Stage := 'new game';
    GenerateGame;
    Stage := 'galaxy';
    TestGalaxy;
    Stage := 'turns';
    RunTurns(TurnCount);
    Stage := 'script libraries';
    TestScriptLibraries;
    Stage := 'inflation save/load';
    TestInflation;
    Stage := 'hangar paging';
    TestHangarPaging;
    Stage := 'music runtime';
    TestMusicFlowRuntime;
  except
    on E: Exception do
    begin
      Inc(Failures);
      Line('FAIL exception in ' + Stage + ': ' + E.ClassName + ': ' + E.Message, gllError);
      LogCurrentGameException('xeno-test', 'Self-test stage ' + Stage, gllError);
    end;
  end;
  Line(Format('RESULT passed=%d failed=%d skipped=%d', [Passes, Failures, Skips]));
  Path := GetGameUserDirectory + 'xeno_selftest.txt';
  try
    Report.SaveToFile(UTF8Encode(Path));
  except
  end;
  Report.Free;
  if Failures > 0 then
    Halt(1)
  else
    Halt(0);
end;

procedure OnFrame(User, Payload: Pointer); cdecl;
begin
  if Started or (CurrentScreenId <> screenMainMenu) then
    Exit;
  Started := True;
  RunSelfTest;
end;

procedure DetectRequest;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if Copy(ParamStr(I), 1, 15) = '--xeno-selftest' then
    begin
      Requested := True;
      if Copy(ParamStr(I), 16, 1) = '=' then
        TurnCount := StrToIntDef(Copy(ParamStr(I), 17, MaxInt), TurnCount);
    end;
end;

initialization
  DetectRequest;
  if Requested then
    XenoSubscribe('Frame', @OnFrame, nil);
{$ENDIF}
end.
