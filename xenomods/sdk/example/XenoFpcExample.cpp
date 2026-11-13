// XenoModsFPC example plugin: the smallest useful template for porting a
// XenoNativeLoader mod. Install as
//   Mods\<Category>\<Mod>\Native\XenoFpcExample.XenoPlugin.dll
// and select the mod. It reads fields by name, hooks a game method, calls a
// game routine by name, follows a few events and exposes script functions
// for ImportedFunction('XenoFpcExample', ...).
#include "../xeno_fpc_plugin_api.h"

#include <atomic>
#include <cstdio>
#include <cstring>

namespace {
const char kId[] = "XenoFpcExample";
const XenoFpcHostV1* g_host = nullptr;
intptr_t g_itemCost = -1;
std::atomic<int> g_itemsCreated{0};
int g_frames = 0;
std::atomic<int> g_days{0};

void Log(const char* text) { g_host->log(kId, XENO_FPC_LOG_INFO, text); }

void XENO_FPC_CALL OnGalaxyCreated(void*, void* payload) {
    auto* event = static_cast<XenoFpcGalaxyCreatedEvent*>(payload);
    char text[128];
    std::snprintf(text, sizeof(text), "galaxy created; sectors=%d", event->sectorCount);
    Log(text);
}

void XENO_FPC_CALL OnItemCreated(void*, void*) { ++g_itemsCreated; }

void XENO_FPC_CALL OnFrame(void*, void*) { ++g_frames; }

void XENO_FPC_CALL OnHangarOpened(void*, void* payload) {
    auto* event = static_cast<XenoFpcHangarEvent*>(payload);
    void* control = g_host->uiFindControl(event->hangar, "PM_EndTurn");
    char text[160];
    std::snprintf(text, sizeof(text), "hangar opened; items_created=%d frames=%d end_turn_button=%s",
        g_itemsCreated.load(), g_frames, control ? "found" : "missing");
    Log(text);
}

// ImportedFunction('XenoFpcExample', 'XenoFpcExample_ItemCost') with
// ScriptLibs: XenoFpcExample_ItemCost=int,XenoFpcExample_ItemCost,dword
void XENO_FPC_CALL ItemCost(void*, XenoFpcScriptCall* call) {
    void* item = reinterpret_cast<void*>(call->arguments[0].dword);
    call->result.i = -1;
    if (g_itemCost >= 0 && g_host->isLiveObject(item) && g_host->isInstanceOf(item, "TItem")) {
        std::memcpy(&call->result.i, static_cast<char*>(item) + g_itemCost, sizeof(int32_t));
    }
}

// After TGalaxy.NextDay: counts the galaxy days this plugin has seen.
void XENO_FPC_CALL AfterNextDay(void*, XenoFpcCall*) { ++g_days; }

// int,XenoFpcExample_Days: lets tests check the hook.
void XENO_FPC_CALL Days(void*, XenoFpcScriptCall* call) { call->result.i = g_days.load(); }

// Calls the game's EC_Str.CountDelimitedPartsW(Text, Delimiters) by name.
int CountParts(const char* text, const char* delimiters) {
    const XenoFpcHookInfo* info = nullptr;
    if (g_host->hookFind("EC_Str.CountDelimitedPartsW", &info, 1) != 1) return -1;
    void* textValue = nullptr;  // WideString storage, empty
    void* delimitersValue = nullptr;
    g_host->valueSetString(&textValue, "WideString", text);
    g_host->valueSetString(&delimitersValue, "WideString", delimiters);
    void* arguments[] = {&textValue, &delimitersValue};
    int32_t result = -1;
    g_host->invoke(info, nullptr, arguments, &result);
    g_host->valueSetString(&textValue, "WideString", nullptr);  // frees the strings
    g_host->valueSetString(&delimitersValue, "WideString", nullptr);
    return result;
}

// int,XenoFpcExample_Add,int,int: lets tests check the script bridge.
void XENO_FPC_CALL Add(void*, XenoFpcScriptCall* call) {
    call->result.i = call->arguments[0].i + call->arguments[1].i;
}
}  // namespace

extern "C" XENO_FPC_EXPORT int32_t XENO_FPC_CALL XenoFpcPlugin_Query(XenoFpcPluginInfoV1* info) {
    if (!info || info->size < sizeof(XenoFpcPluginInfoV1)) return 0;
    info->requiredHostApi = XENO_FPC_HOST_API_V2;
    std::snprintf(info->id, sizeof(info->id), "%s", kId);
    std::snprintf(info->version, sizeof(info->version), "1.0.0");
    std::snprintf(info->description, sizeof(info->description), "XenoModsFPC SDK example");
    return 1;
}

extern "C" XENO_FPC_EXPORT int32_t XENO_FPC_CALL XenoFpcPlugin_Initialize(const XenoFpcHostV1* host) {
    if (!host || host->apiVersion < XENO_FPC_HOST_API_V2 || host->size < sizeof(XenoFpcHostV1)) return 1;
    g_host = host;
    XenoFpcFieldInfo field = {sizeof(field)};
    if (!host->fieldInfo("TItem", "Cost", &field)) return 2;
    g_itemCost = field.offset;
    XenoFpcFieldInfo inherited = {sizeof(inherited)};
    const int chameleon = host->fieldInfo("TRanger", "ChameleonActive", &inherited);  // declared in TShip
    char text[256];
    std::snprintf(text, sizeof(text), "ready cpu=%s TItem.Cost=%d (%s, %d bytes) TRanger.ChameleonActive=%d config=%s",
        host->targetCpu, static_cast<int>(field.offset), field.typeName, field.byteSize,
        chameleon ? static_cast<int>(inherited.offset) : -1, host->configPath);
    Log(text);
    host->subscribe("Galaxy.Created", OnGalaxyCreated, nullptr);
    host->subscribe("Item.Created", OnItemCreated, nullptr);
    host->subscribe("Frame", OnFrame, nullptr);
    host->subscribe("Hangar.Opened", OnHangarOpened, nullptr);
    host->registerScriptFunction("XenoFpcExample", "int,XenoFpcExample_ItemCost,dword", ItemCost, nullptr);
    host->registerScriptFunction("XenoFpcExample", "int,XenoFpcExample_Add,int,int", Add, nullptr);
    host->registerScriptFunction("XenoFpcExample", "int,XenoFpcExample_Days", Days, nullptr);
    if (!host->hook("TGalaxy.NextDay", XENO_FPC_HOOK_AFTER, 0, 0, AfterNextDay, nullptr))
        host->log(kId, XENO_FPC_LOG_WARNING, "TGalaxy.NextDay cannot be hooked in this build");
    std::snprintf(text, sizeof(text), "hooks=%d CountDelimitedPartsW(\"a;b;c\", \";\")=%d", host->hookCount(),
        CountParts("a;b;c", ";"));
    Log(text);
    return 0;
}

extern "C" XENO_FPC_EXPORT void XENO_FPC_CALL XenoFpcPlugin_Shutdown() {
    if (g_host) Log("shutdown");
}
