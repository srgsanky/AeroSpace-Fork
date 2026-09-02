#ifndef private_header_h
#define private_header_h

#import <ApplicationServices/ApplicationServices.h>
#import <stdbool.h>
#import <stdint.h>

// Potential alternative 1?
// func allWindowsOnCurrentMacOsSpace() {
//     let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
//     let windowsListInfo = CGWindowListCopyWindowInfo(options, CGWindowID(0))
//     let infoList = windowsListInfo as! [[String:Any]]
//     let windows = infoList.filter { $0["kCGWindowLayer"] as! Int == 0 }
//     print(windows.count)
//     for window in windows {
//             print(window)
//             print("Name: \(window["kCGWindowOwnerName"].unsafelyUnwrapped)")
//             print("PID: \(window["kCGWindowOwnerPID"].unsafelyUnwrapped)")
//             print("window ID: \(window["kCGWindowNumber"])")
//             print("---")
//     }
// }
//
// Alternative 2:
// @_silgen_name("_AXUIElementGetWindow")
// @discardableResult
// func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ id: inout CGWindowID) -> AXError
AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);

/// Dynamically resolved private CoreGraphics functions used for experimental
/// built-in display control. Keeping resolution in this bridge lets AeroSpace
/// fail closed when Apple removes or changes either symbol.
bool AeroPrivateDisplayControlIsAvailable(void);
CGError AeroPrivateGetDisplayList(uint32_t maxDisplays, CGDirectDisplayID *displays, uint32_t *displayCount);
CGError AeroPrivateConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);

#endif
