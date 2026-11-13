unit XenoBuiltinMods;

{$I GameOptions.inc}

// The Xeno mods built into XenoModsFPC. Each unit subscribes to the plugin
// host's events in its initialization, exactly like an external plugin, and
// stays inert until its mod folder is selected.
interface

implementation

{$IFDEF XENO_MODS}
uses
  XenoPluginHost,
  XenoBigGalaxy,
  XenoCoalitionSupplyLines,
  XenoDomRangers,
  XenoEquipmentInflation,
  XenoHangarPaging,
  XenoMusicFlow,
  XenoSelfTest;
{$ENDIF}

end.
