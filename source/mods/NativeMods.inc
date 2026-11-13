// Native DLL replacements are enabled by default. Uncomment either switch
// below to omit that integration, or pass the same symbol with FPC's -d option.
// {$DEFINE DISABLE_UTILITY_FUNCTIONS_PACK}
// {$DEFINE DISABLE_AUTOSEARCH}
// {$DEFINE DISABLE_XENO_MODS}

{$IFNDEF DISABLE_UTILITY_FUNCTIONS_PACK}
  {$DEFINE NATIVE_UTILITY_FUNCTIONS_PACK}
{$ENDIF}
{$IFNDEF DISABLE_AUTOSEARCH}
  {$DEFINE NATIVE_AUTOSEARCH}
{$ENDIF}
// XenoMods: the native parts of the Xenomorphchyma mod set, compiled into the
// game instead of being patched into Rangers.exe by XenoNativeLoader. Each mod
// stays inert until its folder is selected in Mods\ModCFG.txt.
{$IFNDEF DISABLE_XENO_MODS}
  {$DEFINE XENO_MODS}
{$ENDIF}
{$IF Defined(NATIVE_UTILITY_FUNCTIONS_PACK) or Defined(NATIVE_AUTOSEARCH) or Defined(XENO_MODS)}
  {$DEFINE NATIVE_SCRIPT_MODS}
{$ENDIF}
