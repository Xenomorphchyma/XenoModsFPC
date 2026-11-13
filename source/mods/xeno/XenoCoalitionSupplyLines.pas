unit XenoCoalitionSupplyLines;

{$I GameOptions.inc}

// Port of XenoCoalitionSupplyLines.XenoPlugin.dll 1.0.83. The DLL only exposed
// the editable convoy composition from Native\XenoCoalitionSupplyLines.XenoPlugin.ini
// to the mod's RScript through ImportedFunction; the script logic is unchanged.
interface

{$IFDEF XENO_MODS}
procedure RegisterXenoCoalitionSupplyLines;
{$ENDIF}

implementation

{$IFDEF XENO_MODS}
uses
  SysUtils,
  EC_Expression,
  NativeScriptLibrary,
  XenoModsHost;

const
  ModName = 'XenoCoalitionSupplyLines';
  IniPath = 'Native\XenoCoalitionSupplyLines.XenoPlugin.ini';

type
  TBandConfig = record
    TransportMin, TransportMax, EscortMin, EscortMax, CargoMin, CargoMax, ProductionBatch: Integer;
  end;

const
  DefaultBands: array[0..6] of TBandConfig = (
      (TransportMin: 4; TransportMax: 6; EscortMin: 5; EscortMax: 6; CargoMin: 4; CargoMax: 5; ProductionBatch: 4),
      (TransportMin: 3; TransportMax: 5; EscortMin: 4; EscortMax: 6; CargoMin: 3; CargoMax: 5; ProductionBatch: 3),
      (TransportMin: 2; TransportMax: 4; EscortMin: 4; EscortMax: 5; CargoMin: 3; CargoMax: 4; ProductionBatch: 2),
      (TransportMin: 2; TransportMax: 3; EscortMin: 4; EscortMax: 4; CargoMin: 2; CargoMax: 4; ProductionBatch: 2),
      (TransportMin: 2; TransportMax: 3; EscortMin: 3; EscortMax: 4; CargoMin: 2; CargoMax: 3; ProductionBatch: 1),
      (TransportMin: 2; TransportMax: 3; EscortMin: 2; EscortMax: 2; CargoMin: 2; CargoMax: 3; ProductionBatch: 1),
      (TransportMin: 2; TransportMax: 2; EscortMin: 0; EscortMax: 0; CargoMin: 2; CargoMax: 3; ProductionBatch: 1));
  BandSections: array[0..6] of WideString = (
      'Band80To100', 'Band60To79', 'Band40To59', 'Band20To39', 'Band11To19', 'BandBelow11', 'CrisisBelow3Systems');

var
  ConfigGeneration: Cardinal = 0;
  Ready: Boolean = False;
  Bands: array[0..6] of TBandConfig;
  CargoPerEnhancedShip, RemainderCreatesSimpleShip, ShipsPerDeliveredEscort, MaximumStrikeShips, MaxConcurrentConvoys: Integer;

procedure LoadConfig;
var
  Generation: Cardinal;
  Ini: TXenoIni;
  I: Integer;

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
    for I := 0 to High(Bands) do
    begin
      Bands[I] := DefaultBands[I];
      with Bands[I] do
      begin
        TransportMin := ReadInt(BandSections[I], 'TransportMin', TransportMin, 1, 6);
        TransportMax := ReadInt(BandSections[I], 'TransportMax', TransportMax, 1, 6);
        EscortMin := ReadInt(BandSections[I], 'EscortMin', EscortMin, 0, 6);
        EscortMax := ReadInt(BandSections[I], 'EscortMax', EscortMax, 0, 6);
        CargoMin := ReadInt(BandSections[I], 'CargoPerTransportMin', CargoMin, 1, 5);
        CargoMax := ReadInt(BandSections[I], 'CargoPerTransportMax', CargoMax, 1, 5);
        ProductionBatch := ReadInt(BandSections[I], 'ProductionBatch', ProductionBatch, 1, 4);
        if TransportMax < TransportMin then
          TransportMax := TransportMin;
        if EscortMax < EscortMin then
          EscortMax := EscortMin;
        if CargoMax < CargoMin then
          CargoMax := CargoMin;
      end;
    end;
    CargoPerEnhancedShip := ReadInt('StrikeGroup', 'CargoPerEnhancedShip', 2, 1, 10);
    RemainderCreatesSimpleShip := ReadInt('StrikeGroup', 'RemainderCreatesSimpleShip', 1, 0, 1);
    ShipsPerDeliveredEscort := ReadInt('StrikeGroup', 'ShipsPerDeliveredEscort', 1, 0, 3);
    MaximumStrikeShips := ReadInt('StrikeGroup', 'MaximumShips', 21, 1, 21);
    MaxConcurrentConvoys := ReadInt('General', 'MaxConcurrentConvoys', 3, 1, 3);
  finally
    Ini.Free;
  end;
  XenoLog(ModName, 'config=loaded max_strike=' + IntToStr(MaximumStrikeShips) + ' cargo_per_ship=' + IntToStr(CargoPerEnhancedShip)
      + ' top_batch=' + IntToStr(Bands[0].ProductionBatch) + ' crisis_batch=' + IntToStr(Bands[6].ProductionBatch)
      + ' max_convoys=' + IntToStr(MaxConcurrentConvoys));
end;

function BandValue(const Band: TBandConfig; Field: Integer): Integer;
begin
  case Field of
    1: Result := Band.TransportMin;
    2: Result := Band.TransportMax;
    3: Result := Band.EscortMin;
    4: Result := Band.EscortMax;
    5: Result := Band.CargoMin;
    6: Result := Band.CargoMax;
    7: Result := Band.ProductionBatch;
  else
    Result := -1;
  end;
end;

function GetConfigInt(Key: Integer): Integer;
var
  Band: Integer;
begin
  LoadConfig;
  if not Ready then
    Exit(-1);
  if (Key >= 11) and (Key <= 77) then
  begin
    Band := Key div 10;
    if (Band >= 1) and (Band <= 7) then
      Exit(BandValue(Bands[Band - 1], Key - Band * 10));
  end;
  case Key of
    101: Result := CargoPerEnhancedShip;
    102: Result := RemainderCreatesSimpleShip;
    103: Result := ShipsPerDeliveredEscort;
    104: Result := MaximumStrikeShips;
    105: Result := MaxConcurrentConvoys;
  else
    Result := -1;
  end;
end;

procedure SF_GetConfigInt(av: array of TVarEC; Code: TCodeEC);
begin
  av[0].SetInt(GetConfigInt(av[1].GetInt));
end;

procedure RegisterXenoCoalitionSupplyLines;
begin
  RegisterNativeScriptFunction('XenoCoalitionSupplyLines.XenoPlugin', 'int,XenoCoalitionSupplyLines_GetConfigInt,int', @SF_GetConfigInt);
end;

initialization
  RegisterXenoCoalitionSupplyLines;
{$ENDIF}
end.
