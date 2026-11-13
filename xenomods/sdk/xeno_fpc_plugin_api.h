/*
 * XenoModsFPC plugin API, version 2.
 *
 * The Free Pascal build of Space Rangers HD loads Mods\<category>\<mod>\Native\
 * *.XenoPlugin.dll (.so on Linux/Android) for every selected mod, the same way
 * XenoNativeLoader does for the Delphi game. Plugins do not patch code: any
 * routine of the game can be hooked by name (hook(), API 2), the game also
 * raises named events at fixed extension points, and object fields are found
 * by name through fieldInfo(). One DLL may export both the XenoNativeLoader
 * entry points (XenoPlugin_*) and these (XenoFpcPlugin_*).
 *
 * Rules:
 *  - every function is cdecl; every string is UTF-8; paths use the host OS;
 *  - structures only grow: check size before using a member added later;
 *  - the host calls the plugin on the game thread unless an event says
 *    otherwise (Item.*, Sound.VolumeRamp may run on worker threads); a hook
 *    runs on whatever thread called the routine;
 *  - object pointers are only valid during the call that delivered them,
 *    unless isLiveObject() still confirms them later.
 */
#ifndef XENO_FPC_PLUGIN_API_H
#define XENO_FPC_PLUGIN_API_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define XENO_FPC_CALL __cdecl
#define XENO_FPC_EXPORT __declspec(dllexport)
#else
#define XENO_FPC_CALL
#define XENO_FPC_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define XENO_FPC_HOST_API_V1 1u
#define XENO_FPC_HOST_API_V2 2u /* method hooks, invoke, string values */

enum XenoFpcLogLevel { XENO_FPC_LOG_DEBUG = 0, XENO_FPC_LOG_INFO = 1, XENO_FPC_LOG_WARNING = 2, XENO_FPC_LOG_ERROR = 3 };

/* Script values for ImportedFunction libraries (see registerScriptFunction). */
enum XenoFpcValueKind { XENO_FPC_VOID = 0, XENO_FPC_INT = 1, XENO_FPC_DWORD = 2, XENO_FPC_FLOAT = 3, XENO_FPC_STR = 4 };

typedef struct XenoFpcValue {
    int32_t kind;          /* XenoFpcValueKind */
    int32_t i;             /* INT */
    uintptr_t dword;       /* DWORD: integers and game object pointers */
    float f;               /* FLOAT */
    const char* s;         /* STR, UTF-8; for results the plugin keeps it alive until its next call */
} XenoFpcValue;

typedef struct XenoFpcScriptCall {
    uint32_t size;
    int32_t argumentCount;
    const XenoFpcValue* arguments;
    XenoFpcValue result;   /* kind is preset from the signature */
} XenoFpcScriptCall;

typedef struct XenoFpcFieldInfo {
    uint32_t size;
    intptr_t offset;       /* from the object (class) or record start */
    int32_t byteSize;
    const char* typeName;  /* declared Pascal type, e.g. "Integer", "WideString", "TList" */
} XenoFpcFieldInfo;

/* ---- Method hooks (API 2) -------------------------------------------------

   Every routine of the game with a body (methods, constructors, destructors,
   unit routines) can be hooked by name: "TShip.GetName", "aShip.TShip.GetName"
   or "EC_Str.TrimWideString". Overloads take the parameter types:
   "TFoo.Bar(Integer, WideString)". The list of names is XenoHooks.txt in the
   SDK archive; hookCount()/hookInfoAt() enumerate them at run time. */

enum XenoFpcHookPhase { XENO_FPC_HOOK_BEFORE = 0, XENO_FPC_HOOK_AFTER = 1 };
/* hook()/hookAdd() flags. OVERRIDES: also every override of the method in
   derived classes (the base method may be abstract); a call that goes through
   several overrides of one object (inherited) reaches the handler once. */
enum XenoFpcHookFlags { XENO_FPC_HOOK_OVERRIDES = 1 };
enum XenoFpcRoutineKind { XENO_FPC_PROCEDURE = 0, XENO_FPC_FUNCTION = 1, XENO_FPC_CONSTRUCTOR = 2, XENO_FPC_DESTRUCTOR = 3 };
enum XenoFpcRoutineFlags {
    XENO_FPC_ROUTINE_CLASS_METHOD = 1,  /* self is the class, not an object */
    XENO_FPC_ROUTINE_STATIC = 2,        /* no self */
    XENO_FPC_ROUTINE_OBJECT = 4,        /* old-style object: self points to it */
    XENO_FPC_ROUTINE_INVOKABLE = 8,     /* invoke() can call it */
    XENO_FPC_ROUTINE_VIRTUAL = 16
};
enum XenoFpcArgumentMode { XENO_FPC_ARG_VALUE = 0, XENO_FPC_ARG_CONST = 1, XENO_FPC_ARG_VAR = 2, XENO_FPC_ARG_OUT = 3, XENO_FPC_ARG_CONSTREF = 4 };

typedef struct XenoFpcHookArgument {
    const char* name;
    const char* typeName;  /* Pascal type as declared, e.g. "Integer", "WideString", "TShip" */
    int32_t mode;          /* XenoFpcArgumentMode */
    int32_t byteSize;      /* 0 for open arrays and untyped parameters */
} XenoFpcHookArgument;

typedef struct XenoFpcHookInfo {
    uint32_t size;
    int32_t id;                  /* 0 .. hookCount()-1 in this build */
    const char* name;            /* "TShip.GetName", "EC_Str.TrimWideString" */
    const char* unitName;
    const char* className;       /* "" for unit routines */
    const char* methodName;
    const char* parameters;      /* "(const Text: WideString)" as declared, "" without parameters */
    const char* resultType;      /* "" for procedures; the class for constructors */
    int32_t kind;                /* XenoFpcRoutineKind */
    int32_t flags;               /* XenoFpcRoutineFlags */
    int32_t resultSize;
    int32_t argumentCount;
    const XenoFpcHookArgument* arguments;
} XenoFpcHookInfo;

/* One call of a hooked routine, shared by all its handlers.
   arguments[i] points to argument i (for var/out arguments: to the caller's
   variable). result points to the function result (NULL for procedures).

   Before handlers may change value, var and out arguments (never const ones)
   and may replace the routine: write *result and set skipOriginal = 1. Only
   the first replacement counts; later handlers see replacedBy and should
   leave the result alone. After handlers see the final result and may change
   it. Strings and other managed values are changed with valueSetString(). */
typedef struct XenoFpcCall {
    uint32_t size;
    const XenoFpcHookInfo* info;
    void* self;                  /* object, class (class methods) or NULL */
    void* const* arguments;
    void* result;
    int32_t skipOriginal;        /* before: 1 = do not run the original */
    int32_t originalRan;         /* after: 1 when the original ran */
    const char* replacedBy;      /* id of the plugin that replaced the original, or NULL */
} XenoFpcCall;

typedef void (XENO_FPC_CALL* XenoFpcHookFn)(void* user, XenoFpcCall* call);

typedef void (XENO_FPC_CALL* XenoFpcEventFn)(void* user, void* payload);
typedef void (XENO_FPC_CALL* XenoFpcScriptFn)(void* user, XenoFpcScriptCall* call);
typedef void (XENO_FPC_CALL* XenoFpcUiCallbackFn)(void* user, void* control);

typedef struct XenoFpcHostV1 {
    uint32_t size;
    uint32_t apiVersion;
    const char* gameVersion;       /* e.g. "2.1.2500 fpc <revision>" */
    const char* gameRoot;          /* absolute game data folder */
    const char* modFolder;         /* game-relative, e.g. "Mods\\XenoMods\\XenoBigGalaxy\\" */
    const char* pluginPath;        /* absolute path of this DLL */
    const char* configPath;        /* absolute path of <plugin>.ini, may not exist */
    const char* targetCpu;         /* "i386", "x86_64", "aarch64" */

    void (XENO_FPC_CALL* log)(const char* pluginId, int32_t level, const char* text);
    /* INI helpers (UTF-8/UTF-16 with BOM). Missing or non-numeric -> default; numbers are clamped. */
    int32_t (XENO_FPC_CALL* configGetInt)(const char* path, const char* section, const char* key,
        int32_t defaultValue, int32_t minimum, int32_t maximum);
    /* Copies a value; returns its full length in bytes (without the terminator). */
    int32_t (XENO_FPC_CALL* configGetString)(const char* path, const char* section, const char* key,
        const char* defaultValue, char* buffer, int32_t bufferSize);
    /* Value from the merged game configuration (Main.dat or Lang.dat with every
       active mod applied); root 0 = Main, 1 = Lang. Returns -1 when missing. */
    int32_t (XENO_FPC_CALL* gameConfigGet)(int32_t root, const char* path, char* buffer, int32_t bufferSize);
    /* 1 when a mod folder (last path component, e.g. "XenoBigGalaxy") is selected. */
    int32_t (XENO_FPC_CALL* isModActive)(const char* modName);

    /* Events: see XENO_FPC_EVENT_* below. Returns 1 or 0 for an unknown name. */
    int32_t (XENO_FPC_CALL* subscribe)(const char* eventName, XenoFpcEventFn callback, void* user);
    /* ImportedFunction('<Library>', '<Name>'): library is the DLL file name
       without ".dll" from the mod's ScriptLibs Path; signature as in ScriptLibs,
       e.g. "int,MyMod_GetValue,int,dword". Returns 1 on success. */
    int32_t (XENO_FPC_CALL* registerScriptFunction)(const char* library, const char* signature,
        XenoFpcScriptFn callback, void* user);

    /* Object model. */
    int32_t (XENO_FPC_CALL* fieldInfo)(const char* typeName, const char* fieldName, XenoFpcFieldInfo* info);
    int32_t (XENO_FPC_CALL* isLiveObject)(const void* object);
    int32_t (XENO_FPC_CALL* isInstanceOf)(const void* object, const char* className);
    /* Copies the class name; returns its length or -1. */
    int32_t (XENO_FPC_CALL* objectClassName)(const void* object, char* buffer, int32_t bufferSize);
    void* (XENO_FPC_CALL* galaxy)(void);
    void* (XENO_FPC_CALL* player)(void);
    int32_t (XENO_FPC_CALL* listCount)(const void* list);              /* TList/TObjectList */
    void* (XENO_FPC_CALL* listItem)(const void* list, int32_t index);
    /* WideString field at object+offset as UTF-8; returns length or -1. */
    int32_t (XENO_FPC_CALL* readWideString)(const void* object, intptr_t offset, char* buffer, int32_t bufferSize);
    void* (XENO_FPC_CALL* objectById)(int32_t kind, uint32_t id);       /* 1 = ship, 2 = item */

    /* User interface (the current screen's controls by Name from its CFG). */
    void* (XENO_FPC_CALL* uiFindControl)(void* screen, const char* name);
    void (XENO_FPC_CALL* uiSetActive)(void* control, int32_t active);
    int32_t (XENO_FPC_CALL* uiSetButtonCallback)(void* control, XenoFpcUiCallbackFn callback, void* user);
    int32_t (XENO_FPC_CALL* uiSetLabelText)(void* control, const char* text);

    /* Game services. */
    uint32_t (XENO_FPC_CALL* tickCount)(void);
    /* Hangar: show a ship (or none) in landing slot 1..8 with the stock fade-in. */
    void (XENO_FPC_CALL* hangarShowShip)(void* hangar, int32_t slot, void* ship);
    /* Music: stock file choice; "" when the current file already fits the category. */
    int32_t (XENO_FPC_CALL* musicChooseFile)(const char* category, const char* currentFile, char* buffer, int32_t bufferSize);
    /* Music: runs the stock PlayCategory without raising Music.PlayCategory. */
    void (XENO_FPC_CALL* musicPlayCategory)(const char* category);
    /* Music units: 0 = current, 1 = queued. */
    int32_t (XENO_FPC_CALL* musicUnitRunning)(int32_t unit);
    int32_t (XENO_FPC_CALL* musicUnitFile)(int32_t unit, char* buffer, int32_t bufferSize);
    void (XENO_FPC_CALL* musicUnitStop)(int32_t unit, int32_t immediate);
    void (XENO_FPC_CALL* musicUnitStart)(int32_t unit);              /* start a queued, waiting unit */
    void* (XENO_FPC_CALL* musicUnitBuffer)(int32_t unit);            /* TSoundBuffer for Sound.VolumeRamp */
    /* Remaining audible milliseconds of the current track, -1 while unknown. */
    int32_t (XENO_FPC_CALL* musicRemainingMs)(void);
    void (XENO_FPC_CALL* soundSetVolumeStep)(void* buffer, float step);
    int32_t (XENO_FPC_CALL* musicCategoryOverride)(char* buffer, int32_t bufferSize);

    /* ---- API 2: method hooks (check apiVersion >= 2) ---- */
    int32_t (XENO_FPC_CALL* hookCount)(void);
    const XenoFpcHookInfo* (XENO_FPC_CALL* hookInfoAt)(int32_t index);
    /* Fills up to maxFound matches; returns how many routines match the name. */
    int32_t (XENO_FPC_CALL* hookFind)(const char* name, const XenoFpcHookInfo** found, int32_t maxFound);
    /* Handlers run by priority (lower first), then in mod load order; after
       handlers in the reverse order. Returns a handle, 0 on failure. Hooks are
       removed automatically when the plugin is unloaded. */
    intptr_t (XENO_FPC_CALL* hookAdd)(const XenoFpcHookInfo* info, int32_t phase, int32_t flags, int32_t priority,
        XenoFpcHookFn callback, void* user);
    /* hookAdd by name; logs unknown and ambiguous names. */
    intptr_t (XENO_FPC_CALL* hook)(const char* name, int32_t phase, int32_t flags, int32_t priority,
        XenoFpcHookFn callback, void* user);
    void (XENO_FPC_CALL* hookRemove)(intptr_t handle);
    /* Calls a routine (with its hooks): arguments as in XenoFpcCall, result
       storage of info->resultSize bytes, zeroed for managed types. Returns 0
       when the routine cannot be invoked or raised an exception. */
    int32_t (XENO_FPC_CALL* invoke)(const XenoFpcHookInfo* info, void* self, void* const* arguments, void* result);
    /* Strings in game storage (arguments, results, fields) by Pascal type name:
       WideString, UnicodeString, AnsiString/string, UTF8String, ShortString;
       get also PWideChar/PAnsiChar. get returns the length or -1; set 1 or 0,
       set with NULL makes the string empty (and frees it). */
    int32_t (XENO_FPC_CALL* valueGetString)(const void* storage, const char* typeName, char* buffer, int32_t bufferSize);
    int32_t (XENO_FPC_CALL* valueSetString)(void* storage, const char* typeName, const char* text);
} XenoFpcHostV1;

typedef struct XenoFpcPluginInfoV1 {
    uint32_t size;
    uint32_t requiredHostApi;
    char id[64];
    char version[32];
    char description[160];
} XenoFpcPluginInfoV1;

/* Exports of a plugin. Initialize returns 0 on success; any other value is
   logged and the plugin stays loaded but receives nothing. */
typedef int32_t (XENO_FPC_CALL* XenoFpcPluginQueryFn)(XenoFpcPluginInfoV1* info);
typedef int32_t (XENO_FPC_CALL* XenoFpcPluginInitializeFn)(const XenoFpcHostV1* host);
/* Optional: called before the game unloads plugins. */
typedef void (XENO_FPC_CALL* XenoFpcPluginShutdownFn)(void);

/* ---- Events (payload structures; size is set by the host) ---------------- */

/* "Frame": main thread, every message pump. */
typedef struct XenoFpcFrameEvent { uint32_t size; uint32_t tick; } XenoFpcFrameEvent;

/* "Galaxy.Created": TGalaxy constructor, new game or load. Set sectorCount. */
typedef struct XenoFpcGalaxyCreatedEvent { uint32_t size; void* galaxy; int32_t sectorCount; } XenoFpcGalaxyCreatedEvent;
/* "Galaxy.PlanStar": sector of star starIndex during generation; -1 keeps the
   stock rule. The stock area balancing applies after a plugin choice. */
typedef struct XenoFpcGalaxyPlanStarEvent { uint32_t size; void* galaxy; int32_t starIndex; int32_t sector; } XenoFpcGalaxyPlanStarEvent;
/* "Galaxy.LayoutDone": after each sector layout attempt. done = stock
   "attempts > 1000"; the layout is also accepted when the stock checks pass. */
typedef struct XenoFpcGalaxyLayoutEvent { uint32_t size; void* galaxy; int32_t attempts; int32_t done; } XenoFpcGalaxyLayoutEvent;
/* "Galaxy.ContourNoEar": hidden-sector trimming found no star-free ear.
   Set removeVertex=1 to drop a vertex (the stock loop would never end). */
typedef struct XenoFpcContourEvent { uint32_t size; int32_t removeVertex; } XenoFpcContourEvent;
/* "Galaxy.StationSpawning": NextDay stage 8; run=0 skips it today. */
typedef struct XenoFpcStationSpawningEvent { uint32_t size; void* galaxy; int32_t day; int32_t run; } XenoFpcStationSpawningEvent;

/* "Item.Created", "Item.Destroyed", "Item.Loaded" (end of TItem.LoadFromBuffer
   and LoadFromBlock). May run on the turn worker thread. */
typedef struct XenoFpcItemEvent { uint32_t size; void* item; } XenoFpcItemEvent;
/* "Item.SaveCost": TItem.SaveToBuffer is about to store cost. */
typedef struct XenoFpcItemSaveCostEvent { uint32_t size; void* item; int32_t cost; } XenoFpcItemSaveCostEvent;

/* "Kling.Camouflage": TKling.IsPlayerCamouflageEffective(target) for a target
   that is not the player. Set handled=1 and effective. */
typedef struct XenoFpcCamouflageEvent { uint32_t size; void* kling; void* target; int32_t handled; int32_t effective; } XenoFpcCamouflageEvent;

/* "Hangar.Opened", "Hangar.Closed". */
typedef struct XenoFpcHangarEvent { uint32_t size; void* hangar; } XenoFpcHangarEvent;
/* "Hangar.Refresh": before the stock fill of landing slots 1..8 (every frame).
   handled=1 skips the stock fill of slots 1..8 (slot 0 stays stock). */
typedef struct XenoFpcHangarRefreshEvent { uint32_t size; void* hangar; int32_t handled; } XenoFpcHangarRefreshEvent;
/* "Hangar.Key": key press not used by the hangar itself; handled=1 consumes it. */
typedef struct XenoFpcHangarKeyEvent { uint32_t size; void* hangar; uint32_t key; int32_t handled; } XenoFpcHangarKeyEvent;

/* "Music.PlayCategory": skip=1 suppresses the stock switch. */
typedef struct XenoFpcMusicCategoryEvent { uint32_t size; const char* category; int32_t skip; } XenoFpcMusicCategoryEvent;
/* "Music.StopImmediately". */
typedef struct XenoFpcMusicStopEvent { uint32_t size; } XenoFpcMusicStopEvent;
/* "Music.PlaceFade": takeoff after autosave and the loading screen fade the
   music out; keep=1 keeps the track. */
typedef struct XenoFpcMusicPlaceFadeEvent { uint32_t size; int32_t keep; } XenoFpcMusicPlaceFadeEvent;
/* "Sound.VolumeRamp": TSoundBuffer.StartVolumeRamp; may adjust step. Audio thread. */
typedef struct XenoFpcVolumeRampEvent { uint32_t size; void* buffer; uint32_t intervalMs; float step; } XenoFpcVolumeRampEvent;

#ifdef __cplusplus
}
#endif

#endif
