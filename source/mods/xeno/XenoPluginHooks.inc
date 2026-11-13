// Method hooks of the plugin host (included by XenoPluginHost).
//
// xenomods/gen_hooks.py wraps the game's routines at build time; every
// wrapper checks its slot and, when a plugin hooked it, calls HookEnter and
// HookLeave (through XenoHookRuntime) around the original body. Here the host
// keeps the handler lists, orders them and reports conflicts.
//
// Order: "before" handlers run by priority (lower first), then by plugin load
// order; "after" handlers run in the reverse order, so every plugin wraps the
// plugins after it. Handler lists are immutable: a change publishes a new list
// and keeps the old one alive, so worker threads inside a call never see a
// list being freed.

{$PACKRECORDS C}
type
  TXenoFpcHookInfo = record
    Size: Cardinal;
    Id: Integer;
    Name, UnitName, ClassName, MethodName, Parameters, ResultType: PAnsiChar;
    Kind, Flags, ResultSize, ArgumentCount: Integer;
    Arguments: PXenoHkArg;
  end;
  PXenoFpcHookInfo = ^TXenoFpcHookInfo;
  PPXenoFpcHookInfo = ^PXenoFpcHookInfo;
{$PACKRECORDS DEFAULT}

  THookHandler = record
    Callback: TXenoFpcHookFn;
    User: Pointer;
    Owner: TPlugin;
    Phase, Priority, Order: Integer;
    Handle: PtrInt;
    Overrides: Boolean;
  end;

  THandlerList = class
    Before, After: array of THookHandler;
    MultiOwner: Boolean;
  end;

  THookEntry = class
    Desc: PXenoHkDesc;
    Info: TXenoFpcHookInfo;
    FullName, TypeKey: AnsiString;
    Handlers: array of THookHandler;
    Current: THandlerList;
  end;

const
  HookPhaseBefore = 0;
  HookPhaseAfter = 1;
  HookFlagOverrides = 1;
  BuiltinOwnerName: PAnsiChar = 'built-in';

var
  HookEntries: array of THookEntry;
  HookNames: TStringList = nil;   // lower-case keys -> entry index
  HookedEntries: TList = nil;     // entries that have handlers
  RetiredLists: TList = nil;
  HookLogged: TStringList = nil;  // conflicts and failures already reported
  NextHookHandle: PtrInt = 0;
  NextHookOrder: Integer = 0;

threadvar
  CurrentHookCall: PXenoHkCall;

function HookEnter(var Call: TXenoHkCall): Boolean; forward;
procedure HookLeave(var Call: TXenoHkCall); forward;

{$IFDEF MSWINDOWS}
function GetModuleHandleExW(Flags: Cardinal; Address: Pointer; out Module: PtrUInt): LongBool; stdcall;
    external 'kernel32.dll';
{$ENDIF}

function TypeKeyOf(const Text: AnsiString): AnsiString;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(Text) do
    if not (Text[I] in [' ', #9]) then
      Result := Result + LowerCase(Text[I]);
end;

procedure EnsureHooks;
var
  I, J, Count: Integer;
  Desc: PXenoHkDesc;
  Entry: THookEntry;
  Types: AnsiString;
  Args: PXenoHkArg;

  procedure AddKey(const Key: AnsiString);
  begin
    HookNames.AddObject(LowerCase(Key), TObject(PtrInt(I)));
  end;

begin
  if HookNames <> nil then
    Exit;
  HookNames := TStringList.Create;
  HookNames.Duplicates := dupAccept;
  HookNames.Sorted := True;
  HookedEntries := TList.Create;
  RetiredLists := TList.Create;
  HookLogged := TStringList.Create;
  HookLogged.Sorted := True;
  Count := XenoHookCount;
  SetLength(HookEntries, Count);
  for I := 0 to Count - 1 do
  begin
    Desc := XenoHookAt(I);
    Entry := THookEntry.Create;
    Entry.Desc := Desc;
    if Desc^.ClassName^ <> #0 then
      Entry.FullName := AnsiString(Desc^.ClassName) + '.' + AnsiString(Desc^.MethodName)
    else
      Entry.FullName := AnsiString(Desc^.UnitName) + '.' + AnsiString(Desc^.MethodName);
    Types := '';
    Args := Desc^.Args;
    for J := 0 to Desc^.ArgCount - 1 do
    begin
      if J > 0 then
        Types := Types + ',';
      Types := Types + TypeKeyOf(AnsiString(Args^.TypeName));
      Inc(Args);
    end;
    Entry.TypeKey := Types;
    with Entry.Info do
    begin
      Size := SizeOf(TXenoFpcHookInfo);
      Id := I;
      Name := PAnsiChar(Entry.FullName);
      UnitName := Desc^.UnitName;
      ClassName := Desc^.ClassName;
      MethodName := Desc^.MethodName;
      Parameters := Desc^.Params;
      ResultType := Desc^.ResultType;
      Kind := Desc^.Kind;
      Flags := Desc^.Flags;
      ResultSize := Desc^.ResultSize;
      ArgumentCount := Desc^.ArgCount;
      Arguments := Desc^.Args;
    end;
    HookEntries[I] := Entry;
    AddKey(Entry.FullName);
    AddKey(AnsiString(Desc^.UnitName) + '.' + Entry.FullName);
  end;
  XenoHookEnterProc := @HookEnter;
  XenoHookLeaveProc := @HookLeave;
end;

// "TShip.Foo", "aShip.TShip.Foo", "aShip.Foo", optionally "...(Integer, Boolean)".
function FindHooks(const Name: AnsiString; Found: PPXenoFpcHookInfo; MaxFound: Integer): Integer;
var
  Base, Types: AnsiString;
  P, Index: Integer;
  Entry: THookEntry;
begin
  EnsureHooks;
  Result := 0;
  P := Pos('(', Name);
  if P > 0 then
  begin
    Base := Trim(Copy(Name, 1, P - 1));
    Types := TypeKeyOf(Copy(Name, P + 1, Length(Name)));
    if (Types <> '') and (Types[Length(Types)] = ')') then
      SetLength(Types, Length(Types) - 1);
  end
  else
    Base := Trim(Name);
  Base := LowerCase(Base);
  if not HookNames.Find(Base, Index) then
    Exit;
  while (Index < HookNames.Count) and (HookNames[Index] = Base) do
  begin
    Entry := HookEntries[PtrInt(HookNames.Objects[Index])];
    if (P = 0) or (Entry.TypeKey = Types) then
    begin
      if (Found <> nil) and (Result < MaxFound) then
        PPXenoFpcHookInfo(PAnsiChar(Found) + Result * SizeOf(Pointer))^ := @Entry.Info;
      Inc(Result);
    end;
    Inc(Index);
  end;
end;

function HookOwnerOf(Callback: Pointer): TPlugin;
{$IFDEF MSWINDOWS}
const
  FromAddress = 4;
  UnchangedRefcount = 2;
var
  Module: PtrUInt;
  I: Integer;
{$ENDIF}
begin
  Result := CurrentPlugin;
  if (Result <> nil) or (Plugins = nil) then
    Exit;
{$IFDEF MSWINDOWS}
  if GetModuleHandleExW(FromAddress or UnchangedRefcount, Callback, Module) then
    for I := 0 to Plugins.Count - 1 do
      if PtrUInt(TPlugin(Plugins[I]).Handle) = Module then
        Exit(TPlugin(Plugins[I]));
{$ENDIF}
end;

function OwnerId(Owner: TPlugin): PAnsiChar;
begin
  if Owner = nil then
    Result := BuiltinOwnerName
  else
    Result := PAnsiChar(Owner.PluginId);
end;

function OwnerKey(Owner: TPlugin): Pointer;
begin
  // Built-in handlers share one key different from every plugin.
  if Owner = nil then
    Result := BuiltinOwnerName
  else
    Result := Owner;
end;

procedure LogHookOnce(const Key: AnsiString; Level: TGameLogLevel; const Text: WideString);
var
  Index: Integer;
begin
  if HookLogged.Find(Key, Index) then
    Exit;
  HookLogged.Add(Key);
  LogGameMessage(Level, 'xeno', Text);
end;

procedure PublishHandlers(Entry: THookEntry);
var
  List: THandlerList;
  Sorted: array of THookHandler;
  I, J, NB, NA: Integer;
  Swap: THookHandler;
  FirstOwner: TPlugin;
begin
  Sorted := Copy(Entry.Handlers);
  // Insertion sort by priority, then load order: lists are short.
  for I := 1 to High(Sorted) do
  begin
    Swap := Sorted[I];
    J := I - 1;
    while (J >= 0) and ((Sorted[J].Priority > Swap.Priority)
        or ((Sorted[J].Priority = Swap.Priority) and (Sorted[J].Order > Swap.Order))) do
    begin
      Sorted[J + 1] := Sorted[J];
      Dec(J);
    end;
    Sorted[J + 1] := Swap;
  end;
  List := THandlerList.Create;
  SetLength(List.Before, Length(Sorted));
  SetLength(List.After, Length(Sorted));
  NB := 0;
  NA := 0;
  for I := 0 to High(Sorted) do
    if Sorted[I].Phase = HookPhaseBefore then
    begin
      List.Before[NB] := Sorted[I];
      Inc(NB);
    end;
  for I := High(Sorted) downto 0 do
    if Sorted[I].Phase = HookPhaseAfter then
    begin
      List.After[NA] := Sorted[I];
      Inc(NA);
    end;
  SetLength(List.Before, NB);
  SetLength(List.After, NA);
  if Length(Sorted) > 0 then
  begin
    FirstOwner := Sorted[0].Owner;
    for I := 1 to High(Sorted) do
      if Sorted[I].Owner <> FirstOwner then
        List.MultiOwner := True;
  end;
  if Entry.Current <> nil then
    RetiredLists.Add(Entry.Current);
  Entry.Current := List;
  if Length(Sorted) > 0 then
  begin
    if HookedEntries.IndexOf(Entry) < 0 then
      HookedEntries.Add(Entry);
    Entry.Desc^.Slot^ := Entry;
  end
  else
  begin
    Entry.Desc^.Slot^ := nil;
    HookedEntries.Remove(Entry);
  end;
end;

function ClassByName(const Name: AnsiString): TClass;
var
  I, Index: Integer;
begin
  for I := 0 to High(HookEntries) do
    if (HookEntries[I].Desc^.ClassRef <> nil) and SameText(AnsiString(HookEntries[I].Desc^.ClassName), Name) then
      Exit(HookEntries[I].Desc^.ClassRef);
  EnsureFieldMap;
  if ClassNames.Find(LowerCase(Name), Index) then
    Exit(TClass(ClassNames.Objects[Index]));
  Result := nil;
end;

procedure AddHandlerTo(Entry: THookEntry; const Handler: THookHandler);
var
  N: Integer;
begin
  N := Length(Entry.Handlers);
  SetLength(Entry.Handlers, N + 1);
  Entry.Handlers[N] := Handler;
  PublishHandlers(Entry);
end;

// Adds a handler to one routine, or with HookFlagOverrides to MethodName of
// BaseClass and of every class derived from it (BaseClass may be abstract).
function AddHook(Target: THookEntry; BaseClass: TClass; const MethodName, TypeKey: AnsiString; Phase, Flags,
    Priority: Integer; Callback: TXenoFpcHookFn; User: Pointer): PtrInt;
var
  Handler: THookHandler;
  I, Count: Integer;
  Entry: THookEntry;
begin
  Result := 0;
  if not Assigned(Callback) or not (Phase in [HookPhaseBefore, HookPhaseAfter]) then
    Exit;
  Inc(NextHookHandle);
  Inc(NextHookOrder);
  Handler.Callback := Callback;
  Handler.User := User;
  Handler.Owner := HookOwnerOf(@Callback);
  Handler.Phase := Phase;
  Handler.Priority := Priority;
  if Handler.Owner <> nil then
    Handler.Order := Plugins.IndexOf(Handler.Owner) * 1000000 + NextHookOrder
  else
    Handler.Order := -1000000 + NextHookOrder;
  Handler.Handle := NextHookHandle;
  Handler.Overrides := (Flags and HookFlagOverrides) <> 0;
  Count := 0;
  if Handler.Overrides and (BaseClass <> nil) then
  begin
    for I := 0 to High(HookEntries) do
    begin
      Entry := HookEntries[I];
      if (Entry.Desc^.ClassRef <> nil) and Entry.Desc^.ClassRef.InheritsFrom(BaseClass)
          and SameText(AnsiString(Entry.Desc^.MethodName), MethodName)
          and ((TypeKey = #0) or (Entry.TypeKey = TypeKey)) then
      begin
        AddHandlerTo(Entry, Handler);
        Inc(Count);
      end;
    end;
  end
  else if Target <> nil then
  begin
    AddHandlerTo(Target, Handler);
    Count := 1;
  end;
  if Count > 0 then
    Result := Handler.Handle;
end;

procedure RemoveHandlers(Handle: PtrInt; Owner: TPlugin; ByOwner: Boolean);
var
  I, J, N: Integer;
  Entry: THookEntry;
  Kept: array of THookHandler;
begin
  if HookedEntries = nil then
    Exit;
  for I := HookedEntries.Count - 1 downto 0 do
  begin
    Entry := THookEntry(HookedEntries[I]);
    SetLength(Kept, Length(Entry.Handlers));
    N := 0;
    for J := 0 to High(Entry.Handlers) do
      if not ((ByOwner and (Entry.Handlers[J].Owner = Owner)) or (not ByOwner and (Entry.Handlers[J].Handle = Handle))) then
      begin
        Kept[N] := Entry.Handlers[J];
        Inc(N);
      end;
    if N <> Length(Entry.Handlers) then
    begin
      SetLength(Kept, N);
      Entry.Handlers := Copy(Kept);
      PublishHandlers(Entry);
    end;
  end;
end;

// True when an outer call on the same object already ran this handler (a
// derived override calling the inherited one): HookFlagOverrides reports a
// call once.
function HandledOutside(var Call: TXenoHkCall; Handle: PtrInt): Boolean;
var
  Outer: PXenoHkCall;
  List: THandlerList;
  I: Integer;
begin
  Result := False;
  Outer := Call.Outer;
  while Outer <> nil do
  begin
    if Outer^.Self_ = Call.Self_ then
    begin
      List := THandlerList(Outer^.Handlers);
      for I := 0 to High(List.Before) do
        if List.Before[I].Handle = Handle then
          Exit(True);
      for I := 0 to High(List.After) do
        if List.After[I].Handle = Handle then
          Exit(True);
    end;
    Outer := Outer^.Outer;
  end;
end;

procedure RunHandler(var Call: TXenoHkCall; const Handler: THookHandler; Track: Boolean);
var
  Before: array[0..15] of Byte;
  Size: Integer;
  Entry: THookEntry;
begin
  Entry := THookEntry(Call.Entry);
  Size := Call.Desc^.ResultSize;
  Track := Track and (Call.Result_ <> nil) and (Size > 0) and (Size <= SizeOf(Before));
  if Track then
    Move(Call.Result_^, Before, Size);
  try
    Handler.Callback(Handler.User, @Call);
  except
    LogCurrentGameException('xeno', OwnerName(Handler.Owner) + ' failed in hook ' + WideString(Entry.FullName), gllError);
  end;
  if Track and not CompareMem(@Before, Call.Result_, Size) then
  begin
    if (Call.Changer <> nil) and (Call.Changer <> OwnerKey(Handler.Owner)) then
      LogHookOnce('chain ' + Entry.FullName + ' ' + AnsiString(OwnerId(Handler.Owner)), gllInfo,
          WideString(Entry.FullName) + ': result changed by several mods; the last one is '
          + OwnerName(Handler.Owner));
    Call.Changer := OwnerKey(Handler.Owner);
  end;
end;

function HookEnter(var Call: TXenoHkCall): Boolean;
var
  Entry: THookEntry;
  List: THandlerList;
  I: Integer;
begin
  Entry := THookEntry(Call.Desc^.Slot^);
  if Entry = nil then
    Exit(True);
  List := Entry.Current;
  Call.Size := PtrUInt(@PXenoHkCall(nil)^.Desc);
  Call.Info := @Entry.Info;
  Call.Entry := Entry;
  Call.Handlers := List;
  Call.Outer := CurrentHookCall;
  CurrentHookCall := @Call;
  for I := 0 to High(List.Before) do
  begin
    if List.Before[I].Overrides and HandledOutside(Call, List.Before[I].Handle) then
      Continue;
    Call.SkipOriginal := 0;
    RunHandler(Call, List.Before[I], List.MultiOwner);
    if Call.SkipOriginal <> 0 then
      if Call.Replacer = nil then
      begin
        Call.Replacer := OwnerKey(List.Before[I].Owner);
        Call.ReplacedBy := OwnerId(List.Before[I].Owner);
      end
      else if Call.Replacer <> OwnerKey(List.Before[I].Owner) then
        LogHookOnce('replace ' + Entry.FullName + ' ' + AnsiString(OwnerId(List.Before[I].Owner)), gllWarning,
            WideString(Entry.FullName) + ': ' + OwnerName(List.Before[I].Owner) + ' also tried to replace it, '
            + 'but ' + WideString(AnsiString(Call.ReplacedBy)) + ' already did');
  end;
  Call.SkipOriginal := Ord(Call.Replacer <> nil);
  Result := Call.SkipOriginal = 0;
end;

procedure HookLeave(var Call: TXenoHkCall);
var
  List: THandlerList;
  I: Integer;
begin
  List := THandlerList(Call.Handlers);
  if (Call.OriginalRan <> 0) or (Call.Replacer <> nil) then
    for I := 0 to High(List.After) do
    begin
      if List.After[I].Overrides and HandledOutside(Call, List.After[I].Handle) then
        Continue;
      RunHandler(Call, List.After[I], List.MultiOwner);
    end;
  CurrentHookCall := Call.Outer;
end;

procedure ShutdownHooks;
var
  I: Integer;
begin
  if HookNames = nil then
    Exit;
  for I := 0 to High(HookEntries) do
    HookEntries[I].Desc^.Slot^ := nil;
  for I := 0 to RetiredLists.Count - 1 do
    TObject(RetiredLists[I]).Free;
  RetiredLists.Clear;
end;

{ Pascal side (self-test, built-in mods) }

function ResolveHook(const Name: AnsiString; Flags: Integer; out Entry: THookEntry; out BaseClass: TClass;
    out MethodName, TypeKey: AnsiString): Boolean;
var
  Found: array[0..7] of PXenoFpcHookInfo;
  Count, P, Dot: Integer;
  Base: AnsiString;
begin
  Entry := nil;
  BaseClass := nil;
  TypeKey := #0;
  Count := FindHooks(Name, @Found[0], Length(Found));
  if Count = 1 then
    Entry := HookEntries[Found[0]^.Id];
  if (Flags and HookFlagOverrides) <> 0 then
  begin
    // The base method may be abstract and have no entry of its own.
    Base := Name;
    P := Pos('(', Base);
    if P > 0 then
    begin
      TypeKey := TypeKeyOf(Copy(Base, P + 1, Length(Base)));
      if (TypeKey <> '') and (TypeKey[Length(TypeKey)] = ')') then
        SetLength(TypeKey, Length(TypeKey) - 1);
      Base := Copy(Base, 1, P - 1);
    end;
    Base := Trim(Base);
    Dot := LastDelimiter('.', Base);
    MethodName := Copy(Base, Dot + 1, Length(Base));
    Base := Copy(Base, 1, Dot - 1);
    if LastDelimiter('.', Base) > 0 then
      Base := Copy(Base, LastDelimiter('.', Base) + 1, Length(Base));
    BaseClass := ClassByName(Base);
    Exit(BaseClass <> nil);
  end;
  if Count = 0 then
    LogGameMessage(gllWarning, 'xeno', 'Unknown hook: ' + WideString(Name))
  else if Count > 1 then
    LogGameMessage(gllWarning, 'xeno', 'Ambiguous hook ' + WideString(Name) + ': ' + IntToStr(Count)
        + ' overloads; add the parameter types, e.g. "' + WideString(HookEntries[Found[0]^.Id].FullName) + '('
        + WideString(AnsiString(Found[0]^.Parameters)) + ')"');
  Result := Count = 1;
end;

function XenoHookAdd(const Name: AnsiString; Phase, Flags, Priority: Integer; Callback: TXenoFpcHookFn;
    User: Pointer): PtrInt;
var
  Entry: THookEntry;
  BaseClass: TClass;
  MethodName, TypeKey: AnsiString;
begin
  EnsureHooks;
  Result := 0;
  if ResolveHook(Name, Flags, Entry, BaseClass, MethodName, TypeKey) then
    Result := AddHook(Entry, BaseClass, MethodName, TypeKey, Phase, Flags, Priority, Callback, User);
  if Result = 0 then
    LogGameMessage(gllWarning, 'xeno', 'Hook not installed: ' + WideString(Name));
end;

procedure XenoHookRemove(Handle: PtrInt);
begin
  if Handle <> 0 then
    RemoveHandlers(Handle, nil, False);
end;

function XenoHookInfo(const Name: AnsiString): Pointer;
var
  Found: PXenoFpcHookInfo;
begin
  if FindHooks(Name, @Found, 1) = 1 then
    Result := Found
  else
    Result := nil;
end;

function XenoHookInvoke(Info: Pointer; Self_: Pointer; Args: PPointer; Result_: Pointer): Boolean;
var
  Desc: PXenoHkDesc;
begin
  Result := False;
  if Info = nil then
    Exit;
  EnsureHooks;
  Desc := HookEntries[PXenoFpcHookInfo(Info)^.Id].Desc;
  if not Assigned(Desc^.Invoke) then
    Exit;
  try
    Desc^.Invoke(Self_, PXenoHkArgs(Args), Result_);
    Result := True;
  except
    LogCurrentGameException('xeno', 'Invoke failed: ' + WideString(HookEntries[PXenoFpcHookInfo(Info)^.Id].FullName),
        gllError);
  end;
end;

var
  TestOwners: TList = nil;

procedure XenoHookTestOwner(const Id: AnsiString);
var
  I: Integer;
  Owner: TPlugin;
begin
  CurrentPlugin := nil;
  if Id = '' then
    Exit;
  if TestOwners = nil then
    TestOwners := TList.Create;
  for I := 0 to TestOwners.Count - 1 do
    if TPlugin(TestOwners[I]).PluginId = Id then
      CurrentPlugin := TPlugin(TestOwners[I]);
  if CurrentPlugin = nil then
  begin
    Owner := TPlugin.Create;
    Owner.PluginId := Id;
    TestOwners.Add(Owner);
    CurrentPlugin := Owner;
  end;
end;

{ C API }

function Host_HookCount: Integer; cdecl;
begin
  EnsureHooks;
  Result := Length(HookEntries);
end;

function Host_HookInfoAt(Index: Integer): Pointer; cdecl;
begin
  EnsureHooks;
  if (Index >= 0) and (Index <= High(HookEntries)) then
    Result := @HookEntries[Index].Info
  else
    Result := nil;
end;

function Host_HookFind(Name: PAnsiChar; Found: Pointer; MaxFound: Integer): Integer; cdecl;
begin
  Result := FindHooks(AnsiString(Name), PPXenoFpcHookInfo(Found), MaxFound);
end;

function Host_HookAdd(Info: Pointer; Phase, Flags, Priority: Integer; Callback: TXenoFpcHookFn; User: Pointer): PtrInt;
    cdecl;
var
  Entry: THookEntry;
begin
  EnsureHooks;
  Result := 0;
  if Info = nil then
    Exit;
  Entry := HookEntries[PXenoFpcHookInfo(Info)^.Id];
  if (Flags and HookFlagOverrides) <> 0 then
    Result := AddHook(Entry, Entry.Desc^.ClassRef, AnsiString(Entry.Desc^.MethodName), Entry.TypeKey, Phase, Flags,
        Priority, Callback, User)
  else
    Result := AddHook(Entry, nil, '', '', Phase, Flags, Priority, Callback, User);
end;

function Host_Hook(Name: PAnsiChar; Phase, Flags, Priority: Integer; Callback: TXenoFpcHookFn; User: Pointer): PtrInt;
    cdecl;
begin
  Result := XenoHookAdd(AnsiString(Name), Phase, Flags, Priority, Callback, User);
end;

procedure Host_HookRemove(Handle: PtrInt); cdecl;
begin
  XenoHookRemove(Handle);
end;

function Host_Invoke(Info: Pointer; Self_: Pointer; Args: PPointer; Result_: Pointer): Integer; cdecl;
begin
  Result := Ord(XenoHookInvoke(Info, Self_, Args, Result_));
end;

function Host_ValueGetString(Storage: Pointer; TypeName: PAnsiChar; Buffer: PAnsiChar; BufferSize: Integer): Integer;
    cdecl;
var
  Kind: AnsiString;
  Text: UTF8String;
begin
  Result := -1;
  if Storage = nil then
    Exit;
  Kind := LowerCase(AnsiString(TypeName));
  if (Kind = 'widestring') or (Kind = 'unicodestring') then
    Text := Utf8(PWideString(Storage)^)
  else if Kind = 'utf8string' then
    Text := PUTF8String(Storage)^
  else if (Kind = 'string') or (Kind = 'ansistring') or (Kind = 'rawbytestring') then
    Text := Utf8(WideString(PAnsiString(Storage)^))
  else if Kind = 'shortstring' then
    Text := Utf8(WideString(PShortString(Storage)^))
  else if (Kind = 'pwidechar') then
    Text := Utf8(WideString(PPWideChar(Storage)^))
  else if (Kind = 'pansichar') or (Kind = 'pchar') then
    Text := Utf8(WideString(AnsiString(PPAnsiChar(Storage)^)))
  else
    Exit;
  Result := CopyOut(Text, Buffer, BufferSize);
end;

function Host_ValueSetString(Storage: Pointer; TypeName: PAnsiChar; Text: PAnsiChar): Integer; cdecl;
var
  Kind: AnsiString;
begin
  Result := 0;
  if Storage = nil then
    Exit;
  Kind := LowerCase(AnsiString(TypeName));
  if (Kind = 'widestring') then
    PWideString(Storage)^ := FromUtf8(Text)
  else if Kind = 'unicodestring' then
    PUnicodeString(Storage)^ := UnicodeString(FromUtf8(Text))
  else if Kind = 'utf8string' then
    PUTF8String(Storage)^ := UTF8String(Text)
  else if (Kind = 'string') or (Kind = 'ansistring') or (Kind = 'rawbytestring') then
    PAnsiString(Storage)^ := AnsiString(FromUtf8(Text))
  else if Kind = 'shortstring' then
    PShortString(Storage)^ := ShortString(AnsiString(FromUtf8(Text)))
  else
    Exit;
  Result := 1;
end;

function XenoHookInfoAt(Index: Integer): Pointer;
begin
  Result := Host_HookInfoAt(Index);
end;

function XenoHookAddInfo(Info: Pointer; Phase, Flags, Priority: Integer; Callback: TXenoFpcHookFn; User: Pointer): PtrInt;
begin
  Result := Host_HookAdd(Info, Phase, Flags, Priority, Callback, User);
end;
