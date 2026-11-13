unit XenoFieldMapData;

// Field map of the game object model for the XenoModsFPC plugin host. Built
// in ObjFPC mode on purpose: there "@Record.Field" is the address of the
// field even for procedural and method-pointer fields, while Delphi mode
// would read the procedure stored in it (through nil here).
{$MODE OBJFPC}
{$H+}

interface

type
  TAddFieldProc = procedure(const TypeName, FieldName: AnsiString; Offset: PtrUInt; ByteSize: Integer; const TypeText: AnsiString);
  TAddClassProc = procedure(const TypeName: AnsiString; ClassType: TClass);

procedure FillFieldMap(AddField: TAddFieldProc; AddClass: TAddClassProc);

implementation

uses
{$I XenoFieldMapUnits.inc}

{$I XenoFieldMap.inc}

end.
