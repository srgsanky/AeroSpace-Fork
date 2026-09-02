#import "private.h"
#import <dlfcn.h>

typedef CGError (*AeroConfigureDisplayEnabledFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
typedef CGError (*AeroGetDisplayListFn)(uint32_t, CGDirectDisplayID *, uint32_t *);

static AeroConfigureDisplayEnabledFn getConfigureDisplayEnabled(void) {
    static AeroConfigureDisplayEnabledFn function;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (AeroConfigureDisplayEnabledFn)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
    });
    return function;
}

static AeroGetDisplayListFn getDisplayList(void) {
    static AeroGetDisplayListFn function;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (AeroGetDisplayListFn)dlsym(RTLD_DEFAULT, "CGSGetDisplayList");
    });
    return function;
}

bool AeroPrivateDisplayControlIsAvailable(void) {
    return getConfigureDisplayEnabled() != NULL && getDisplayList() != NULL;
}

CGError AeroPrivateGetDisplayList(uint32_t maxDisplays, CGDirectDisplayID *displays, uint32_t *displayCount) {
    AeroGetDisplayListFn function = getDisplayList();
    return function == NULL ? kCGErrorNotImplemented : function(maxDisplays, displays, displayCount);
}

CGError AeroPrivateConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled) {
    AeroConfigureDisplayEnabledFn function = getConfigureDisplayEnabled();
    return function == NULL ? kCGErrorNotImplemented : function(config, display, enabled);
}
