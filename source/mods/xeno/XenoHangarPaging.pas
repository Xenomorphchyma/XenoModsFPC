unit XenoHangarPaging;

{$I GameOptions.inc}

// Port of XenoHangarPaging.Runtime.dll 1.2.0. With more than eight foreign
// ships on the landing area, the hangar shows them in stable pages of eight
// (ordered by ship Id); the player's ship stays in slot 0. The paging strip
// itself (HangarPagingPanel, HangarPagePrev/Next, HangarPageNumber1..16) is
// declared by the mod's CFG\Main.dat and works unchanged.
//
// The Delphi runtime ran after the stock TfHangar.RefreshDockedShips and then
// corrected slot records it had filled randomly; it caught clicks with a
// window-procedure hook at fixed coordinates. Here the hangar calls
// XenoHangarPagingRefresh before its random fill and skips that fill when
// paging owns the foreign slots; the arrows get ordinary button callbacks.
interface

{$IFDEF XENO_MODS}
uses
  fHangar;

procedure XenoHangarPagingOpen(Hangar: TfHangar);
procedure XenoHangarPagingClose(Hangar: TfHangar);
// True when paging filled slots 1..8; the caller then skips its random fill.
function XenoHangarPagingRefresh(Hangar: TfHangar): Boolean;
// Left/Right arrows. True when the key changed the page.
function XenoHangarPagingKey(Hangar: TfHangar; Key: Cardinal): Boolean;
{$ENDIF}

implementation

{$IFDEF XENO_MODS}
uses
  SysUtils,
  Classes,
  GameSystem,
  GameInput,
  GI_MessageLoop,
  GI_GraphButton,
  aGalaxy,
  aShip,
  aPlayer,
  XenoPluginHost,
  XenoModsHost;

const
  ModName = 'XenoHangarPaging';
  SlotsPerPage = 8;
  PageNumberLabelCount = 16;
  InputDebounceMs = 300;

type
  TPagingHandler = class
    procedure PrevClicked(Sender: TObjectGI);
    procedure NextClicked(Sender: TObjectGI);
  end;

var
  Handler: TPagingHandler = nil;
  CurrentHangar: TfHangar = nil;
  Enabled: Boolean = False;
  Page: Integer = 0;
  PageCount: Integer = 1;
  LastUiPage: Integer = -2;
  LastUiPageCount: Integer = -2;
  LastCandidateCount: Integer = -2;
  LastLoggedPage: Integer = -2;
  LastInputTick: Cardinal = 0;
  LoggedOpen: Boolean = False;

function Control(Hangar: TfHangar; const Name: WideString): TObjectGI;
begin
  // FindControlByPath does not raise for a missing control (GetByName does).
  Result := Hangar.FindControlByPath(Name);
end;

procedure UpdatePagingUi(Hangar: TfHangar);
var
  I, Visible: Integer;
  Panel, NumberLabel: TObjectGI;
begin
  Panel := Control(Hangar, 'HangarPagingPanel');
  if Panel = nil then
    Exit;
  // The strip stays visible on single-page and empty landing areas too.
  Panel.SetActive(True);
  if (LastUiPage = Page) and (LastUiPageCount = PageCount) then
    Exit;
  LastUiPage := Page;
  LastUiPageCount := PageCount;
  Visible := Page;
  if Visible < 0 then
    Visible := 0
  else if Visible >= PageNumberLabelCount then
    Visible := PageNumberLabelCount - 1;
  for I := 0 to PageNumberLabelCount - 1 do
  begin
    NumberLabel := Control(Hangar, 'HangarPageNumber' + IntToStr(I + 1));
    if NumberLabel <> nil then
      NumberLabel.SetActive(I = Visible);
  end;
end;

function AlreadyListed(const Candidates: array of TShip; Count: Integer; Ship: TShip): Boolean;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if Candidates[I].Id = Ship.Id then
      Exit(True);
  Result := False;
end;

// Foreign ships on the player's landing place in stable Id order.
procedure GatherCandidates(out Candidates: TList);
var
  Player: TPlayer;
  Ship: TShip;
  J: Integer;
  Items: array of TShip;
  Count, I, K: Integer;

  procedure Add(Value: TShip);
  begin
    if (Value = nil) or (Value = TShip(Player)) or (Value.Id = 0) or AlreadyListed(Items, Count, Value) then
      Exit;
    if Value.GetShipPortraitImagePath = WideString('') then
      Exit;
    if Count = Length(Items) then
      SetLength(Items, Count * 2 + 16);
    Items[Count] := Value;
    Inc(Count);
  end;

begin
  Candidates := TList.Create;
  Player := GetPlayer;
  Count := 0;
  if (Player = nil) or (Player.CurrentStar = nil) then
    Exit;
  if Player.IsOnPlanet then
  begin
    for J := 0 to Player.CurrentStar.Ships.Count - 1 do
    begin
      Ship := Player.CurrentStar.Ships[J];
      if Ship.CurrentPlanet = Player.CurrentPlanet then
        Add(Ship);
    end;
    if Player.CurrentPlanet <> nil then
      for J := 0 to Player.CurrentPlanet.Warriors.Count - 1 do
      begin
        Ship := Player.CurrentPlanet.Warriors[J];
        if Ship.CurrentPlanet = Player.CurrentPlanet then
          Add(Ship);
      end;
  end
  else if Player.IsDockedToShip then
    for J := 0 to Player.CurrentStar.Ships.Count - 1 do
    begin
      Ship := Player.CurrentStar.Ships[J];
      if Ship.DockedTo = Player.DockedTo then
        Add(Ship);
    end;
  // Insertion sort by Id keeps pages stable while ships land and leave.
  for I := 1 to Count - 1 do
  begin
    Ship := Items[I];
    K := I;
    while (K > 0) and (Items[K - 1].Id > Ship.Id) do
    begin
      Items[K] := Items[K - 1];
      Dec(K);
    end;
    Items[K] := Ship;
  end;
  for I := 0 to Count - 1 do
    Candidates.Add(Items[I]);
end;

procedure HideSlot(Hangar: TfHangar; Slot: Integer);
begin
  Hangar.ShipSlots[Slot].AnimationState := 0;
  Hangar.ShipSlots[Slot].ShipId := 0;
  Hangar.ShipSlots[Slot].Opacity := 0;
  if Hangar.ShipSlots[Slot].ImageControl <> nil then
    Hangar.ShipSlots[Slot].ImageControl.SetActive(False);
end;

procedure ShowSlot(Hangar: TfHangar; Slot: Integer; Ship: TShip);
var
  Path: WideString;
begin
  Path := Ship.GetShipPortraitImagePath;
  if Path = WideString('') then
  begin
    HideSlot(Hangar, Slot);
    Exit;
  end;
  Hangar.ShipSlots[Slot].ShipId := Ship.Id;
  Hangar.ShipSlots[Slot].AnimationState := 1;
  Hangar.ShipSlots[Slot].Opacity := 0;
  Hangar.LoadDockedShipImage(Slot, Path, False, Hangar.GetShipPortraitScale(Ship));
  Hangar.SetDockedShipOpacity(Slot, 0);
end;

function XenoHangarPagingRefresh(Hangar: TfHangar): Boolean;
var
  Candidates: TList;
  Count, First, Slot, Index: Integer;
  Ship: TShip;
  SelectionChanged: Boolean;
begin
  Result := False;
  if (Hangar = nil) or (Hangar <> CurrentHangar) or not Enabled then
    Exit;
  GatherCandidates(Candidates);
  try
    Count := Candidates.Count;
    if Count <= SlotsPerPage then
    begin
      // The stock hangar shows everyone; keep its layout untouched.
      Page := 0;
      PageCount := 1;
      UpdatePagingUi(Hangar);
      if LastCandidateCount > SlotsPerPage then
        // Leaving paging: release foreign slots so the stock fill reflows them.
        for Slot := 1 to SlotsPerPage do
          if Hangar.ShipSlots[Slot].AnimationState in [1, 2] then
          begin
            Ship := TShip(Galaxy.IdToShip(Hangar.ShipSlots[Slot].ShipId, False));
            if (Ship = nil) or (Candidates.IndexOf(Ship) < 0) then
              HideSlot(Hangar, Slot);
          end;
      LastCandidateCount := Count;
      LastLoggedPage := 0;
      Exit;
    end;
    PageCount := (Count + SlotsPerPage - 1) div SlotsPerPage;
    if Page < 0 then
      Page := PageCount - 1;
    if Page >= PageCount then
      Page := 0;
    UpdatePagingUi(Hangar);
    SelectionChanged := (LastCandidateCount <> Count) or (LastLoggedPage <> Page);
    if SelectionChanged then
    begin
      XenoLog(ModName, 'page applied; candidates=' + IntToStr(Count) + '; page=' + IntToStr(Page + 1) + '/' + IntToStr(PageCount));
      LastCandidateCount := Count;
      LastLoggedPage := Page;
      Hangar.HoveredShip := nil;
      if Hangar.ShipInfoWindow <> nil then
        Hangar.ShipInfoWindow.SetActive(False);
    end;
    First := Page * SlotsPerPage;
    for Slot := 1 to SlotsPerPage do
    begin
      Index := First + Slot - 1;
      if Index >= Count then
      begin
        if (Hangar.ShipSlots[Slot].AnimationState <> 0) or (Hangar.ShipSlots[Slot].ShipId <> 0) then
          HideSlot(Hangar, Slot);
        Continue;
      end;
      Ship := TShip(Candidates[Index]);
      // A slot that already shows (or fades in) the right ship is left alone,
      // so settled ships never blink on the per-frame refresh.
      if (Hangar.ShipSlots[Slot].ShipId = Ship.Id) and (Hangar.ShipSlots[Slot].AnimationState in [1, 2]) then
        Continue;
      ShowSlot(Hangar, Slot, Ship);
    end;
    Result := True;
  finally
    Candidates.Free;
  end;
end;

procedure ChangePage(Delta: Integer);
begin
  if (CurrentHangar = nil) or not Enabled or (PageCount <= 1) then
    Exit;
  Page := (Page + Delta) mod PageCount;
  if Page < 0 then
    Inc(Page, PageCount);
  XenoHangarPagingRefresh(CurrentHangar);
end;

function AcceptPageInput: Boolean;
var
  Now: Cardinal;
begin
  Now := GameTickCount;
  Result := (LastInputTick = 0) or (Cardinal(Now - LastInputTick) >= InputDebounceMs);
  if Result then
    LastInputTick := Now;
end;

procedure TPagingHandler.PrevClicked(Sender: TObjectGI);
begin
  ChangePage(-1);
end;

procedure TPagingHandler.NextClicked(Sender: TObjectGI);
begin
  ChangePage(1);
end;

function XenoHangarPagingKey(Hangar: TfHangar; Key: Cardinal): Boolean;
begin
  Result := False;
  if (Hangar <> CurrentHangar) or not Enabled or (PageCount <= 1) then
    Exit;
  if (Key = VK_LEFT) or (Key = VK_RIGHT) then
  begin
    Result := True;
    if not AcceptPageInput then
      Exit;
    if Key = VK_LEFT then
      ChangePage(-1)
    else
      ChangePage(1);
  end;
end;

procedure XenoHangarPagingOpen(Hangar: TfHangar);
var
  Button: TObjectGI;
begin
  CurrentHangar := Hangar;
  Enabled := XenoModActive(ModName) and (Control(Hangar, 'HangarPagingPanel') <> nil);
  Page := 0;
  PageCount := 1;
  LastUiPage := -2;
  LastUiPageCount := -2;
  LastCandidateCount := -2;
  LastLoggedPage := -2;
  if not Enabled then
    Exit;
  if Handler = nil then
    Handler := TPagingHandler.Create;
  Button := Control(Hangar, 'HangarPagePrev');
  if Button is TGraphButtonGI then
    TGraphButtonGI(Button).UpCallback := Handler.PrevClicked;
  Button := Control(Hangar, 'HangarPageNext');
  if Button is TGraphButtonGI then
    TGraphButtonGI(Button).UpCallback := Handler.NextClicked;
  if not LoggedOpen then
  begin
    LoggedOpen := True;
    XenoLog(ModName, 'hangar paging active (FPC port of runtime 1.2.0)');
  end;
end;

procedure XenoHangarPagingClose(Hangar: TfHangar);
begin
  if Hangar = CurrentHangar then
    CurrentHangar := nil;
end;

procedure OnHangarOpened(User, Payload: Pointer); cdecl;
begin
  XenoHangarPagingOpen(TfHangar(TXenoFpcHangarEvent(Payload^).Hangar));
end;

procedure OnHangarClosed(User, Payload: Pointer); cdecl;
begin
  XenoHangarPagingClose(TfHangar(TXenoFpcHangarEvent(Payload^).Hangar));
end;

procedure OnHangarRefresh(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcHangarRefreshEvent(Payload^) do
    if (Handled = 0) and XenoHangarPagingRefresh(TfHangar(Hangar)) then
      Handled := 1;
end;

procedure OnHangarKey(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcHangarKeyEvent(Payload^) do
    if (Handled = 0) and XenoHangarPagingKey(TfHangar(Hangar), Key) then
      Handled := 1;
end;

initialization
  XenoSubscribe('Hangar.Opened', @OnHangarOpened, nil);
  XenoSubscribe('Hangar.Closed', @OnHangarClosed, nil);
  XenoSubscribe('Hangar.Refresh', @OnHangarRefresh, nil);
  XenoSubscribe('Hangar.Key', @OnHangarKey, nil);

finalization
  FreeAndNil(Handler);
{$ENDIF}
end.
