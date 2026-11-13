unit XenoHookRuntime;

{$I GameOptions.inc}

// Runtime side of the generated method hooks.
//
// At build time xenomods/gen_hooks.py copies the game sources and wraps every
// routine it can: the original body is renamed to <Name>__XB<n>, and the
// original name becomes a small wrapper that runs the body directly while its
// hook slot is empty. When a plugin hooks the routine, the plugin host puts
// its handler list into the slot and the wrapper goes through <Name>__XH<n>,
// which calls XenoHookEnter/XenoHookLeave around the body. Every instrumented
// unit registers one descriptor per routine at initialization.
//
// This unit must not use any game unit: every instrumented unit uses it.

interface

type
  PXenoHkArgs = ^TXenoHkArgs;
  TXenoHkArgs = array[0..255] of Pointer;
  // Calls the routine itself (through its wrapper, so other hooks still run).
  TXenoHkInvoke = procedure(Self_: Pointer; Args: PXenoHkArgs; Result_: Pointer);

{$PACKRECORDS C}
  // Layouts shared with xenomods/sdk/xeno_fpc_plugin_api.h.
  PXenoHkArg = ^TXenoHkArg;
  TXenoHkArg = record
    Name, TypeName: PAnsiChar;
    Mode: Integer;  // 0 value, 1 const, 2 var, 3 out, 4 constref
    Size: Integer;  // 0 for open arrays and untyped parameters
  end;

  PXenoHkDesc = ^TXenoHkDesc;
  TXenoHkDesc = record
    Slot: PPointer;
    UnitName, ClassName, MethodName, Params, ResultType: PAnsiChar;
    Kind: Integer;  // 0 procedure, 1 function, 2 constructor, 3 destructor
    Flags: Integer; // XenoHkClassMethod, ...
    ResultSize, ArgCount: Integer;
    Args: PXenoHkArg;
    Invoke: TXenoHkInvoke;
    ClassRef: TClass;
    Counter: PCardinal; // call counter of profiling builds, else nil
  end;

  PXenoHkCall = ^TXenoHkCall;
  TXenoHkCall = record
    // Public part (XenoFpcCall).
    Size: Cardinal;
    Info: Pointer;
    Self_: Pointer;
    Arguments: PXenoHkArgs;
    Result_: Pointer;
    SkipOriginal: Integer;
    OriginalRan: Integer;
    ReplacedBy: PAnsiChar;
    // Host part.
    Desc: PXenoHkDesc;
    Outer: PXenoHkCall;
    Entry: Pointer;
    Handlers: Pointer;
    Replacer: Pointer;
    Changer: Pointer;
  end;
{$PACKRECORDS DEFAULT}

  TXenoHkEnterProc = function(var Call: TXenoHkCall): Boolean;
  TXenoHkLeaveProc = procedure(var Call: TXenoHkCall);

const
  XenoHkClassMethod = 1;
  XenoHkStatic = 2;
  XenoHkObjectMethod = 4;
  XenoHkInvokable = 8;
  XenoHkVirtual = 16;

var
  // Installed by the plugin host.
  XenoHookEnterProc: TXenoHkEnterProc = nil;
  XenoHookLeaveProc: TXenoHkLeaveProc = nil;

function XenoHookEnter(var Call: TXenoHkCall; Desc: PXenoHkDesc; Self_: Pointer; Args: PXenoHkArgs;
    Result_: Pointer): Boolean;
procedure XenoHookLeave(var Call: TXenoHkCall);
procedure XenoHookRegister(Desc: PXenoHkDesc);
function XenoHookCount: Integer;
function XenoHookAt(Index: Integer): PXenoHkDesc;

implementation

var
  Descs: array of PXenoHkDesc;
  DescCount: Integer = 0;

function XenoHookEnter(var Call: TXenoHkCall; Desc: PXenoHkDesc; Self_: Pointer; Args: PXenoHkArgs;
    Result_: Pointer): Boolean;
begin
  FillChar(Call, SizeOf(Call), 0);
  Call.Desc := Desc;
  Call.Self_ := Self_;
  Call.Arguments := Args;
  Call.Result_ := Result_;
  if Assigned(XenoHookEnterProc) then
    Result := XenoHookEnterProc(Call)
  else
    Result := True;
end;

procedure XenoHookLeave(var Call: TXenoHkCall);
begin
  if Assigned(XenoHookLeaveProc) and (Call.Entry <> nil) then
    XenoHookLeaveProc(Call);
end;

procedure XenoHookRegister(Desc: PXenoHkDesc);
begin
  if DescCount = Length(Descs) then
    SetLength(Descs, DescCount * 2 + 1024);
  Descs[DescCount] := Desc;
  Inc(DescCount);
end;

function XenoHookCount: Integer;
begin
  Result := DescCount;
end;

function XenoHookAt(Index: Integer): PXenoHkDesc;
begin
  if (Index >= 0) and (Index < DescCount) then
    Result := Descs[Index]
  else
    Result := nil;
end;

end.
