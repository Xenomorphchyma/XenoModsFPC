unit XenoMusicFlow;

{$I GameOptions.inc}
{$LEGACYPC24 OFF}
{$EXCESSPRECISION OFF}
{$DELPHIORDER OFF}

// Port of XenoMusicFlow.XenoPlugin.dll 1.0.2: the music no longer breaks off
// on landing, docking or takeoff. A place-music switch is deferred while the
// old track goes on; after HoldSeconds the old track either plays to its end
// (when less than EndGraceSeconds remain) or crossfades over CrossfadeSeconds
// into a track of the new place. ImmediateCategories (battles, menus, endings,
// quest soundtracks) switch at once; MusicControl playlists override all.
//
// The Delphi plugin detoured TMusicControl.PlayCategory / StopImmediately /
// RequestFadeOut and TSoundBuffer.StartVolumeRamp and polled with a Win32
// timer. Here GR_Music, GR_Sound, the three place fades and the main message
// pump call the procedures below.
interface

{$IFDEF XENO_MODS}
uses
  GR_Music,
  GR_Sound;

// Start of TMusicControl.PlayCategory. False: the request was deferred or the
// current track already fits, so the stock switch must not run.
function XenoMusicFlowPlayCategory(Control: TMusicControl; const Category: WideString): Boolean;
// Place fades (takeoff after autosave, loading screen). True: keep the track.
function XenoMusicFlowHoldPlaceFade(Control: TMusicControl): Boolean;
procedure XenoMusicFlowStopImmediately(Control: TMusicControl);
// TSoundBuffer.StartVolumeRamp: stretches the ramps of a running crossfade.
function XenoMusicFlowRampStep(Buffer: TSoundBuffer; Interval: Cardinal; Step: Single): Single;
// Main thread, every message pump; rate-limited to 100 ms.
procedure XenoMusicFlowTick;
// For XenoSelfTest (settings from the mod INI or the defaults).
function XenoMusicFlowIsPlaceCategory(const Category: WideString): Boolean;
function XenoMusicFlowDecide(PendingMs: Cardinal; RemainingMs: Int64): Integer;
function XenoMusicFlowEnabled: Boolean;
{$ENDIF}

implementation

{$IFDEF XENO_MODS}
uses
  SysUtils,
  GameSystem,
  GameEvents,
  EC_FileStream,
  EC_Str,
  GR_Main,
  XenoPluginHost,
  XenoModsHost;

const
  ModName = 'XenoMusicFlow';
  IniPath = 'Native\XenoMusicFlow.XenoPlugin.ini';
  DefaultImmediate = 'Battle;Robot;ArcadeBattle;Base;Win;Loss;Song;QuestSoundtrack*;Intro;Introduction;Outro;Logo;1C;Begin;Record;Hyper*;MusicOff';
  DecodeLeadMs = 5000;
  MinimumElapsedMs = 8000;
  TickMs = 100;

type
  TPendingAction = (paWait, paCrossfade, paLetEnd);

  TTrackProgress = record
    Stream, ReadBuffer: Pointer;
    StartMs, NowMs: Cardinal;
    SwappedBytes, Consumed: Int64;
    BufferFill, UnreadBuffered, FileSize: Integer;
    EndOfFile: Boolean;
  end;

var
  ConfigGeneration: Cardinal = 0;
  Enabled: Boolean = False;
  HoldMs: Cardinal = 45000;
  CrossfadeMs: Cardinal = 8000;
  EndGraceMs: Cardinal = 40000;
  ImmediatePatterns: array of WideString;

  InternalCall: Boolean = False;
  OriginDeferrable: Boolean = False;
  Pending: WideString = '';
  PendingSince: Cardinal = 0;
  LetEndLogged: Boolean = False;
  LastTick: Cardinal = 0;
  Progress: TTrackProgress;

  CrossfadeActive: Boolean = False;
  OutUnit, InUnit: TMusicUnit;
  OutBuffer, InBuffer: TSoundBuffer;
  OutSlowed: Boolean = False;
  CrossfadeStarted: Cardinal = 0;

{ Settings }

procedure SetPatterns(const Text: WideString);
var
  I, Count: Integer;
  Part: WideString;
begin
  SetLength(ImmediatePatterns, 0);
  Count := CountDelimitedPartsW(Text, ';,');
  for I := 0 to Count - 1 do
  begin
    Part := TrimWideString(ExtractDelimitedPartW(Text, I, ';,'));
    if Part <> '' then
    begin
      SetLength(ImmediatePatterns, Length(ImmediatePatterns) + 1);
      ImmediatePatterns[High(ImmediatePatterns)] := WideUpperCase(Part);
    end;
  end;
end;

procedure LoadConfig;
var
  Generation: Cardinal;
  Ini: TXenoIni;
begin
  Generation := XenoModsGeneration;
  if Generation = ConfigGeneration then
    Exit;
  ConfigGeneration := Generation;
  Enabled := XenoPluginEnabled(ModName, IniPath);
  HoldMs := 45000;
  CrossfadeMs := 8000;
  EndGraceMs := 40000;
  SetPatterns(DefaultImmediate);
  if not Enabled then
    Exit;
  Ini := XenoOpenModIni(ModName, IniPath);
  if Ini <> nil then
    try
      HoldMs := Cardinal(Ini.ReadInt('MusicFlow', 'HoldSeconds', 45, 0, 600)) * 1000;
      CrossfadeMs := Cardinal(Ini.ReadInt('MusicFlow', 'CrossfadeSeconds', 8, 1, 60)) * 1000;
      EndGraceMs := Cardinal(Ini.ReadInt('MusicFlow', 'EndGraceSeconds', 40, 0, 600)) * 1000;
      SetPatterns(Ini.ReadString('MusicFlow', 'ImmediateCategories', DefaultImmediate));
    finally
      Ini.Free;
    end;
  XenoLog(ModName, 'ready hold_s=' + IntToStr(HoldMs div 1000) + ' crossfade_s=' + IntToStr(CrossfadeMs div 1000)
      + ' end_grace_s=' + IntToStr(EndGraceMs div 1000));
end;

// Case-insensitive; a trailing '*' matches any rest ("Nation.*").
function CategoryMatches(const Category: WideString): Boolean;
var
  Upper, Pattern: WideString;
  I: Integer;
begin
  Upper := WideUpperCase(Category);
  for I := 0 to High(ImmediatePatterns) do
  begin
    Pattern := ImmediatePatterns[I];
    if (Pattern <> '') and (Pattern[Length(Pattern)] = '*') then
    begin
      if Copy(Upper, 1, Length(Pattern) - 1) = Copy(Pattern, 1, Length(Pattern) - 1) then
        Exit(True);
    end
    else if Upper = Pattern then
      Exit(True);
  end;
  Result := False;
end;

// An empty category comes from MusicControl resetting its playlist.
function IsPlaceCategory(const Category: WideString): Boolean;
begin
  Result := (Category <> '') and not CategoryMatches(Category);
end;

{ Track progress: remaining audible time from how far the decoder read the file. }

procedure ObserveProgress(UnitValue: TMusicUnit; NowMs: Cardinal);
var
  Stream: TFileStreamEC;
begin
  Stream := nil;
  if UnitValue <> nil then
    Stream := UnitValue.Stream;
  if Stream = nil then
  begin
    FillChar(Progress, SizeOf(Progress), 0);
    Exit;
  end;
  if Pointer(Stream) <> Progress.Stream then
  begin
    FillChar(Progress, SizeOf(Progress), 0);
    Progress.Stream := Stream;
    Progress.StartMs := NowMs;
    Progress.ReadBuffer := Stream.ReadBuffer;
    Progress.BufferFill := Stream.ReadPosition + Stream.ReadAvailable;
  end
  else if Stream.ReadBuffer <> Progress.ReadBuffer then
  begin
    Inc(Progress.SwappedBytes, Progress.BufferFill);
    Progress.ReadBuffer := Stream.ReadBuffer;
    Progress.BufferFill := Stream.ReadPosition + Stream.ReadAvailable;
  end
  else
    Progress.BufferFill := Stream.ReadPosition + Stream.ReadAvailable;
  Progress.Consumed := Progress.SwappedBytes + Stream.ReadPosition;
  Progress.UnreadBuffered := Stream.ReadAvailable + Stream.FillAvailable;
  Progress.FileSize := Stream.FileSize;
  Progress.EndOfFile := Stream.EndOfFile;
  Progress.NowMs := NowMs;
end;

function RemainingMs: Int64;
var
  Elapsed: Cardinal;
  Rate, Total, Remaining: Double;
begin
  Result := -1;
  if (Progress.Stream = nil) or (Progress.FileSize <= 0) then
    Exit;
  Elapsed := Progress.NowMs - Progress.StartMs;
  if (Elapsed < MinimumElapsedMs) or (Progress.Consumed = 0) then
    Exit;
  Rate := Progress.Consumed * 1000.0 / (Elapsed + DecodeLeadMs);
  if Rate <= 0 then
    Exit;
  if Progress.EndOfFile then
    Exit(Trunc(Progress.UnreadBuffered * 1000.0 / Rate) + DecodeLeadMs);
  Total := Progress.FileSize * 1000.0 / Rate;
  Remaining := Total - Elapsed;
  if Remaining > 0 then
    Result := Trunc(Remaining)
  else
    Result := 0;
end;

function DecidePending(PendingMs: Cardinal; Remaining: Int64): TPendingAction;
begin
  if PendingMs < HoldMs then
    Exit(paWait);
  // An unknown remainder means the track has only just started.
  if (Remaining >= 0) and (Remaining <= Int64(EndGraceMs) + CrossfadeMs) then
    Exit(paLetEnd);
  Result := paCrossfade;
end;

{ Music units }

function UnitRunning(UnitValue: TMusicUnit): Boolean;
begin
  Result := False;
  if UnitValue = nil then
    Exit;
  try
    Result := UnitValue.IsRunning;
  except
    Result := False;
  end;
end;

function UnitFileName(UnitValue: TMusicUnit): WideString;
begin
  Result := '';
  if UnitValue <> nil then
    try
      Result := UnitValue.GetFileName;
    except
      Result := '';
    end;
end;

// ChooseMusicFile returns '' when the file already belongs to the category.
function TrackFitsCategory(const Category, FileName: WideString): Boolean;
begin
  Result := ChooseMusicFile(Category, FileName) = '';
end;

procedure ClearPending;
begin
  Pending := '';
  LetEndLogged := False;
end;

procedure AbortCrossfade(Immediate: Boolean; const Reason: WideString);
begin
  if not CrossfadeActive then
    Exit;
  CrossfadeActive := False;
  if InUnit <> nil then
  begin
    if Immediate then
      InUnit.ImmediateStop := True;
    InUnit.RequestStop;
    SetGameEvent(InUnit.StartPlaybackEvent);
  end;
  // The outgoing track goes on fading at the normal speed.
  if OutSlowed and (OutBuffer <> nil) then
    OutBuffer.VolumeStep := -0.1;
  XenoLog(ModName, 'crossfade aborted: ' + Reason);
end;

procedure StartCrossfade(Control: TMusicControl);
var
  Current, Queued: TMusicUnit;
  FileName: WideString;
  Remaining: Int64;
begin
  Current := Control.Current;
  Queued := Control.Queued;
  if not UnitRunning(Current) or (Queued = nil) or UnitRunning(Queued) then
    Exit;
  FileName := UnitFileName(Current);
  if (FileName = '') or TrackFitsCategory(Pending, FileName) then
  begin
    ClearPending;
    Exit;
  end;
  Remaining := RemainingMs;
  OutUnit := Current;
  InUnit := Queued;
  OutBuffer := Current.Buffer;
  InBuffer := Queued.Buffer;
  OutSlowed := False;
  CrossfadeStarted := GameTickCount;
  CrossfadeActive := True;
  InternalCall := True;
  try
    XenoMusicPlayCategoryOriginal(Pending);
  finally
    InternalCall := False;
  end;
  // PlayFile left the new track waiting for the old one to finish; start it
  // now so both play together.
  if UnitRunning(Queued) then
  begin
    SetGameEvent(Queued.StartPlaybackEvent);
    XenoLog(ModName, 'crossfade to ' + Pending + ' remaining_ms=' + IntToStr(Remaining));
  end
  else
    CrossfadeActive := False;
  OriginDeferrable := True;
  ClearPending;
end;

procedure CheckCrossfadeDone(Control: TMusicControl);
var
  Swapped, Lost, Overdue: Boolean;
begin
  if not CrossfadeActive then
    Exit;
  Swapped := (Control.Current = InUnit) and not UnitRunning(OutUnit);
  Lost := not UnitRunning(InUnit);
  Overdue := GameTickCount - CrossfadeStarted > CrossfadeMs + 10000;
  if Swapped or Lost or Overdue then
    CrossfadeActive := False;
end;

function XenoMusicFlowIsPlaceCategory(const Category: WideString): Boolean;
begin
  LoadConfig;
  Result := IsPlaceCategory(Category);
end;

function XenoMusicFlowDecide(PendingMs: Cardinal; RemainingMs: Int64): Integer;
begin
  LoadConfig;
  Result := Ord(DecidePending(PendingMs, RemainingMs));
end;

function XenoMusicFlowEnabled: Boolean;
begin
  LoadConfig;
  Result := Enabled;
end;

{ Hooks }

function XenoMusicFlowPlayCategory(Control: TMusicControl; const Category: WideString): Boolean;
var
  Playing: TMusicUnit;
  Deferrable, Transition: Boolean;
  FileName: WideString;
begin
  Result := True;
  if InternalCall or (Control = nil) then
    Exit;
  LoadConfig;
  if not Enabled then
    Exit;
  if (Control.Current = nil) or (Control.Queued = nil) then
    Exit; // music disabled in the settings
  if Control.CategoryOverride <> '' then
  begin
    AbortCrossfade(True, 'playlist');
    ClearPending;
    OriginDeferrable := False;
    Exit;
  end;
  Deferrable := IsPlaceCategory(Category);
  if CrossfadeActive then
    Playing := InUnit
  else
    Playing := Control.Current;
  Transition := not CrossfadeActive and UnitRunning(Control.Queued);
  if not Deferrable or not OriginDeferrable or not UnitRunning(Playing) or Transition then
  begin
    AbortCrossfade(True, 'switch');
    ClearPending;
    OriginDeferrable := Deferrable;
    Exit;
  end;
  FileName := UnitFileName(Playing);
  if FileName = '' then
    Exit;
  Result := False;
  if TrackFitsCategory(Category, FileName) then
  begin
    // Back at a place the track fits: cancel the pending switch.
    ClearPending;
    Exit;
  end;
  if Pending = '' then
    PendingSince := GameTickCount;
  Pending := Category;
  LetEndLogged := False;
end;

function XenoMusicFlowHoldPlaceFade(Control: TMusicControl): Boolean;
begin
  Result := False;
  if Control = nil then
    Exit;
  LoadConfig;
  if not Enabled or (Control.CategoryOverride <> '') or not OriginDeferrable or CrossfadeActive
      or not UnitRunning(Control.Current) or UnitRunning(Control.Queued) then
    Exit;
  Result := True;
end;

procedure XenoMusicFlowStopImmediately(Control: TMusicControl);
begin
  AbortCrossfade(True, 'stop_immediately');
  ClearPending;
  OriginDeferrable := False;
end;

function XenoMusicFlowRampStep(Buffer: TSoundBuffer; Interval: Cardinal; Step: Single): Single;
var
  Magnitude: Single;
begin
  Result := Step;
  if not CrossfadeActive or (Buffer = nil) or (Interval = 0) or (CrossfadeMs = 0) then
    Exit;
  Magnitude := Interval / CrossfadeMs;
  if (Buffer = OutBuffer) and (Step < 0) then
  begin
    // A second stop request (MusicControl "next") keeps the normal speed.
    if not OutSlowed then
    begin
      OutSlowed := True;
      Result := -Magnitude;
    end;
  end
  else if (Buffer = InBuffer) and (Step > 0) then
    Result := Magnitude;
end;

procedure XenoMusicFlowTick;
var
  Now: Cardinal;
  Control: TMusicControl;
begin
  Now := GameTickCount;
  if Now - LastTick < TickMs then
    Exit;
  LastTick := Now;
  Control := MusicManager;
  if (Control = nil) or not Enabled or (Control.Current = nil) then
    Exit;
  ObserveProgress(Control.Current, Now);
  CheckCrossfadeDone(Control);
  if (Pending = '') or CrossfadeActive then
    Exit;
  if (Control.CategoryOverride <> '') or not UnitRunning(Control.Current) then
  begin
    // A playlist took over, or the track ended and the stock switch picks
    // the music of the current place.
    ClearPending;
    Exit;
  end;
  case DecidePending(Now - PendingSince, RemainingMs) of
    paWait:
      ;
    paLetEnd:
      if not LetEndLogged then
      begin
        LetEndLogged := True;
        XenoLog(ModName, 'old track ends soon; switching after it');
      end;
    paCrossfade:
      StartCrossfade(Control);
  end;
end;

procedure OnPlayCategory(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcMusicCategoryEvent(Payload^) do
    if (Skip = 0) and (MusicManager <> nil)
        and not XenoMusicFlowPlayCategory(MusicManager, UTF8Decode(UTF8String(Category))) then
      Skip := 1;
end;

procedure OnStopImmediately(User, Payload: Pointer); cdecl;
begin
  XenoMusicFlowStopImmediately(MusicManager);
end;

procedure OnPlaceFade(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcMusicPlaceFadeEvent(Payload^) do
    if (Keep = 0) and XenoMusicFlowHoldPlaceFade(MusicManager) then
      Keep := 1;
end;

procedure OnVolumeRamp(User, Payload: Pointer); cdecl;
begin
  with TXenoFpcVolumeRampEvent(Payload^) do
    Step := XenoMusicFlowRampStep(TSoundBuffer(Buffer), IntervalMs, Step);
end;

procedure OnFrame(User, Payload: Pointer); cdecl;
begin
  XenoMusicFlowTick;
end;

initialization
  XenoSubscribe('Music.PlayCategory', @OnPlayCategory, nil);
  XenoSubscribe('Music.StopImmediately', @OnStopImmediately, nil);
  XenoSubscribe('Music.PlaceFade', @OnPlaceFade, nil);
  XenoSubscribe('Sound.VolumeRamp', @OnVolumeRamp, nil);
  XenoSubscribe('Frame', @OnFrame, nil);
{$ENDIF}
end.
