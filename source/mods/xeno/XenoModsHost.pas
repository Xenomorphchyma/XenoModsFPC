unit XenoModsHost;

{$I GameOptions.inc}

// Host services shared by the XenoMods ports. On the Delphi game these came
// from XenoNativeLoader (XenoCore.dll): active-mod detection from
// Mods\ModCFG.txt, per-plugin INI files and XenoNative.log. Here the native
// code is part of the executable, so a mod is "loaded" simply when its folder
// is selected; switching mods needs no process restart.
interface

{$IFDEF XENO_MODS}
type
  TXenoIni = class
  private
    Names, Values: array of WideString;
    FLoaded: Boolean;
    function IndexOf(const Section, Key: WideString): Integer;
  public
    constructor Create(const GameRelativePath: WideString);
    function Loaded: Boolean;
    function HasKey(const Section, Key: WideString): Boolean;
    function ReadString(const Section, Key, Default: WideString): WideString;
    // Same contract as XenoNativeLoader's configGetInt: a missing or
    // non-numeric value yields Default, a numeric one is clamped.
    function ReadInt(const Section, Key: WideString; Default, Minimum, Maximum: Integer): Integer;
  end;

// Game-relative folder of a selected mod, e.g. 'Mods\XenoMods\XenoHangarPaging\',
// matched by its last path component. Empty when the mod is not active.
function XenoModFolder(const ModName: WideString): WideString;
function XenoModActive(const ModName: WideString): Boolean;
// Changes whenever the selected mod set changes; mods use it to drop caches.
function XenoModsGeneration: Cardinal;
// Opens an INI below the mod folder; nil when the mod or file is missing.
function XenoOpenModIni(const ModName, RelativePath: WideString): TXenoIni;
// True when the mod is active and its INI does not say [Plugin] Enabled=0.
function XenoPluginEnabled(const ModName, IniRelativePath: WideString): Boolean;
procedure XenoLog(const ModName, Text: WideString);
procedure XenoLogWarning(const ModName, Text: WideString);
// XenoModsFPC installs into a subfolder of the game (the original game keeps
// its own okgf.dll next to Rangers.exe). Without --game-dir, use the folder
// that holds CFG\Main.dat: the working directory, the executable's folder or
// its parent.
procedure XenoSelectGameDirectory;
// --xeno-selftest runs unattended: a hidden window that does not take the
// focus and a silent audio device (the music still plays through the mixer,
// so its tests keep working). Call before the window and audio are opened.
procedure XenoPrepareSelfTestRun;
{$ENDIF}

implementation

{$IFDEF XENO_MODS}
uses
  Classes,
  SysUtils,
  GameDiagnostics,
  GameSystem,
  GameWindow,
  SDL2,
  EC_Str,
  GR_Main;

type
  TModEntry = record
    Key, Folder: WideString;
  end;

var
  CacheLock: TRTLCriticalSection;
  CachedSelection: WideString;
  CachedSkip: Boolean;
  CacheValid: Boolean;
  CachedEntries: array of TModEntry;
  Generation: Cardinal = 1;

function LastPathComponent(const Path: WideString): WideString;
var
  I: Integer;
begin
  I := Length(Path);
  while (I > 0) and (Path[I] <> '\') and (Path[I] <> '/') do
    Dec(I);
  Result := Copy(Path, I + 1, MaxInt);
end;

procedure RefreshCache;
var
  I, Count: Integer;
  Entry: WideString;
begin
  if CacheValid and (CachedSkip = SkipModsOnReload) and (CachedSelection = SelectedMods) then
    Exit;
  CachedSelection := SelectedMods;
  CachedSkip := SkipModsOnReload;
  CacheValid := True;
  Inc(Generation);
  SetLength(CachedEntries, 0);
  if CachedSkip then
    Exit;
  Count := CountDelimitedPartsW(CachedSelection, ',');
  for I := 0 to Count - 1 do
  begin
    Entry := TrimWideString(ExtractDelimitedPartW(CachedSelection, I, ','));
    if Entry = '' then
      Continue;
    SetLength(CachedEntries, Length(CachedEntries) + 1);
    CachedEntries[High(CachedEntries)].Key := WideUpperCase(LastPathComponent(Entry));
    CachedEntries[High(CachedEntries)].Folder := 'Mods\' + Entry + '\';
  end;
end;

function XenoModFolder(const ModName: WideString): WideString;
var
  I: Integer;
  Key: WideString;
begin
  Result := '';
  Key := WideUpperCase(ModName);
  EnterCriticalSection(CacheLock);
  try
    RefreshCache;
    for I := 0 to High(CachedEntries) do
      if CachedEntries[I].Key = Key then
        Exit(CachedEntries[I].Folder);
  finally
    LeaveCriticalSection(CacheLock);
  end;
end;

function XenoModActive(const ModName: WideString): Boolean;
begin
  Result := XenoModFolder(ModName) <> '';
end;

function XenoModsGeneration: Cardinal;
begin
  EnterCriticalSection(CacheLock);
  try
    RefreshCache;
    Result := Generation;
  finally
    LeaveCriticalSection(CacheLock);
  end;
end;

function XenoOpenModIni(const ModName, RelativePath: WideString): TXenoIni;
var
  Folder: WideString;
begin
  Result := nil;
  Folder := XenoModFolder(ModName);
  if Folder = '' then
    Exit;
  Result := TXenoIni.Create(Folder + RelativePath);
  if not Result.Loaded then
    FreeAndNil(Result);
end;

function XenoPluginEnabled(const ModName, IniRelativePath: WideString): Boolean;
var
  Ini: TXenoIni;
begin
  Result := XenoModActive(ModName);
  if not Result then
    Exit;
  Ini := XenoOpenModIni(ModName, IniRelativePath);
  if Ini <> nil then
    try
      Result := Ini.ReadInt('Plugin', 'Enabled', 1, 0, 1) <> 0;
    finally
      Ini.Free;
    end;
end;

procedure XenoLog(const ModName, Text: WideString);
begin
  LogGameMessage(gllInfo, 'xeno', ModName + ': ' + Text);
end;

procedure XenoLogWarning(const ModName, Text: WideString);
begin
  LogGameMessage(gllWarning, 'xeno', ModName + ': ' + Text);
end;

procedure XenoSelectGameDirectory;
var
  ExeDir: UnicodeString;

  function IsGameDir(const Dir: UnicodeString): Boolean;
  begin
    Result := FileExists(UTF8Encode(IncludeTrailingPathDelimiter(Dir) + 'CFG' + DirectorySeparator + 'Main.dat'));
  end;

begin
  if IsGameDir(UTF8Decode(GetCurrentDir)) then
    Exit;
  ExeDir := ExcludeTrailingPathDelimiter(UTF8Decode(ExtractFilePath(ExpandFileName(ParamStr(0)))));
  if IsGameDir(ExeDir) then
    SetGameDirectory(ExeDir)
  else if IsGameDir(ExtractFileDir(ExeDir)) then
    SetGameDirectory(ExtractFileDir(ExeDir));
end;

procedure XenoPrepareSelfTestRun;
var
  I: Integer;
  SelfTest, Visible: Boolean;
begin
  SelfTest := False;
  Visible := False;
  for I := 1 to ParamCount do
    if Copy(ParamStr(I), 1, 15) = '--xeno-selftest' then
      SelfTest := True
    else if ParamStr(I) = '--xeno-visible' then
      Visible := True; // watch the run: normal window and sound
  if not SelfTest or Visible then
    Exit;
  GameWindowStartHidden := True;
  // Errors go to rangers-fpc.log and the exit code instead of a dialog.
  GameDialogsSuppressed := True;
  // The message loop idles until the window is activated, which a hidden
  // window never is.
  RuntimeActive := True;
  SDL_SetHint('SDL_AUDIODRIVER', 'dummy');
end;

{ TXenoIni }

function DecodeText(const Bytes: RawByteString): WideString;
var
  Wide: UnicodeString;
begin
  if (Length(Bytes) >= 2) and (Bytes[1] = #$FF) and (Bytes[2] = #$FE) then
  begin
    SetLength(Wide, (Length(Bytes) - 2) div 2);
    if Length(Wide) > 0 then
      Move(Bytes[3], Wide[1], Length(Wide) * 2);
    Exit(Wide);
  end;
  if (Length(Bytes) >= 3) and (Bytes[1] = #$EF) and (Bytes[2] = #$BB) and (Bytes[3] = #$BF) then
    Exit(UTF8Decode(Copy(Bytes, 4, MaxInt)));
  Result := UTF8Decode(Bytes);
end;

constructor TXenoIni.Create(const GameRelativePath: WideString);
var
  Stream: TFileStream;
  Bytes: RawByteString;
  Text, Line, Section: WideString;
  Start, I, Separator: Integer;

  procedure AddLine(const Raw: WideString);
  var
    Value: WideString;
  begin
    Line := TrimWideString(Raw);
    if (Line = '') or (Line[1] = ';') or (Line[1] = '#') then
      Exit;
    if Line[1] = '[' then
    begin
      Separator := Pos(']', Line);
      if Separator > 0 then
        Section := WideUpperCase(TrimWideString(Copy(Line, 2, Separator - 2)));
      Exit;
    end;
    Separator := Pos('=', Line);
    if Separator <= 1 then
      Exit;
    Value := TrimWideString(Copy(Line, Separator + 1, MaxInt));
    SetLength(Names, Length(Names) + 1);
    SetLength(Values, Length(Values) + 1);
    Names[High(Names)] := Section + #0 + WideUpperCase(TrimWideString(Copy(Line, 1, Separator - 1)));
    Values[High(Values)] := Value;
  end;

begin
  inherited Create;
  FLoaded := False;
  if not FileExists(NativeGamePath(GameRelativePath)) then
    Exit;
  try
    Stream := TFileStream.Create(UTF8Encode(NativeGamePath(GameRelativePath)), fmOpenRead or fmShareDenyNone);
    try
      SetLength(Bytes, Stream.Size);
      if Length(Bytes) > 0 then
        Stream.ReadBuffer(Bytes[1], Length(Bytes));
    finally
      Stream.Free;
    end;
  except
    Exit;
  end;
  Text := DecodeText(Bytes);
  Section := '';
  Start := 1;
  for I := 1 to Length(Text) do
    if (Text[I] = #10) or (Text[I] = #13) then
    begin
      AddLine(Copy(Text, Start, I - Start));
      Start := I + 1;
    end;
  AddLine(Copy(Text, Start, MaxInt));
  FLoaded := True;
end;

function TXenoIni.Loaded: Boolean;
begin
  Result := FLoaded;
end;

function TXenoIni.IndexOf(const Section, Key: WideString): Integer;
var
  Name: WideString;
  I: Integer;
begin
  Name := WideUpperCase(Section) + #0 + WideUpperCase(Key);
  // GetPrivateProfile* returns the first matching key; keep that behavior.
  for I := 0 to High(Names) do
    if Names[I] = Name then
      Exit(I);
  Result := -1;
end;

function TXenoIni.HasKey(const Section, Key: WideString): Boolean;
begin
  Result := IndexOf(Section, Key) >= 0;
end;

function TXenoIni.ReadString(const Section, Key, Default: WideString): WideString;
var
  Index: Integer;
begin
  Index := IndexOf(Section, Key);
  if Index < 0 then
    Result := Default
  else
    Result := Values[Index];
end;

function TXenoIni.ReadInt(const Section, Key: WideString; Default, Minimum, Maximum: Integer): Integer;
var
  Text: WideString;
  I: Integer;
  Negative: Boolean;
  Value: Int64;
begin
  Result := Default;
  Text := ReadString(Section, Key, '');
  I := 1;
  Negative := False;
  if (I <= Length(Text)) and ((Text[I] = '-') or (Text[I] = '+')) then
  begin
    Negative := Text[I] = '-';
    Inc(I);
  end;
  if (I > Length(Text)) or (Text[I] < '0') or (Text[I] > '9') then
    Exit;
  Value := 0;
  while (I <= Length(Text)) and (Text[I] >= '0') and (Text[I] <= '9') do
  begin
    if Value < High(Integer) then
      Value := Value * 10 + (Ord(Text[I]) - Ord('0'));
    Inc(I);
  end;
  if Negative then
    Value := -Value;
  if Value < Minimum then
    Value := Minimum;
  if Value > Maximum then
    Value := Maximum;
  Result := Integer(Value);
end;

initialization
  InitCriticalSection(CacheLock);

finalization
  DoneCriticalSection(CacheLock);
{$ENDIF}
end.
