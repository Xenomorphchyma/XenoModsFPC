unit XenoEquipmentInflation;

{$I GameOptions.inc}

// Port of XenoEquipmentInflation.XenoPlugin.dll 3.1.0 (EIDM). The mod's
// RScript remains the economy controller: it computes the global index and
// calls Pulse once per turn. The Delphi plugin detoured TObject.NewInstance /
// FreeInstance, TItem.LoadFromBuffer / LoadFromBlock and the Cost store in
// TItem.SaveToBuffer; aItem.pas calls the matching procedures below instead.
// Saves keep the clean base price, so loading never inflates twice and the
// mod can be removed from a save without a cleanup pass.
interface

{$IFDEF XENO_MODS}
uses
  aItem;

procedure RegisterXenoEquipmentInflation;
procedure XenoInflationItemCreated(Item: TItem);
procedure XenoInflationItemDestroyed(Item: TItem);
procedure XenoInflationItemInitialized(Item: TItem);
function XenoInflationSerializedCost(Item: TItem): Integer;
// For XenoSelfTest.
function EffectiveFactor(Global, Elasticity: Integer): Integer;
function ApplyFactors(BaseCost, Global, Market: Integer): Integer;
function RecoverBase(ActualCost, Global, Market: Integer): Integer;
function XenoInflationTrackedCount: Integer;
function XenoInflationGlobalFactor: Integer;
{$ENDIF}

implementation

{$IFDEF XENO_MODS}
uses
  SysUtils,
  Math,
  EC_Expression,
  NativeScriptLibrary,
  GameObjectRegistry,
  XenoPluginHost,
  XenoModsHost;

const
  ModName = 'XenoEquipmentInflation';
  DeletedEntry = Pointer(1);

type
  TItemRecord = record
    Item: TItem;
    BaseCost, GlobalFactor, MarketFactor: Integer;
    Processed, Pending: Boolean;
  end;
  PItemRecord = ^TItemRecord;

  TTypeConfiguration = record
    Artefact, Hull, Weapon1, CustomWeapon, ExtendedArtefactFirst, ExtendedArtefactLast: Integer;
    ArtefactElasticity, HullElasticity, SystemElasticity, WeaponElasticity: Integer;
    Valid: Boolean;
  end;

var
  Lock: TRTLCriticalSection;
  // Open-addressing table keyed by item address; Count/Used as in GameObjectRegistry.
  Records: array of TItemRecord;
  LiveCount, UsedCount: SizeInt;
  PendingCount: SizeInt;
  Types: TTypeConfiguration;
  GlobalFactor: Integer = 0;
  ActiveGeneration: Cardinal = 0;
  Active: Boolean = False;
  // Set once the first item is tracked; lets vanilla games skip the lock.
  EverTracked: Boolean = False;

function ClampPrice(Value: Int64): Integer;
begin
  Result := Integer(Max(Int64(1), Min(Value, Int64(High(Integer)))));
end;

function EffectiveFactor(Global, Elasticity: Integer): Integer;
var
  Growth: Int64;
begin
  Global := Max(100, Global);
  Elasticity := Max(0, Elasticity);
  Growth := Int64(Global - 100) * Elasticity;
  Result := ClampPrice(100 + (Growth + 50) div 100);
end;

function ApplyFactors(BaseCost, Global, Market: Integer): Integer;
const
  MaximumRoundedProduct = Int64(High(Integer)) * 10000 + 4999;
var
  Base, G, M, WithGlobal: Int64;
begin
  Base := Max(1, BaseCost);
  G := Max(1, Global);
  M := Max(1, Market);
  // Cap before each multiplication: Pulse accepts any positive factor.
  if Base > MaximumRoundedProduct div G then
    Exit(High(Integer));
  WithGlobal := Base * G;
  if WithGlobal > MaximumRoundedProduct div M then
    Exit(High(Integer));
  Result := ClampPrice((WithGlobal * M + 5000) div 10000);
end;

function RecoverBase(ActualCost, Global, Market: Integer): Integer;
var
  Denominator, Numerator: Int64;
begin
  Denominator := Int64(Max(1, Global)) * Max(1, Market);
  Numerator := Int64(Max(1, ActualCost)) * 10000;
  Result := ClampPrice((Numerator + Denominator div 2) div Denominator);
end;

function IsActive: Boolean;
var
  Generation: Cardinal;
begin
  Generation := XenoModsGeneration;
  if Generation <> ActiveGeneration then
  begin
    ActiveGeneration := Generation;
    Active := XenoModActive(ModName);
  end;
  Result := Active;
end;

{ Item table }

function FirstSlot(Item: Pointer): SizeInt;
begin
  Result := SizeInt(((PtrUInt(Item) shr 4) xor (PtrUInt(Item) shr 17)) and PtrUInt(Length(Records) - 1));
end;

function FindRecord(Item: TItem): PItemRecord;
var
  I: SizeInt;
begin
  Result := nil;
  if Length(Records) = 0 then
    Exit;
  I := FirstSlot(Item);
  while Records[I].Item <> nil do
  begin
    if Records[I].Item = Item then
      Exit(@Records[I]);
    I := (I + 1) and (Length(Records) - 1);
  end;
end;

procedure Rehash(NewSize: SizeInt);
var
  Old: array of TItemRecord;
  I, J: SizeInt;
begin
  Old := Records;
  Records := nil;
  SetLength(Records, NewSize);
  UsedCount := 0;
  for I := 0 to High(Old) do
    if (Old[I].Item <> nil) and (Pointer(Old[I].Item) <> DeletedEntry) then
    begin
      J := FirstSlot(Old[I].Item);
      while Records[J].Item <> nil do
        J := (J + 1) and (Length(Records) - 1);
      Records[J] := Old[I];
      Inc(UsedCount);
    end;
end;

function AddRecord(Item: TItem; out Inserted: Boolean): PItemRecord;
var
  I, Deleted: SizeInt;
begin
  Result := FindRecord(Item);
  Inserted := Result = nil;
  if not Inserted then
    Exit;
  if (Length(Records) = 0) or ((UsedCount + 1) * 4 >= Length(Records) * 3) then
    if Length(Records) = 0 then
      Rehash(4096)
    else if LiveCount * 2 >= Length(Records) then
      Rehash(Length(Records) * 2)
    else
      Rehash(Length(Records));
  I := FirstSlot(Item);
  Deleted := -1;
  while Records[I].Item <> nil do
  begin
    if (Pointer(Records[I].Item) = DeletedEntry) and (Deleted < 0) then
      Deleted := I;
    I := (I + 1) and (Length(Records) - 1);
  end;
  if Deleted >= 0 then
    I := Deleted
  else
    Inc(UsedCount);
  EverTracked := True;
  Records[I].Item := Item;
  Records[I].BaseCost := 1;
  Records[I].GlobalFactor := 100;
  Records[I].MarketFactor := 100;
  Records[I].Processed := False;
  Records[I].Pending := True;
  Inc(PendingCount);
  Inc(LiveCount);
  Result := @Records[I];
end;

procedure RemoveRecord(Item: TItem);
var
  Rec: PItemRecord;
begin
  Rec := FindRecord(Item);
  if Rec = nil then
    Exit;
  if Rec^.Pending then
    Dec(PendingCount);
  FillChar(Rec^, SizeOf(Rec^), 0);
  Rec^.Item := TItem(DeletedEntry);
  Dec(LiveCount);
end;

{ Pricing }

function ElasticityForType(ItemType: Integer): Integer;
var
  Extended: Boolean;
begin
  if not Types.Valid then
    Exit(-1);
  Extended := (ItemType >= Types.ExtendedArtefactFirst) and (ItemType <= Types.ExtendedArtefactLast);
  if ((ItemType >= Types.Artefact) and (ItemType < Types.Hull)) or Extended then
    Result := Types.ArtefactElasticity
  else if ItemType = Types.Hull then
    Result := Types.HullElasticity
  else if (ItemType > Types.Hull) and (ItemType < Types.Weapon1) then
    Result := Types.SystemElasticity
  else if (ItemType >= Types.Weapon1) and (ItemType <= Types.CustomWeapon) then
    Result := Types.WeaponElasticity
  else
    Result := -1;
end;

// Re-derives the base price when something else changed Cost (repairs,
// script SetCost) and applies the current global factor.
function ApplyRecord(var Rec: TItemRecord; var Updated: Integer): Boolean;
var
  Item: TItem;
  Elasticity, DesiredGlobal, DesiredCost: Integer;
begin
  Item := Rec.Item;
  if (Item.Id = 0) or (Item.Cost <= 0) then
    Exit(False);
  Result := True;
  Elasticity := ElasticityForType(Ord(Item.ItemType));
  if Elasticity < 0 then
    Exit;
  DesiredGlobal := EffectiveFactor(Max(100, GlobalFactor), Elasticity);
  if not Rec.Processed then
  begin
    Rec.BaseCost := Max(1, Item.Cost);
    Rec.GlobalFactor := 100;
    Rec.MarketFactor := 100;
    Rec.Processed := True;
  end
  else if Item.Cost <> ApplyFactors(Rec.BaseCost, Rec.GlobalFactor, Rec.MarketFactor) then
    Rec.BaseCost := RecoverBase(Item.Cost, Rec.GlobalFactor, Rec.MarketFactor);
  DesiredCost := ApplyFactors(Rec.BaseCost, DesiredGlobal, Rec.MarketFactor);
  Rec.GlobalFactor := DesiredGlobal;
  if Item.Cost <> DesiredCost then
  begin
    Item.Cost := Max(1, DesiredCost);
    Inc(Updated);
  end;
end;

procedure ClearPending(var Rec: TItemRecord);
begin
  if Rec.Pending then
  begin
    Rec.Pending := False;
    Dec(PendingCount);
  end;
end;

{ Lifecycle hooks called from aItem.pas }

procedure XenoInflationItemCreated(Item: TItem);
var
  Inserted: Boolean;
begin
  if (Item = nil) or not IsActive then
    Exit;
  EnterCriticalSection(Lock);
  try
    AddRecord(Item, Inserted);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure XenoInflationItemDestroyed(Item: TItem);
begin
  if (Item = nil) or not EverTracked then
    Exit;
  EnterCriticalSection(Lock);
  try
    RemoveRecord(Item);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure XenoInflationItemInitialized(Item: TItem);
var
  Rec: PItemRecord;
  Inserted: Boolean;
  Updated: Integer;
begin
  if (Item = nil) or not IsActive then
    Exit;
  EnterCriticalSection(Lock);
  try
    Rec := AddRecord(Item, Inserted);
    if Types.Valid and (GlobalFactor >= 100) then
    begin
      Updated := 0;
      ApplyRecord(Rec^, Updated);
    end;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function XenoInflationSerializedCost(Item: TItem): Integer;
var
  Rec: PItemRecord;
begin
  Result := Item.Cost;
  if not EverTracked then
    Exit;
  EnterCriticalSection(Lock);
  try
    Rec := FindRecord(Item);
    if (Rec = nil) or not Rec^.Processed then
      Exit(Item.Cost);
    if Item.Cost <> ApplyFactors(Rec^.BaseCost, Rec^.GlobalFactor, Rec^.MarketFactor) then
      Rec^.BaseCost := RecoverBase(Item.Cost, Rec^.GlobalFactor, Rec^.MarketFactor);
    Result := Max(1, Rec^.BaseCost);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function XenoInflationTrackedCount: Integer;
begin
  Result := LiveCount;
end;

function XenoInflationGlobalFactor: Integer;
begin
  if Types.Valid then
    Result := GlobalFactor
  else
    Result := -1;
end;

{ Script library }

procedure SF_IsReady(av: array of TVarEC; Code: TCodeEC);
begin
  av[0].SetInt(Ord(IsActive));
end;

procedure SF_Configure(av: array of TVarEC; Code: TCodeEC);
var
  T: TTypeConfiguration;
  Changed: Boolean;
begin
  av[0].SetInt(0);
  T.Artefact := av[1].GetInt;
  T.Hull := av[2].GetInt;
  T.Weapon1 := av[3].GetInt;
  T.CustomWeapon := av[4].GetInt;
  T.ExtendedArtefactFirst := av[5].GetInt;
  T.ExtendedArtefactLast := av[6].GetInt;
  T.ArtefactElasticity := av[7].GetInt;
  T.HullElasticity := av[8].GetInt;
  T.SystemElasticity := av[9].GetInt;
  T.WeaponElasticity := av[10].GetInt;
  T.Valid := True;
  if not IsActive or (T.Artefact < 0) or (T.Hull <= T.Artefact) or (T.Weapon1 <= T.Hull) or (T.CustomWeapon < T.Weapon1)
      or (T.ExtendedArtefactFirst < 0) or (T.ExtendedArtefactLast < T.ExtendedArtefactFirst)
      or not InRange(T.ArtefactElasticity, 0, 500) or not InRange(T.HullElasticity, 0, 500)
      or not InRange(T.SystemElasticity, 0, 500) or not InRange(T.WeaponElasticity, 0, 500) then
    Exit;
  EnterCriticalSection(Lock);
  try
    Changed := not Types.Valid or (Types.Artefact <> T.Artefact) or (Types.Hull <> T.Hull) or (Types.Weapon1 <> T.Weapon1)
        or (Types.CustomWeapon <> T.CustomWeapon) or (Types.ExtendedArtefactFirst <> T.ExtendedArtefactFirst)
        or (Types.ExtendedArtefactLast <> T.ExtendedArtefactLast) or (Types.ArtefactElasticity <> T.ArtefactElasticity)
        or (Types.HullElasticity <> T.HullElasticity) or (Types.SystemElasticity <> T.SystemElasticity)
        or (Types.WeaponElasticity <> T.WeaponElasticity);
    Types := T;
    if Changed then
      GlobalFactor := 0;
  finally
    LeaveCriticalSection(Lock);
  end;
  if Changed then
    XenoLog(ModName, 'script_bridge=configured');
  av[0].SetInt(1);
end;

procedure SF_Pulse(av: array of TVarEC; Code: TCodeEC);
var
  Factor, Updated: Integer;
  FactorChanged: Boolean;
  I: SizeInt;
  Tracked: SizeInt;
begin
  Factor := av[1].GetInt;
  if not IsActive or not Types.Valid or (Factor < 100) then
  begin
    av[0].SetInt(0);
    Exit;
  end;
  Updated := 0;
  EnterCriticalSection(Lock);
  try
    FactorChanged := GlobalFactor <> Factor;
    GlobalFactor := Factor;
    // A changed index walks every tracked item; otherwise only new ones.
    if FactorChanged or (PendingCount > 0) then
      for I := 0 to High(Records) do
        if (Records[I].Item <> nil) and (Pointer(Records[I].Item) <> DeletedEntry)
            and (FactorChanged or Records[I].Pending) then
          if ApplyRecord(Records[I], Updated) or FactorChanged then
            ClearPending(Records[I]);
    Tracked := LiveCount;
  finally
    LeaveCriticalSection(Lock);
  end;
  if FactorChanged then
    XenoLog(ModName, 'factor=' + IntToStr(Factor) + ' tracked=' + IntToStr(Tracked) + ' updated=' + IntToStr(Updated));
  av[0].SetInt(Updated + 1);
end;

procedure SF_SetMarket(av: array of TVarEC; Code: TCodeEC);
var
  Item: TItem;
  Market, Updated, Desired: Integer;
  Rec: PItemRecord;
  Inserted: Boolean;
begin
  av[0].SetInt(0);
  Market := av[2].GetInt;
  if not IsActive or not Types.Valid or (av[1].GetDword = 0) or (Market < 70) or (Market > 130) then
    Exit;
  if not IsLiveGameObject(Pointer(av[1].GetDword)) or not (TObject(av[1].GetDword) is TItem) then
    Exit;
  Item := TItem(av[1].GetDword);
  EnterCriticalSection(Lock);
  try
    Rec := AddRecord(Item, Inserted);
    Updated := 0;
    if not ApplyRecord(Rec^, Updated) or not Rec^.Processed then
      Exit;
    if Item.Cost <> ApplyFactors(Rec^.BaseCost, Rec^.GlobalFactor, Rec^.MarketFactor) then
      Rec^.BaseCost := RecoverBase(Item.Cost, Rec^.GlobalFactor, Rec^.MarketFactor);
    Rec^.MarketFactor := Market;
    Desired := ApplyFactors(Rec^.BaseCost, Rec^.GlobalFactor, Rec^.MarketFactor);
    if Item.Cost <> Desired then
      Item.Cost := Max(1, Desired);
    av[0].SetInt(1);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure RegisterXenoEquipmentInflation;
const
  LibraryName = 'XenoEquipmentInflation.XenoPlugin';
begin
  RegisterNativeScriptFunction(LibraryName, 'int,XenoEquipmentInflation_IsReady', @SF_IsReady);
  RegisterNativeScriptFunction(LibraryName, 'int,XenoEquipmentInflation_Configure,int,int,int,int,int,int,int,int,int,int', @SF_Configure);
  RegisterNativeScriptFunction(LibraryName, 'int,XenoEquipmentInflation_Pulse,int', @SF_Pulse);
  RegisterNativeScriptFunction(LibraryName, 'int,XenoEquipmentInflation_SetMarket,dword,int', @SF_SetMarket);
end;

procedure OnItemCreated(User, Payload: Pointer); cdecl;
begin
  XenoInflationItemCreated(TItem(TXenoFpcItemEvent(Payload^).Item));
end;

procedure OnItemDestroyed(User, Payload: Pointer); cdecl;
begin
  XenoInflationItemDestroyed(TItem(TXenoFpcItemEvent(Payload^).Item));
end;

procedure OnItemLoaded(User, Payload: Pointer); cdecl;
begin
  XenoInflationItemInitialized(TItem(TXenoFpcItemEvent(Payload^).Item));
end;

procedure OnItemSaveCost(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcItemSaveCostEvent(Payload^) do
    Cost := XenoInflationSerializedCost(TItem(Item));
end;

initialization
  InitCriticalSection(Lock);
  RegisterXenoEquipmentInflation;
  XenoSubscribe('Item.Created', @OnItemCreated, nil);
  XenoSubscribe('Item.Destroyed', @OnItemDestroyed, nil);
  XenoSubscribe('Item.Loaded', @OnItemLoaded, nil);
  XenoSubscribe('Item.SaveCost', @OnItemSaveCost, nil);

finalization
  DoneCriticalSection(Lock);
{$ENDIF}
end.
