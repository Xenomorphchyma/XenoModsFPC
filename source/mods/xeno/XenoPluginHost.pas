unit XenoPluginHost;

{$I GameOptions.inc}
{$LEGACYPC24 OFF}
{$EXCESSPRECISION OFF}
{$DELPHIORDER OFF}

// XenoModsFPC plugin host: the Free Pascal counterpart of XenoNativeLoader.
// It loads Mods\...\Native\*.XenoPlugin.dll (.so) of the selected mods and
// hands them the C API from xenomods/sdk/xeno_fpc_plugin_api.h. Plugins never
// patch code: the game raises the events declared there, and fields are found
// by name through the generated field map. The built-in Xeno mods subscribe
// to the very same events, so the API is exercised by real mods.
interface

{$IFDEF XENO_MODS}
uses
  XenoHookRuntime;

{$PACKRECORDS C}
type
  TXenoFpcEventFn = procedure(User: Pointer; Payload: Pointer); cdecl;
  // Method hooks: Call is XenoFpcCall of the SDK header.
  TXenoFpcHookFn = procedure(User: Pointer; Call: PXenoHkCall); cdecl;

  TXenoFpcFrameEvent = record
    Size: Cardinal;
    Tick: Cardinal;
  end;
  TXenoFpcGalaxyCreatedEvent = record
    Size: Cardinal;
    Galaxy: Pointer;
    SectorCount: Integer;
  end;
  TXenoFpcGalaxyPlanStarEvent = record
    Size: Cardinal;
    Galaxy: Pointer;
    StarIndex: Integer;
    Sector: Integer;
  end;
  TXenoFpcGalaxyLayoutEvent = record
    Size: Cardinal;
    Galaxy: Pointer;
    Attempts: Integer;
    Done: Integer;
  end;
  TXenoFpcContourEvent = record
    Size: Cardinal;
    RemoveVertex: Integer;
  end;
  TXenoFpcStationSpawningEvent = record
    Size: Cardinal;
    Galaxy: Pointer;
    Day: Integer;
    Run: Integer;
  end;
  TXenoFpcItemEvent = record
    Size: Cardinal;
    Item: Pointer;
  end;
  TXenoFpcItemSaveCostEvent = record
    Size: Cardinal;
    Item: Pointer;
    Cost: Integer;
  end;
  TXenoFpcCamouflageEvent = record
    Size: Cardinal;
    Kling: Pointer;
    Target: Pointer;
    Handled: Integer;
    Effective: Integer;
  end;
  TXenoFpcHangarEvent = record
    Size: Cardinal;
    Hangar: Pointer;
  end;
  TXenoFpcHangarRefreshEvent = record
    Size: Cardinal;
    Hangar: Pointer;
    Handled: Integer;
  end;
  TXenoFpcHangarKeyEvent = record
    Size: Cardinal;
    Hangar: Pointer;
    Key: Cardinal;
    Handled: Integer;
  end;
  TXenoFpcMusicCategoryEvent = record
    Size: Cardinal;
    Category: PAnsiChar;
    Skip: Integer;
  end;
  TXenoFpcMusicStopEvent = record
    Size: Cardinal;
  end;
  TXenoFpcMusicPlaceFadeEvent = record
    Size: Cardinal;
    Keep: Integer;
  end;
  TXenoFpcVolumeRampEvent = record
    Size: Cardinal;
    Buffer: Pointer;
    IntervalMs: Cardinal;
    Step: Single;
  end;
{$PACKRECORDS DEFAULT}

  TXenoEvent = (xeFrame, xeGalaxyCreated, xeGalaxyPlanStar, xeGalaxyLayoutDone, xeGalaxyContourNoEar, xeGalaxyStationSpawning,
      xeItemCreated, xeItemDestroyed, xeItemLoaded, xeItemSaveCost, xeKlingCamouflage, xeHangarOpened, xeHangarClosed,
      xeHangarRefresh, xeHangarKey, xeMusicPlayCategory, xeMusicStopImmediately, xeMusicPlaceFade, xeSoundVolumeRamp);

// Built-in mods subscribe with the same callbacks external plugins use.
function XenoSubscribe(const EventName: AnsiString; Callback: TXenoFpcEventFn; User: Pointer): Boolean;
function XenoHasSubscribers(Event: TXenoEvent): Boolean; inline;
procedure XenoRaise(Event: TXenoEvent; var Payload);
// Loads/unloads plugins for the current mod selection (after mod configs load).
procedure XenoSyncPlugins;
procedure XenoShutdownPlugins;
// Field map for plugins and tests; -1 when unknown.
function XenoFieldOffset(const TypeName, FieldName: AnsiString; out ByteSize: Integer; out TypeText: AnsiString): PtrInt;
// Remaining audible ms of the current music track (sampled every frame).
function XenoMusicRemainingMs: Integer;
// Runs the stock PlayCategory without raising Music.PlayCategory.
procedure XenoMusicPlayCategoryOriginal(const Category: WideString);
function XenoLoadedPluginCount: Integer;

// Method hooks (see XenoPluginHooks.inc). Phase 0 = before, 1 = after;
// Flags 1 = also every override in derived classes. 0 = not installed.
function XenoHookAdd(const Name: AnsiString; Phase, Flags, Priority: Integer; Callback: TXenoFpcHookFn;
    User: Pointer): PtrInt;
procedure XenoHookRemove(Handle: PtrInt);
// PXenoFpcHookInfo of a routine, nil when unknown or ambiguous.
function XenoHookInfo(const Name: AnsiString): Pointer;
function XenoHookInfoAt(Index: Integer): Pointer;
function XenoHookAddInfo(Info: Pointer; Phase, Flags, Priority: Integer; Callback: TXenoFpcHookFn; User: Pointer): PtrInt;
function XenoHookInvoke(Info: Pointer; Self_: Pointer; Args: PPointer; Result_: Pointer): Boolean;
// Self-test only: hooks added until the next call belong to a fake plugin
// with this id ('' = built-in again).
procedure XenoHookTestOwner(const Id: AnsiString);

// Convenience raisers used by the game code.
procedure XenoRaiseFrame;
function XenoRaiseGalaxyCreated(Galaxy: Pointer; SectorCount: Integer): Integer;
function XenoRaiseGalaxyPlanStar(Galaxy: Pointer; StarIndex: Integer): Integer;
function XenoRaiseGalaxyLayoutDone(Galaxy: Pointer; Attempts: Integer): Boolean;
function XenoRaiseContourNoEar: Boolean;
function XenoRaiseStationSpawning(Galaxy: Pointer; Day: Integer): Boolean;
procedure XenoRaiseItem(Event: TXenoEvent; Item: Pointer);
function XenoRaiseItemSaveCost(Item: Pointer; Cost: Integer): Integer;
function XenoRaiseCamouflage(Kling, Target: Pointer; out Effective: Boolean): Boolean;
procedure XenoRaiseHangar(Event: TXenoEvent; Hangar: Pointer);
function XenoRaiseHangarRefresh(Hangar: Pointer): Boolean;
function XenoRaiseHangarKey(Hangar: Pointer; Key: Cardinal): Boolean;
function XenoRaiseMusicPlayCategory(const Category: WideString): Boolean;
procedure XenoRaiseMusicStopImmediately;
function XenoRaiseMusicPlaceFade: Boolean;
function XenoRaiseVolumeRamp(Buffer: Pointer; IntervalMs: Cardinal; Step: Single): Single;
{$ENDIF}

implementation

{$IFDEF XENO_MODS}
uses
  XenoFieldMapData,
  // Generated with the field map: every unit whose types plugins can address.
{$I XenoFieldMapUnits.inc}

const
  EventNames: array[TXenoEvent] of AnsiString = ('Frame', 'Galaxy.Created', 'Galaxy.PlanStar', 'Galaxy.LayoutDone',
      'Galaxy.ContourNoEar', 'Galaxy.StationSpawning', 'Item.Created', 'Item.Destroyed', 'Item.Loaded', 'Item.SaveCost',
      'Kling.Camouflage', 'Hangar.Opened', 'Hangar.Closed', 'Hangar.Refresh', 'Hangar.Key', 'Music.PlayCategory',
      'Music.StopImmediately', 'Music.PlaceFade', 'Sound.VolumeRamp');
  HostApiVersion = 2;
{$IFDEF MSWINDOWS}
  PluginSuffix = '.XenoPlugin.dll';
{$ELSE}
  PluginSuffix = '.XenoPlugin.so';
{$ENDIF}

{$PACKRECORDS C}
type
  PXenoFpcValue = ^TXenoFpcValue;
  TXenoFpcValue = record
    Kind: Integer;
    I: Integer;
    Dword: PtrUInt;
    F: Single;
    S: PAnsiChar;
  end;
  TXenoFpcScriptCall = record
    Size: Cardinal;
    ArgumentCount: Integer;
    Arguments: PXenoFpcValue;
    Result: TXenoFpcValue;
  end;
  PXenoFpcScriptCall = ^TXenoFpcScriptCall;
  TXenoFpcFieldInfo = record
    Size: Cardinal;
    Offset: PtrInt;
    ByteSize: Integer;
    TypeName: PAnsiChar;
  end;
  PXenoFpcFieldInfo = ^TXenoFpcFieldInfo;
  TXenoFpcScriptFn = procedure(User: Pointer; Call: PXenoFpcScriptCall); cdecl;
  TXenoFpcUiCallbackFn = procedure(User: Pointer; Control: Pointer); cdecl;

  TXenoFpcHostV1 = record
    Size: Cardinal;
    ApiVersion: Cardinal;
    GameVersion, GameRoot, ModFolder, PluginPath, ConfigPath, TargetCpu: PAnsiChar;
    Log: procedure(PluginId: PAnsiChar; Level: Integer; Text: PAnsiChar); cdecl;
    ConfigGetInt: function(Path, Section, Key: PAnsiChar; Default, Minimum, Maximum: Integer): Integer; cdecl;
    ConfigGetString: function(Path, Section, Key, Default: PAnsiChar; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
    GameConfigGet: function(Root: Integer; Path: PAnsiChar; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
    IsModActive: function(ModName: PAnsiChar): Integer; cdecl;
    Subscribe: function(EventName: PAnsiChar; Callback: TXenoFpcEventFn; User: Pointer): Integer; cdecl;
    RegisterScriptFunction: function(LibraryName, Signature: PAnsiChar; Callback: TXenoFpcScriptFn; User: Pointer): Integer; cdecl;
    FieldInfo: function(TypeName, FieldName: PAnsiChar; Info: PXenoFpcFieldInfo): Integer; cdecl;
    IsLiveObject: function(Obj: Pointer): Integer; cdecl;
    IsInstanceOf: function(Obj: Pointer; ClassName: PAnsiChar): Integer; cdecl;
    ObjectClassName: function(Obj: Pointer; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
    Galaxy: function: Pointer; cdecl;
    Player: function: Pointer; cdecl;
    ListCount: function(List: Pointer): Integer; cdecl;
    ListItem: function(List: Pointer; Index: Integer): Pointer; cdecl;
    ReadWideString: function(Obj: Pointer; Offset: PtrInt; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
    ObjectById: function(Kind: Integer; Id: Cardinal): Pointer; cdecl;
    UiFindControl: function(Screen: Pointer; Name: PAnsiChar): Pointer; cdecl;
    UiSetActive: procedure(Control: Pointer; Active: Integer); cdecl;
    UiSetButtonCallback: function(Control: Pointer; Callback: TXenoFpcUiCallbackFn; User: Pointer): Integer; cdecl;
    UiSetLabelText: function(Control: Pointer; Text: PAnsiChar): Integer; cdecl;
    TickCount: function: Cardinal; cdecl;
    HangarShowShip: procedure(Hangar: Pointer; Slot: Integer; Ship: Pointer); cdecl;
    MusicChooseFile: function(Category, CurrentFile: PAnsiChar; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
    MusicPlayCategory: procedure(Category: PAnsiChar); cdecl;
    MusicUnitRunning: function(UnitIndex: Integer): Integer; cdecl;
    MusicUnitFile: function(UnitIndex: Integer; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
    MusicUnitStop: procedure(UnitIndex: Integer; Immediate: Integer); cdecl;
    MusicUnitStart: procedure(UnitIndex: Integer); cdecl;
    MusicUnitBuffer: function(UnitIndex: Integer): Pointer; cdecl;
    MusicRemainingMs: function: Integer; cdecl;
    SoundSetVolumeStep: procedure(Buffer: Pointer; Step: Single); cdecl;
    MusicCategoryOverride: function(Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
    // API 2: method hooks.
    HookCount: function: Integer; cdecl;
    HookInfoAt: function(Index: Integer): Pointer; cdecl;
    HookFind: function(Name: PAnsiChar; Found: Pointer; MaxFound: Integer): Integer; cdecl;
    HookAdd: function(Info: Pointer; Phase, Flags, Priority: Integer; Callback: TXenoFpcHookFn; User: Pointer): PtrInt; cdecl;
    Hook: function(Name: PAnsiChar; Phase, Flags, Priority: Integer; Callback: TXenoFpcHookFn; User: Pointer): PtrInt; cdecl;
    HookRemove: procedure(Handle: PtrInt); cdecl;
    Invoke: function(Info: Pointer; Self_: Pointer; Args: PPointer; Result_: Pointer): Integer; cdecl;
    ValueGetString: function(Storage: Pointer; TypeName: PAnsiChar; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
    ValueSetString: function(Storage: Pointer; TypeName: PAnsiChar; Text: PAnsiChar): Integer; cdecl;
  end;
  PXenoFpcHostV1 = ^TXenoFpcHostV1;

  TXenoFpcPluginInfoV1 = record
    Size: Cardinal;
    RequiredHostApi: Cardinal;
    Id: array[0..63] of AnsiChar;
    Version: array[0..31] of AnsiChar;
    Description: array[0..159] of AnsiChar;
  end;
{$PACKRECORDS DEFAULT}

  TPluginQueryFn = function(Info: Pointer): Integer; cdecl;
  TPluginInitializeFn = function(Host: PXenoFpcHostV1): Integer; cdecl;
  TPluginShutdownFn = procedure; cdecl;

  TPlugin = class
    Path, ModFolder, ConfigPath: UTF8String;
    PluginId, Version: UTF8String;
    Handle: TLibHandle;
    Host: TXenoFpcHostV1;
    Shutdown: TPluginShutdownFn;
    Active: Boolean;
  end;

  TSubscriber = record
    Callback: TXenoFpcEventFn;
    User: Pointer;
    Owner: TPlugin; // nil for built-in mods
  end;

  TScriptBridge = class
    Owner: TPlugin;
    Callback: TXenoFpcScriptFn;
    User: Pointer;
    Kinds: array of TLibraryValueKind;
    Name: UTF8String;
  end;

  TUiThunk = class
    Callback: TXenoFpcUiCallbackFn;
    User: Pointer;
    Owner: TPlugin;
    procedure Fire(Sender: TObjectGI);
  end;

  TFieldEntry = record
    Offset: PtrInt;
    ByteSize: Integer;
    TypeText: AnsiString;
  end;

var
  Subscribers: array[TXenoEvent] of array of TSubscriber;
  Plugins: TList = nil;
  Bridges: TList = nil;
  Thunks: TList = nil;
  CurrentPlugin: TPlugin = nil; // set while a plugin initializes
  FieldNames: TStringList = nil;
  FieldEntries: array of TFieldEntry;
  ClassNames: TStringList = nil;
  GameRootText, GameVersionText, TargetCpuText: UTF8String;
  LastSyncSelection: WideString = #0;
  InternalMusicCall: Boolean = False;
  // Track progress estimate (see XenoMusicFlow's DLL for the method).
  ProgressStream, ProgressReadBuffer: Pointer;
  ProgressStartMs, ProgressNowMs: Cardinal;
  ProgressSwapped, ProgressConsumed: Int64;
  ProgressBufferFill, ProgressUnread, ProgressFileSize: Integer;
  ProgressEndOfFile: Boolean;

{ Helpers }

function CopyOut(const Value: UTF8String; Buffer: PAnsiChar; BufferSize: Integer): Integer;
var
  Count: Integer;
begin
  Result := Length(Value);
  if (Buffer = nil) or (BufferSize <= 0) then
    Exit;
  Count := Min(Result, BufferSize - 1);
  if Count > 0 then
    Move(PAnsiChar(Value)^, Buffer^, Count);
  Buffer[Count] := #0;
end;

function Utf8(const Value: WideString): UTF8String;
begin
  Result := UTF8Encode(Value);
end;

function FromUtf8(Text: PAnsiChar): WideString;
begin
  if Text = nil then
    Result := ''
  else
    Result := UTF8Decode(UTF8String(Text));
end;

function OwnerName(Owner: TPlugin): WideString;
begin
  if Owner = nil then
    Result := 'built-in'
  else
    Result := FromUtf8(PAnsiChar(Owner.PluginId));
end;

{ Field map }

procedure AddField(const TypeName, FieldName: AnsiString; Offset: PtrUInt; ByteSize: Integer; const TypeText: AnsiString);
var
  N: Integer;
begin
  N := Length(FieldEntries);
  SetLength(FieldEntries, N + 1);
  FieldEntries[N].Offset := PtrInt(Offset);
  FieldEntries[N].ByteSize := ByteSize;
  FieldEntries[N].TypeText := TypeText;
  FieldNames.AddObject(LowerCase(TypeName + '.' + FieldName), TObject(PtrInt(N)));
end;

procedure AddClass(const TypeName: AnsiString; ClassType: TClass);
begin
  ClassNames.AddObject(LowerCase(TypeName), TObject(ClassType));
end;

procedure EnsureFieldMap;
begin
  if FieldNames <> nil then
    Exit;
  FieldNames := TStringList.Create;
  FieldNames.Duplicates := dupAccept;
  FieldNames.Sorted := True;
  ClassNames := TStringList.Create;
  ClassNames.Duplicates := dupAccept;
  ClassNames.Sorted := True;
  FillFieldMap(@AddField, @AddClass);
end;

function XenoFieldOffset(const TypeName, FieldName: AnsiString; out ByteSize: Integer; out TypeText: AnsiString): PtrInt;
var
  Index: Integer;
  Name: AnsiString;
  ClassType: TClass;
begin
  EnsureFieldMap;
  Result := -1;
  ByteSize := 0;
  TypeText := '';
  Name := LowerCase(TypeName);
  ClassType := nil;
  if ClassNames.Find(Name, Index) then
    ClassType := TClass(ClassNames.Objects[Index]);
  repeat
    if FieldNames.Find(Name + '.' + LowerCase(FieldName), Index) then
    begin
      Index := PtrInt(FieldNames.Objects[Index]);
      ByteSize := FieldEntries[Index].ByteSize;
      TypeText := FieldEntries[Index].TypeText;
      Exit(FieldEntries[Index].Offset);
    end;
    // Inherited fields: walk the class chain.
    if ClassType = nil then
      Exit;
    ClassType := ClassType.ClassParent;
    if ClassType = nil then
      Exit;
    Name := LowerCase(ClassType.ClassName);
  until False;
end;

{$I XenoPluginHooks.inc}

{ Events }

function XenoSubscribe(const EventName: AnsiString; Callback: TXenoFpcEventFn; User: Pointer): Boolean;
var
  Event: TXenoEvent;
  N: Integer;
begin
  Result := False;
  if not Assigned(Callback) then
    Exit;
  for Event := Low(TXenoEvent) to High(TXenoEvent) do
    if SameText(EventNames[Event], EventName) then
    begin
      N := Length(Subscribers[Event]);
      SetLength(Subscribers[Event], N + 1);
      Subscribers[Event][N].Callback := Callback;
      Subscribers[Event][N].User := User;
      Subscribers[Event][N].Owner := CurrentPlugin;
      Exit(True);
    end;
end;

function XenoHasSubscribers(Event: TXenoEvent): Boolean; inline;
begin
  Result := Length(Subscribers[Event]) > 0;
end;

procedure XenoRaise(Event: TXenoEvent; var Payload);
var
  List: array of TSubscriber;
  I: Integer;
begin
  List := Subscribers[Event];
  for I := 0 to High(List) do
    try
      List[I].Callback(List[I].User, @Payload);
    except
      // A failing subscriber must not take the game down; report it once per call.
      LogCurrentGameException('xeno', OwnerName(List[I].Owner) + ' failed in ' + WideString(EventNames[Event]), gllError);
    end;
end;

{ Host API }

procedure Host_Log(PluginId: PAnsiChar; Level: Integer; Text: PAnsiChar); cdecl;
var
  LogLevel: TGameLogLevel;
begin
  case Level of
    0: LogLevel := gllDebug;
    2: LogLevel := gllWarning;
    3: LogLevel := gllError;
  else
    LogLevel := gllInfo;
  end;
  LogGameMessage(LogLevel, 'xeno', FromUtf8(PluginId) + ': ' + FromUtf8(Text));
end;

function OpenIni(Path: PAnsiChar): TXenoIni;
var
  FullPath, Root: WideString;
begin
  Result := nil;
  FullPath := FromUtf8(Path);
  if FullPath = '' then
    Exit;
  // TXenoIni takes game-relative paths; strip the game root when present.
  Root := IncludeTrailingPathDelimiter(FromUtf8(PAnsiChar(GameRootText)));
  if SameText(Copy(FullPath, 1, Length(Root)), Root) then
    FullPath := Copy(FullPath, Length(Root) + 1, MaxInt);
  Result := TXenoIni.Create(FullPath);
  if not Result.Loaded then
    FreeAndNil(Result);
end;

function Host_ConfigGetInt(Path, Section, Key: PAnsiChar; Default, Minimum, Maximum: Integer): Integer; cdecl;
var
  Ini: TXenoIni;
begin
  Result := Default;
  try
    Ini := OpenIni(Path);
    if Ini <> nil then
      try
        Result := Ini.ReadInt(FromUtf8(Section), FromUtf8(Key), Default, Minimum, Maximum);
      finally
        Ini.Free;
      end;
  except
    Result := Default;
  end;
end;

function Host_ConfigGetString(Path, Section, Key, Default: PAnsiChar; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
var
  Ini: TXenoIni;
  Value: WideString;
begin
  Value := FromUtf8(Default);
  try
    Ini := OpenIni(Path);
    if Ini <> nil then
      try
        Value := Ini.ReadString(FromUtf8(Section), FromUtf8(Key), Value);
      finally
        Ini.Free;
      end;
  except
  end;
  Result := CopyOut(Utf8(Value), Buffer, BufferSize);
end;

function Host_GameConfigGet(Root: Integer; Path: PAnsiChar; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
var
  Config: TBlockParEC;
  Key: WideString;
begin
  Result := -1;
  if Root = 0 then
    Config := MainDataConfig
  else
    Config := LanguageDataConfig;
  Key := FromUtf8(Path);
  if (Config = nil) or (Key = '') then
    Exit;
  try
    if Config.CountParamsByPath(Key) > 0 then
      Result := CopyOut(Utf8(Config.GetParamByPath(Key)), Buffer, BufferSize);
  except
    Result := -1;
  end;
end;

function Host_IsModActive(ModName: PAnsiChar): Integer; cdecl;
begin
  Result := Ord(XenoModActive(FromUtf8(ModName)));
end;

function Host_Subscribe(EventName: PAnsiChar; Callback: TXenoFpcEventFn; User: Pointer): Integer; cdecl;
begin
  Result := Ord(XenoSubscribe(AnsiString(EventName), Callback, User));
end;

procedure ScriptBridgeCall(User: Pointer; av: array of TVarEC; Code: TCodeEC);
var
  Bridge: TScriptBridge;
  Values: array of TXenoFpcValue;
  Strings: array of UTF8String;
  Call: TXenoFpcScriptCall;
  I: Integer;
begin
  Bridge := TScriptBridge(User);
  if (Bridge.Owner <> nil) and not Bridge.Owner.Active then
    raise ExceptionExpressionEC.Create('Plugin library unloaded: ' + WideString(Bridge.Name));
  SetLength(Values, Max(0, Length(av) - 1));
  SetLength(Strings, Length(Values));
  for I := 1 to High(av) do
  begin
    FillChar(Values[I - 1], SizeOf(TXenoFpcValue), 0);
    if I + 1 > High(Bridge.Kinds) + 1 then
      Continue;
    Values[I - 1].Kind := Ord(Bridge.Kinds[I + 1]);
    case Bridge.Kinds[I + 1] of
      lvInt: Values[I - 1].I := av[I].GetInt;
      lvDword: Values[I - 1].Dword := av[I].GetDword;
      lvFloat: Values[I - 1].F := av[I].GetFloat;
      lvString:
      begin
        Strings[I - 1] := Utf8(av[I].GetString);
        Values[I - 1].S := PAnsiChar(Strings[I - 1]);
      end;
    end;
  end;
  FillChar(Call, SizeOf(Call), 0);
  Call.Size := SizeOf(Call);
  Call.ArgumentCount := Length(Values);
  if Length(Values) > 0 then
    Call.Arguments := @Values[0];
  Call.Result.Kind := Ord(Bridge.Kinds[0]);
  Bridge.Callback(Bridge.User, @Call);
  case Bridge.Kinds[0] of
    lvInt: av[0].SetInt(Call.Result.I);
    lvDword: av[0].SetDword(Call.Result.Dword);
    lvFloat: av[0].SetFloat(Call.Result.F);
    lvString: av[0].SetString(FromUtf8(Call.Result.S));
  end;
end;

function Host_RegisterScriptFunction(LibraryName, Signature: PAnsiChar; Callback: TXenoFpcScriptFn; User: Pointer): Integer; cdecl;
var
  Bridge: TScriptBridge;
  Text, Kind: WideString;
  I, Count: Integer;
begin
  Result := 0;
  if (LibraryName = nil) or (Signature = nil) or not Assigned(Callback) then
    Exit;
  Text := FromUtf8(Signature);
  Count := CountDelimitedPartsW(Text, ',');
  if Count < 2 then
    Exit;
  Bridge := TScriptBridge.Create;
  Bridge.Owner := CurrentPlugin;
  Bridge.Callback := Callback;
  Bridge.User := User;
  Bridge.Name := Utf8(ExtractDelimitedPartW(Text, 1, ','));
  SetLength(Bridge.Kinds, Count);
  for I := 0 to Count - 1 do
  begin
    Kind := LowerCase(TrimWideString(ExtractDelimitedPartW(Text, I, ',')));
    if I = 1 then
      Bridge.Kinds[I] := lvVoid
    else if Kind = 'void' then
      Bridge.Kinds[I] := lvVoid
    else if Kind = 'int' then
      Bridge.Kinds[I] := lvInt
    else if Kind = 'dword' then
      Bridge.Kinds[I] := lvDword
    else if Kind = 'float' then
      Bridge.Kinds[I] := lvFloat
    else if Kind = 'str' then
      Bridge.Kinds[I] := lvString
    else
    begin
      Bridge.Free;
      Exit;
    end;
  end;
  Bridges.Add(Bridge);
  RegisterNativeScriptUserFunction(FromUtf8(LibraryName), Text, @ScriptBridgeCall, Bridge);
  Result := 1;
end;

function Host_FieldInfo(TypeName, FieldName: PAnsiChar; Info: PXenoFpcFieldInfo): Integer; cdecl;
var
  Offset: PtrInt;
  ByteSize: Integer;
  TypeText: AnsiString;
  Index: Integer;
begin
  Result := 0;
  if (TypeName = nil) or (FieldName = nil) then
    Exit;
  Offset := XenoFieldOffset(AnsiString(TypeName), AnsiString(FieldName), ByteSize, TypeText);
  if Offset < 0 then
    Exit;
  if Info <> nil then
  begin
    Info^.Offset := Offset;
    Info^.ByteSize := ByteSize;
    // Point into the permanent table entry so the string stays valid.
    for Index := 0 to High(FieldEntries) do
      if (FieldEntries[Index].Offset = Offset) and (FieldEntries[Index].TypeText = TypeText) then
      begin
        Info^.TypeName := PAnsiChar(FieldEntries[Index].TypeText);
        Break;
      end;
  end;
  Result := 1;
end;

function Host_IsLiveObject(Obj: Pointer): Integer; cdecl;
begin
  Result := Ord((Obj <> nil) and IsLiveGameObject(Obj));
end;

function Host_IsInstanceOf(Obj: Pointer; ClassName: PAnsiChar): Integer; cdecl;
var
  ClassType: TClass;
  Name: AnsiString;
begin
  Result := 0;
  if (Obj = nil) or (ClassName = nil) or not IsLiveGameObject(Obj) then
    Exit;
  Name := AnsiString(ClassName);
  ClassType := TObject(Obj).ClassType;
  while ClassType <> nil do
  begin
    if SameText(ClassType.ClassName, Name) then
      Exit(1);
    ClassType := ClassType.ClassParent;
  end;
end;

function Host_ObjectClassName(Obj: Pointer; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
begin
  if (Obj = nil) or not IsLiveGameObject(Obj) then
    Exit(-1);
  Result := CopyOut(UTF8String(TObject(Obj).ClassName), Buffer, BufferSize);
end;

function Host_Galaxy: Pointer; cdecl;
begin
  Result := aGalaxy.Galaxy;
end;

function Host_Player: Pointer; cdecl;
begin
  Result := GetPlayer;
end;

function Host_ListCount(List: Pointer): Integer; cdecl;
begin
  if List = nil then
    Exit(0);
  Result := TList(List).Count;
end;

function Host_ListItem(List: Pointer; Index: Integer): Pointer; cdecl;
begin
  Result := nil;
  if (List <> nil) and (Index >= 0) and (Index < TList(List).Count) then
    Result := TList(List)[Index];
end;

function Host_ReadWideString(Obj: Pointer; Offset: PtrInt; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
begin
  if Obj = nil then
    Exit(-1);
  Result := CopyOut(Utf8(PWideString(PAnsiChar(Obj) + Offset)^), Buffer, BufferSize);
end;

function Host_ObjectById(Kind: Integer; Id: Cardinal): Pointer; cdecl;
begin
  Result := nil;
  if aGalaxy.Galaxy = nil then
    Exit;
  try
    case Kind of
      1: Result := aGalaxy.Galaxy.IdToShip(Id, False);
      2: Result := aGalaxy.Galaxy.IdToItem(Id, False);
    end;
  except
    Result := nil;
  end;
end;

function Host_UiFindControl(Screen: Pointer; Name: PAnsiChar): Pointer; cdecl;
begin
  Result := nil;
  if (Screen = nil) or (Name = nil) or not (TObject(Screen) is TMessageLoopGI) then
    Exit;
  Result := TMessageLoopGI(Screen).FindControlByPath(FromUtf8(Name));
end;

procedure Host_UiSetActive(Control: Pointer; Active: Integer); cdecl;
begin
  if (Control <> nil) and (TObject(Control) is TObjectGI) then
    TObjectGI(Control).SetActive(Active <> 0);
end;

procedure TUiThunk.Fire(Sender: TObjectGI);
begin
  if (Owner <> nil) and not Owner.Active then
    Exit;
  try
    Callback(User, Sender);
  except
    LogCurrentGameException('xeno', OwnerName(Owner) + ' failed in a button callback', gllError);
  end;
end;

function Host_UiSetButtonCallback(Control: Pointer; Callback: TXenoFpcUiCallbackFn; User: Pointer): Integer; cdecl;
var
  Thunk: TUiThunk;
begin
  Result := 0;
  if (Control = nil) or not (TObject(Control) is TGraphButtonGI) or not Assigned(Callback) then
    Exit;
  Thunk := TUiThunk.Create;
  Thunk.Callback := Callback;
  Thunk.User := User;
  Thunk.Owner := CurrentPlugin;
  Thunks.Add(Thunk);
  TGraphButtonGI(Control).UpCallback := Thunk.Fire;
  Result := 1;
end;

function Host_UiSetLabelText(Control: Pointer; Text: PAnsiChar): Integer; cdecl;
begin
  Result := 0;
  if (Control <> nil) and (TObject(Control) is TLabelGI) then
  begin
    TLabelGI(Control).SetText(FromUtf8(Text));
    Result := 1;
  end;
end;

function Host_TickCount: Cardinal; cdecl;
begin
  Result := GameTickCount;
end;

procedure Host_HangarShowShip(Hangar: Pointer; Slot: Integer; Ship: Pointer); cdecl;
var
  Form: TfHangar;
  Path: WideString;
begin
  if (Hangar = nil) or not (TObject(Hangar) is TfHangar) or (Slot < 1) or (Slot > 8) then
    Exit;
  Form := TfHangar(Hangar);
  if (Ship <> nil) and IsLiveGameObject(Ship) and (TObject(Ship) is TShip) then
    Path := TShip(Ship).GetShipPortraitImagePath
  else
    Path := '';
  if Path = '' then
  begin
    Form.ShipSlots[Slot].AnimationState := 0;
    Form.ShipSlots[Slot].ShipId := 0;
    Form.ShipSlots[Slot].Opacity := 0;
    if Form.ShipSlots[Slot].ImageControl <> nil then
      Form.ShipSlots[Slot].ImageControl.SetActive(False);
    Exit;
  end;
  Form.ShipSlots[Slot].ShipId := TShip(Ship).Id;
  Form.ShipSlots[Slot].AnimationState := 1;
  Form.ShipSlots[Slot].Opacity := 0;
  Form.LoadDockedShipImage(Slot, Path, False, Form.GetShipPortraitScale(TShip(Ship)));
  Form.SetDockedShipOpacity(Slot, 0);
end;

function MusicUnit(UnitIndex: Integer): TMusicUnit;
begin
  Result := nil;
  if MusicManager = nil then
    Exit;
  if UnitIndex = 0 then
    Result := MusicManager.Current
  else if UnitIndex = 1 then
    Result := MusicManager.Queued;
end;

function Host_MusicChooseFile(Category, CurrentFile: PAnsiChar; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
begin
  Result := CopyOut(Utf8(ChooseMusicFile(FromUtf8(Category), FromUtf8(CurrentFile))), Buffer, BufferSize);
end;

procedure XenoMusicPlayCategoryOriginal(const Category: WideString);
begin
  if MusicManager = nil then
    Exit;
  InternalMusicCall := True;
  try
    MusicManager.PlayCategory(Category);
  finally
    InternalMusicCall := False;
  end;
end;

procedure Host_MusicPlayCategory(Category: PAnsiChar); cdecl;
begin
  XenoMusicPlayCategoryOriginal(FromUtf8(Category));
end;

function Host_MusicUnitRunning(UnitIndex: Integer): Integer; cdecl;
var
  Music: TMusicUnit;
begin
  Result := 0;
  Music := MusicUnit(UnitIndex);
  if Music <> nil then
    try
      Result := Ord(Music.IsRunning);
    except
      Result := 0;
    end;
end;

function Host_MusicUnitFile(UnitIndex: Integer; Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
var
  Music: TMusicUnit;
  Name: WideString;
begin
  Name := '';
  Music := MusicUnit(UnitIndex);
  if Music <> nil then
    try
      Name := Music.GetFileName;
    except
      Name := '';
    end;
  Result := CopyOut(Utf8(Name), Buffer, BufferSize);
end;

procedure Host_MusicUnitStop(UnitIndex: Integer; Immediate: Integer); cdecl;
var
  Music: TMusicUnit;
begin
  Music := MusicUnit(UnitIndex);
  if Music = nil then
    Exit;
  if Immediate <> 0 then
    Music.ImmediateStop := True;
  Music.RequestStop;
  SetGameEvent(Music.StartPlaybackEvent);
end;

procedure Host_MusicUnitStart(UnitIndex: Integer); cdecl;
var
  Music: TMusicUnit;
begin
  Music := MusicUnit(UnitIndex);
  if Music <> nil then
    SetGameEvent(Music.StartPlaybackEvent);
end;

function Host_MusicUnitBuffer(UnitIndex: Integer): Pointer; cdecl;
var
  Music: TMusicUnit;
begin
  Music := MusicUnit(UnitIndex);
  if Music = nil then
    Result := nil
  else
    Result := Music.Buffer;
end;

procedure SampleMusicProgress;
var
  Music: TMusicUnit;
  Stream: TFileStreamEC;
  NowMs: Cardinal;
begin
  NowMs := GameTickCount;
  Music := MusicUnit(0);
  Stream := nil;
  if Music <> nil then
    Stream := Music.Stream;
  if Stream = nil then
  begin
    ProgressStream := nil;
    Exit;
  end;
  if Pointer(Stream) <> ProgressStream then
  begin
    ProgressStream := Stream;
    ProgressStartMs := NowMs;
    ProgressSwapped := 0;
    ProgressReadBuffer := Stream.ReadBuffer;
    ProgressBufferFill := Stream.ReadPosition + Stream.ReadAvailable;
  end
  else if Stream.ReadBuffer <> ProgressReadBuffer then
  begin
    Inc(ProgressSwapped, ProgressBufferFill);
    ProgressReadBuffer := Stream.ReadBuffer;
    ProgressBufferFill := Stream.ReadPosition + Stream.ReadAvailable;
  end
  else
    ProgressBufferFill := Stream.ReadPosition + Stream.ReadAvailable;
  ProgressConsumed := ProgressSwapped + Stream.ReadPosition;
  ProgressUnread := Stream.ReadAvailable + Stream.FillAvailable;
  ProgressFileSize := Stream.FileSize;
  ProgressEndOfFile := Stream.EndOfFile;
  ProgressNowMs := NowMs;
end;

function XenoMusicRemainingMs: Integer;
const
  DecodeLeadMs = 5000;
  MinimumElapsedMs = 8000;
var
  Elapsed: Cardinal;
  Rate, Total: Double;
begin
  Result := -1;
  if (ProgressStream = nil) or (ProgressFileSize <= 0) then
    Exit;
  Elapsed := ProgressNowMs - ProgressStartMs;
  if (Elapsed < MinimumElapsedMs) or (ProgressConsumed = 0) then
    Exit;
  // Bytes of the file per second of audio; the decoder runs ~5 s ahead.
  Rate := ProgressConsumed * 1000.0 / (Elapsed + DecodeLeadMs);
  if Rate <= 0 then
    Exit;
  if ProgressEndOfFile then
    Exit(Trunc(ProgressUnread * 1000.0 / Rate) + DecodeLeadMs);
  Total := ProgressFileSize * 1000.0 / Rate;
  Result := Max(0, Trunc(Total - Elapsed));
end;

function Host_MusicRemainingMs: Integer; cdecl;
begin
  Result := XenoMusicRemainingMs;
end;

procedure Host_SoundSetVolumeStep(Buffer: Pointer; Step: Single); cdecl;
begin
  if (Buffer <> nil) and (TObject(Buffer) is TSoundBuffer) then
    TSoundBuffer(Buffer).VolumeStep := Step;
end;

function Host_MusicCategoryOverride(Buffer: PAnsiChar; BufferSize: Integer): Integer; cdecl;
begin
  if MusicManager = nil then
    Result := CopyOut('', Buffer, BufferSize)
  else
    Result := CopyOut(Utf8(MusicManager.CategoryOverride), Buffer, BufferSize);
end;

{ Plugin loading }

function SelectedModFolders: TStringList;
var
  I, Count: Integer;
  Entry: WideString;
begin
  Result := TStringList.Create;
  if SkipModsOnReload then
    Exit;
  Count := CountDelimitedPartsW(SelectedMods, ',');
  for I := 0 to Count - 1 do
  begin
    Entry := TrimWideString(ExtractDelimitedPartW(SelectedMods, I, ','));
    if Entry <> '' then
      Result.Add(Utf8('Mods\' + Entry + '\'));
  end;
end;

procedure FillHost(Plugin: TPlugin);
begin
  FillChar(Plugin.Host, SizeOf(Plugin.Host), 0);
  with Plugin.Host do
  begin
    Size := SizeOf(TXenoFpcHostV1);
    ApiVersion := HostApiVersion;
    GameVersion := PAnsiChar(GameVersionText);
    GameRoot := PAnsiChar(GameRootText);
    ModFolder := PAnsiChar(Plugin.ModFolder);
    PluginPath := PAnsiChar(Plugin.Path);
    ConfigPath := PAnsiChar(Plugin.ConfigPath);
    TargetCpu := PAnsiChar(TargetCpuText);
    Log := @Host_Log;
    ConfigGetInt := @Host_ConfigGetInt;
    ConfigGetString := @Host_ConfigGetString;
    GameConfigGet := @Host_GameConfigGet;
    IsModActive := @Host_IsModActive;
    Subscribe := @Host_Subscribe;
    RegisterScriptFunction := @Host_RegisterScriptFunction;
    FieldInfo := @Host_FieldInfo;
    IsLiveObject := @Host_IsLiveObject;
    IsInstanceOf := @Host_IsInstanceOf;
    ObjectClassName := @Host_ObjectClassName;
    Galaxy := @Host_Galaxy;
    Player := @Host_Player;
    ListCount := @Host_ListCount;
    ListItem := @Host_ListItem;
    ReadWideString := @Host_ReadWideString;
    ObjectById := @Host_ObjectById;
    UiFindControl := @Host_UiFindControl;
    UiSetActive := @Host_UiSetActive;
    UiSetButtonCallback := @Host_UiSetButtonCallback;
    UiSetLabelText := @Host_UiSetLabelText;
    TickCount := @Host_TickCount;
    HangarShowShip := @Host_HangarShowShip;
    MusicChooseFile := @Host_MusicChooseFile;
    MusicPlayCategory := @Host_MusicPlayCategory;
    MusicUnitRunning := @Host_MusicUnitRunning;
    MusicUnitFile := @Host_MusicUnitFile;
    MusicUnitStop := @Host_MusicUnitStop;
    MusicUnitStart := @Host_MusicUnitStart;
    MusicUnitBuffer := @Host_MusicUnitBuffer;
    MusicRemainingMs := @Host_MusicRemainingMs;
    SoundSetVolumeStep := @Host_SoundSetVolumeStep;
    MusicCategoryOverride := @Host_MusicCategoryOverride;
    HookCount := @Host_HookCount;
    HookInfoAt := @Host_HookInfoAt;
    HookFind := @Host_HookFind;
    HookAdd := @Host_HookAdd;
    Hook := @Host_Hook;
    HookRemove := @Host_HookRemove;
    Invoke := @Host_Invoke;
    ValueGetString := @Host_ValueGetString;
    ValueSetString := @Host_ValueSetString;
  end;
end;

procedure UnloadPlugin(Plugin: TPlugin);
var
  Event: TXenoEvent;
  I, N: Integer;
  Kept: array of TSubscriber;
begin
  if Plugin.Active and Assigned(Plugin.Shutdown) then
    try
      Plugin.Shutdown();
    except
      LogCurrentGameException('xeno', WideString(Plugin.PluginId) + ' failed during shutdown', gllWarning);
    end;
  Plugin.Active := False;
  RemoveHandlers(0, Plugin, True);
  for Event := Low(TXenoEvent) to High(TXenoEvent) do
  begin
    SetLength(Kept, 0);
    N := 0;
    for I := 0 to High(Subscribers[Event]) do
      if Subscribers[Event][I].Owner <> Plugin then
      begin
        SetLength(Kept, N + 1);
        Kept[N] := Subscribers[Event][I];
        Inc(N);
      end;
    Subscribers[Event] := Kept;
  end;
  // Script bridges and button thunks stay allocated (the script engine and
  // controls may still refer to them) but refuse to call into the plugin.
  if Plugin.Handle <> NilHandle then
    UnloadLibrary(Plugin.Handle);
  Plugin.Handle := NilHandle;
  LogGameMessage(gllInfo, 'xeno', 'Plugin unloaded: ' + WideString(Plugin.Path));
end;

procedure LoadPlugin(const ModFolder, FileName: WideString);
var
  Plugin: TPlugin;
  Query: TPluginQueryFn;
  Initialize: TPluginInitializeFn;
  Info: TXenoFpcPluginInfoV1;
  Status: Integer;
  IniName: WideString;
  Ini: TXenoIni;
begin
  IniName := Copy(FileName, 1, Length(FileName) - Length(ExtractFileExt(FileName))) + '.ini';
  Ini := TXenoIni.Create(ModFolder + 'Native\' + IniName);
  try
    if Ini.Loaded and (Ini.ReadInt('Plugin', 'Enabled', 1, 0, 1) = 0) then
    begin
      LogGameMessage(gllInfo, 'xeno', 'Plugin disabled by its INI: ' + ModFolder + 'Native\' + FileName);
      Exit;
    end;
  finally
    Ini.Free;
  end;
  Plugin := TPlugin.Create;
  Plugin.ModFolder := Utf8(ModFolder);
  Plugin.Path := Utf8(ExpandFileName(NativeGamePath(ModFolder + 'Native\' + FileName)));
  Plugin.ConfigPath := Utf8(ExpandFileName(NativeGamePath(ModFolder + 'Native\' + IniName)));
  Plugin.Handle := LoadLibrary(UnicodeString(UTF8Decode(Plugin.Path)));
  if Plugin.Handle = NilHandle then
  begin
    LogGameMessage(gllWarning, 'xeno', 'Plugin cannot be loaded: ' + WideString(Plugin.Path) + ': ' + WideString(GetLoadErrorStr));
    Plugin.Free;
    Exit;
  end;
  Query := TPluginQueryFn(GetProcedureAddress(Plugin.Handle, 'XenoFpcPlugin_Query'));
  Initialize := TPluginInitializeFn(GetProcedureAddress(Plugin.Handle, 'XenoFpcPlugin_Initialize'));
  Plugin.Shutdown := TPluginShutdownFn(GetProcedureAddress(Plugin.Handle, 'XenoFpcPlugin_Shutdown'));
  if not Assigned(Initialize) then
  begin
    // A XenoNativeLoader-only DLL: it patches the Delphi game and cannot run here.
    LogGameMessage(gllWarning, 'xeno', 'Not a XenoModsFPC plugin (no XenoFpcPlugin_Initialize), skipped: ' + WideString(Plugin.Path));
    UnloadLibrary(Plugin.Handle);
    Plugin.Free;
    Exit;
  end;
  FillChar(Info, SizeOf(Info), 0);
  Info.Size := SizeOf(Info);
  Plugin.PluginId := Utf8(ChangeFileExt(ChangeFileExt(FileName, ''), ''));
  if Assigned(Query) then
    try
      if Query(@Info) <> 0 then
      begin
        if Info.RequiredHostApi > HostApiVersion then
        begin
          LogGameMessage(gllWarning, 'xeno', 'Plugin needs host API ' + IntToStr(Info.RequiredHostApi) + ', skipped: '
              + WideString(Plugin.Path));
          UnloadLibrary(Plugin.Handle);
          Plugin.Free;
          Exit;
        end;
        if Info.Id[0] <> #0 then
          Plugin.PluginId := UTF8String(PAnsiChar(@Info.Id[0]));
        Plugin.Version := UTF8String(PAnsiChar(@Info.Version[0]));
      end;
    except
      LogCurrentGameException('xeno', 'Plugin query failed: ' + WideString(Plugin.Path), gllWarning);
    end;
  FillHost(Plugin);
  Plugins.Add(Plugin);
  Plugin.Active := True;
  CurrentPlugin := Plugin;
  try
    try
      Status := Initialize(@Plugin.Host);
    except
      LogCurrentGameException('xeno', 'Plugin initialization raised: ' + WideString(Plugin.Path), gllError);
      Status := -1;
    end;
  finally
    CurrentPlugin := nil;
  end;
  if Status <> 0 then
  begin
    LogGameMessage(gllWarning, 'xeno', 'Plugin ' + WideString(Plugin.PluginId) + ' initialization returned ' + IntToStr(Status));
    UnloadPlugin(Plugin);
    Plugins.Remove(Plugin);
    Plugin.Free;
    Exit;
  end;
  LogGameMessage(gllInfo, 'xeno', 'Plugin loaded: ' + WideString(Plugin.PluginId) + ' ' + WideString(Plugin.Version) + ' from '
      + ModFolder);
end;

procedure XenoSyncPlugins;
var
  Folders: TStringList;
  I, J: Integer;
  Search: TSearchRec;
  Plugin: TPlugin;
  Folder: WideString;
  Known: Boolean;
begin
  if (LastSyncSelection = SelectedMods) and (Plugins <> nil) then
    Exit;
  LastSyncSelection := SelectedMods;
  if Plugins = nil then
  begin
    Plugins := TList.Create;
    Bridges := TList.Create;
    Thunks := TList.Create;
  end;
  GameRootText := Utf8(ExcludeTrailingPathDelimiter(GetCurrentDir));
  GameVersionText := '2.1.2500 fpc xenomodsfpc';
  TargetCpuText := {$I %FPCTARGETCPU%};
  Folders := SelectedModFolders;
  try
    // Unload plugins whose mod was deselected.
    for I := Plugins.Count - 1 downto 0 do
    begin
      Plugin := TPlugin(Plugins[I]);
      if Folders.IndexOf(Plugin.ModFolder) < 0 then
      begin
        UnloadPlugin(Plugin);
        Plugins.Delete(I);
        Plugin.Free;
      end;
    end;
    for I := 0 to Folders.Count - 1 do
    begin
      Folder := UTF8Decode(Folders[I]);
      if FindFirst(UTF8Encode(NativeGamePath(Folder + 'Native\*' + PluginSuffix)), faAnyFile, Search) <> 0 then
        Continue;
      try
        repeat
          Known := False;
          for J := 0 to Plugins.Count - 1 do
            if SameText(TPlugin(Plugins[J]).Path,
                Utf8(ExpandFileName(NativeGamePath(Folder + 'Native\' + UTF8Decode(Search.Name))))) then
              Known := True;
          if not Known then
            LoadPlugin(Folder, UTF8Decode(Search.Name));
        until FindNext(Search) <> 0;
      finally
        FindClose(Search);
      end;
    end;
  finally
    Folders.Free;
  end;
end;

procedure XenoShutdownPlugins;
var
  I: Integer;
begin
  if Plugins = nil then
    Exit;
  for I := Plugins.Count - 1 downto 0 do
  begin
    UnloadPlugin(TPlugin(Plugins[I]));
    TPlugin(Plugins[I]).Free;
  end;
  Plugins.Clear;
  ShutdownHooks;
end;

function XenoLoadedPluginCount: Integer;
begin
  if Plugins = nil then
    Result := 0
  else
    Result := Plugins.Count;
end;

{ Raisers }

procedure XenoRaiseFrame;
var
  Event: TXenoFpcFrameEvent;
begin
  SampleMusicProgress;
  if not XenoHasSubscribers(xeFrame) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.Tick := GameTickCount;
  XenoRaise(xeFrame, Event);
end;

function XenoRaiseGalaxyCreated(Galaxy: Pointer; SectorCount: Integer): Integer;
var
  Event: TXenoFpcGalaxyCreatedEvent;
begin
  Event.Size := SizeOf(Event);
  Event.Galaxy := Galaxy;
  Event.SectorCount := SectorCount;
  if XenoHasSubscribers(xeGalaxyCreated) then
    XenoRaise(xeGalaxyCreated, Event);
  Result := EnsureRange(Event.SectorCount, 1, 255);
end;

function XenoRaiseGalaxyPlanStar(Galaxy: Pointer; StarIndex: Integer): Integer;
var
  Event: TXenoFpcGalaxyPlanStarEvent;
begin
  Result := -1;
  if not XenoHasSubscribers(xeGalaxyPlanStar) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.Galaxy := Galaxy;
  Event.StarIndex := StarIndex;
  Event.Sector := -1;
  XenoRaise(xeGalaxyPlanStar, Event);
  Result := Event.Sector;
end;

function XenoRaiseGalaxyLayoutDone(Galaxy: Pointer; Attempts: Integer): Boolean;
var
  Event: TXenoFpcGalaxyLayoutEvent;
begin
  Event.Size := SizeOf(Event);
  Event.Galaxy := Galaxy;
  Event.Attempts := Attempts;
  Event.Done := Ord(Attempts > 1000);
  if XenoHasSubscribers(xeGalaxyLayoutDone) then
    XenoRaise(xeGalaxyLayoutDone, Event);
  Result := Event.Done <> 0;
end;

function XenoRaiseContourNoEar: Boolean;
var
  Event: TXenoFpcContourEvent;
begin
  Result := False;
  if not XenoHasSubscribers(xeGalaxyContourNoEar) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.RemoveVertex := 0;
  XenoRaise(xeGalaxyContourNoEar, Event);
  Result := Event.RemoveVertex <> 0;
end;

function XenoRaiseStationSpawning(Galaxy: Pointer; Day: Integer): Boolean;
var
  Event: TXenoFpcStationSpawningEvent;
begin
  Result := True;
  if not XenoHasSubscribers(xeGalaxyStationSpawning) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.Galaxy := Galaxy;
  Event.Day := Day;
  Event.Run := 1;
  XenoRaise(xeGalaxyStationSpawning, Event);
  Result := Event.Run <> 0;
end;

procedure XenoRaiseItem(Event: TXenoEvent; Item: Pointer);
var
  Payload: TXenoFpcItemEvent;
begin
  if not XenoHasSubscribers(Event) then
    Exit;
  Payload.Size := SizeOf(Payload);
  Payload.Item := Item;
  XenoRaise(Event, Payload);
end;

function XenoRaiseItemSaveCost(Item: Pointer; Cost: Integer): Integer;
var
  Event: TXenoFpcItemSaveCostEvent;
begin
  Result := Cost;
  if not XenoHasSubscribers(xeItemSaveCost) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.Item := Item;
  Event.Cost := Cost;
  XenoRaise(xeItemSaveCost, Event);
  Result := Event.Cost;
end;

function XenoRaiseCamouflage(Kling, Target: Pointer; out Effective: Boolean): Boolean;
var
  Event: TXenoFpcCamouflageEvent;
begin
  Effective := False;
  Result := False;
  if not XenoHasSubscribers(xeKlingCamouflage) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.Kling := Kling;
  Event.Target := Target;
  Event.Handled := 0;
  Event.Effective := 0;
  XenoRaise(xeKlingCamouflage, Event);
  Result := Event.Handled <> 0;
  Effective := Event.Effective <> 0;
end;

procedure XenoRaiseHangar(Event: TXenoEvent; Hangar: Pointer);
var
  Payload: TXenoFpcHangarEvent;
begin
  if not XenoHasSubscribers(Event) then
    Exit;
  Payload.Size := SizeOf(Payload);
  Payload.Hangar := Hangar;
  XenoRaise(Event, Payload);
end;

function XenoRaiseHangarRefresh(Hangar: Pointer): Boolean;
var
  Event: TXenoFpcHangarRefreshEvent;
begin
  Result := False;
  if not XenoHasSubscribers(xeHangarRefresh) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.Hangar := Hangar;
  Event.Handled := 0;
  XenoRaise(xeHangarRefresh, Event);
  Result := Event.Handled <> 0;
end;

function XenoRaiseHangarKey(Hangar: Pointer; Key: Cardinal): Boolean;
var
  Event: TXenoFpcHangarKeyEvent;
begin
  Result := False;
  if not XenoHasSubscribers(xeHangarKey) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.Hangar := Hangar;
  Event.Key := Key;
  Event.Handled := 0;
  XenoRaise(xeHangarKey, Event);
  Result := Event.Handled <> 0;
end;

function XenoRaiseMusicPlayCategory(const Category: WideString): Boolean;
var
  Event: TXenoFpcMusicCategoryEvent;
  Text: UTF8String;
begin
  Result := True;
  if InternalMusicCall or not XenoHasSubscribers(xeMusicPlayCategory) then
    Exit;
  Text := Utf8(Category);
  Event.Size := SizeOf(Event);
  Event.Category := PAnsiChar(Text);
  Event.Skip := 0;
  XenoRaise(xeMusicPlayCategory, Event);
  Result := Event.Skip = 0;
end;

procedure XenoRaiseMusicStopImmediately;
var
  Event: TXenoFpcMusicStopEvent;
begin
  if not XenoHasSubscribers(xeMusicStopImmediately) then
    Exit;
  Event.Size := SizeOf(Event);
  XenoRaise(xeMusicStopImmediately, Event);
end;

function XenoRaiseMusicPlaceFade: Boolean;
var
  Event: TXenoFpcMusicPlaceFadeEvent;
begin
  Result := False;
  if not XenoHasSubscribers(xeMusicPlaceFade) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.Keep := 0;
  XenoRaise(xeMusicPlaceFade, Event);
  Result := Event.Keep <> 0;
end;

function XenoRaiseVolumeRamp(Buffer: Pointer; IntervalMs: Cardinal; Step: Single): Single;
var
  Event: TXenoFpcVolumeRampEvent;
begin
  Result := Step;
  if not XenoHasSubscribers(xeSoundVolumeRamp) then
    Exit;
  Event.Size := SizeOf(Event);
  Event.Buffer := Buffer;
  Event.IntervalMs := IntervalMs;
  Event.Step := Step;
  XenoRaise(xeSoundVolumeRamp, Event);
  Result := Event.Step;
end;

finalization
  FieldNames.Free;
  ClassNames.Free;
{$ENDIF}
end.
