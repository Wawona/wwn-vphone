/*
 * vphoned_accessibility — Accessibility tree for agent-device @eN refs.
 *
 * Primary path: AXRuntime private C API (_AXUIElementCreateWithPid +
 * AXUIElementCopyAttributeValue) and AccessibilityUtilities AXElement.
 * Appropriate for the jailbroken research kernel: vphoned is already a
 * platform-application LaunchDaemon with backboard/SpringBoard ents.
 *
 * Fallback: LSApplicationWorkspace user-app icon grid (same heuristic the
 * host sock uses when guest capability is missing).
 */

#import "vphoned_accessibility.h"
#import "vphoned_protocol.h"
#import "vphoned_apps.h"

#import <CoreGraphics/CoreGraphics.h>

#include <dlfcn.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>

typedef const void *VP_AXUIElementRef;
typedef int VP_AXError;

typedef VP_AXUIElementRef (*vp_ax_create_pid_fn)(pid_t);
typedef VP_AXError (*vp_ax_copy_attr_fn)(VP_AXUIElementRef, CFStringRef, CFTypeRef *);

static const NSUInteger kVPAxMaxNodes = 256;
static const NSInteger kVPAxDefaultMaxDepth = 8;

static CGSize vp_screen_points(void) {
  Class uiScreen = NSClassFromString(@"UIScreen");
  if (uiScreen) {
    id (*msg0)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id main = msg0(uiScreen, sel_registerName("mainScreen"));
    if (main) {
      CGRect (*msgRect)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
      CGRect bounds = msgRect(main, sel_registerName("bounds"));
      if (bounds.size.width > 1 && bounds.size.height > 1)
        return bounds.size;
    }
  }
  return CGSizeMake(1290, 2796);
}

static NSString *vp_cf_string(CFTypeRef value) {
  if (!value)
    return nil;
  if (CFGetTypeID(value) == CFStringGetTypeID())
    return (__bridge NSString *)value;
  if (CFGetTypeID(value) == CFNumberGetTypeID())
    return [(__bridge NSNumber *)value stringValue];
  if ([(__bridge id)value isKindOfClass:[NSString class]])
    return (__bridge NSString *)value;
  return [(__bridge id)value description];
}

static BOOL vp_parse_rect(CFTypeRef value, CGRect *outRect) {
  if (!value || !outRect)
    return NO;
  id obj = (__bridge id)value;
  if ([obj isKindOfClass:[NSValue class]]) {
    NSValue *nv = (NSValue *)obj;
    const char *t = [nv objCType];
    if (t && (strcmp(t, @encode(CGRect)) == 0 || strcmp(t, "{CGRect={CGPoint=dd}{CGSize=dd}}") == 0)) {
      [nv getValue:outRect];
      return YES;
    }
  }
  if ([obj isKindOfClass:[NSDictionary class]]) {
    NSDictionary *d = (NSDictionary *)obj;
    double x = [d[@"X"] ?: d[@"x"] ?: d[@"minX"] doubleValue];
    double y = [d[@"Y"] ?: d[@"y"] ?: d[@"minY"] doubleValue];
    double w = [d[@"Width"] ?: d[@"width"] doubleValue];
    double h = [d[@"Height"] ?: d[@"height"] doubleValue];
    if (w > 0 || h > 0) {
      *outRect = CGRectMake(x, y, w, h);
      return YES;
    }
  }
  return NO;
}

static BOOL vp_bool_attr(CFTypeRef value, BOOL fallback) {
  if (!value)
    return fallback;
  if (CFGetTypeID(value) == CFBooleanGetTypeID())
    return CFBooleanGetValue((CFBooleanRef)value);
  if ([(__bridge id)value respondsToSelector:@selector(boolValue)])
    return [(__bridge id)value boolValue];
  return fallback;
}

static void vp_walk_ax_element(VP_AXUIElementRef element, vp_ax_copy_attr_fn copyAttr,
                               NSInteger depth, NSInteger maxDepth, NSMutableArray *nodes) {
  if (!element || !copyAttr || nodes.count >= kVPAxMaxNodes)
    return;
  if (maxDepth >= 0 && depth > maxDepth)
    return;

  CFTypeRef role = NULL;
  CFTypeRef label = NULL;
  CFTypeRef title = NULL;
  CFTypeRef value = NULL;
  CFTypeRef ident = NULL;
  CFTypeRef frame = NULL;
  CFTypeRef enabled = NULL;
  CFTypeRef children = NULL;

  copyAttr(element, CFSTR("AXRole"), &role);
  copyAttr(element, CFSTR("AXLabel"), &label);
  copyAttr(element, CFSTR("AXTitle"), &title);
  copyAttr(element, CFSTR("AXValue"), &value);
  copyAttr(element, CFSTR("AXIdentifier"), &ident);
  copyAttr(element, CFSTR("AXFrame"), &frame);
  copyAttr(element, CFSTR("AXEnabled"), &enabled);
  copyAttr(element, CFSTR("AXChildren"), &children);

  NSString *roleStr = vp_cf_string(role);
  NSString *labelStr = vp_cf_string(label) ?: vp_cf_string(title);
  NSString *identStr = vp_cf_string(ident);
  NSString *valueStr = vp_cf_string(value);
  CGRect rect = CGRectZero;
  BOOL hasRect = vp_parse_rect(frame, &rect);

  if (labelStr.length || identStr.length || hasRect) {
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"index"] = @(nodes.count);
    node[@"type"] = roleStr.length ? roleStr : @"element";
    node[@"role"] = roleStr.length ? roleStr : @"element";
    if (labelStr.length)
      node[@"label"] = labelStr;
    if (identStr.length)
      node[@"identifier"] = identStr;
    if (valueStr.length)
      node[@"value"] = valueStr;
    if (hasRect) {
      node[@"rect"] = @{
        @"x" : @(rect.origin.x),
        @"y" : @(rect.origin.y),
        @"width" : @(rect.size.width),
        @"height" : @(rect.size.height),
      };
    }
    node[@"enabled"] = @(vp_bool_attr(enabled, YES));
    node[@"hittable"] = @YES;
    node[@"visible"] = @YES;
    node[@"depth"] = @(depth);
    [nodes addObject:node];
  }

  if (children && CFGetTypeID(children) == CFArrayGetTypeID()) {
    CFArrayRef arr = (CFArrayRef)children;
    CFIndex n = CFArrayGetCount(arr);
    for (CFIndex i = 0; i < n && nodes.count < kVPAxMaxNodes; i++) {
      VP_AXUIElementRef child = CFArrayGetValueAtIndex(arr, i);
      vp_walk_ax_element(child, copyAttr, depth + 1, maxDepth, nodes);
    }
  }

  if (role)
    CFRelease(role);
  if (label)
    CFRelease(label);
  if (title)
    CFRelease(title);
  if (value)
    CFRelease(value);
  if (ident)
    CFRelease(ident);
  if (frame)
    CFRelease(frame);
  if (enabled)
    CFRelease(enabled);
  if (children)
    CFRelease(children);
}

static NSArray *vp_try_axruntime(NSInteger maxDepth) {
  void *handle = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_LAZY);
  if (!handle)
    handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
  if (!handle)
    return nil;

  vp_ax_create_pid_fn createPid = (vp_ax_create_pid_fn)dlsym(handle, "_AXUIElementCreateWithPid");
  if (!createPid)
    createPid = (vp_ax_create_pid_fn)dlsym(handle, "AXUIElementCreateApplication");
  vp_ax_copy_attr_fn copyAttr = (vp_ax_copy_attr_fn)dlsym(handle, "AXUIElementCopyAttributeValue");
  if (!createPid || !copyAttr)
    return nil;

  NSMutableArray *nodes = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];

  void (^walkPid)(pid_t) = ^(pid_t pid) {
    if (pid <= 0)
      return;
    NSNumber *key = @(pid);
    if ([seen containsObject:key])
      return;
    [seen addObject:key];
    VP_AXUIElementRef root = createPid(pid);
    if (!root)
      return;
    vp_walk_ax_element(root, copyAttr, 0, maxDepth, nodes);
    CFRelease(root);
  };

  NSDictionary *listReq = @{@"t" : @"app_list", @"id" : @"0", @"filter" : @"user"};
  NSDictionary *listResp = vp_handle_apps_command(listReq);
  NSArray *apps = listResp[@"apps"];
  if ([apps isKindOfClass:[NSArray class]]) {
    for (NSDictionary *app in apps) {
      pid_t pid = [app[@"pid"] intValue];
      walkPid(pid);
    }
  }

  return nodes.count > 0 ? nodes : nil;
}

static NSArray *vp_try_axelement(NSInteger maxDepth) {
  void *au = dlopen(
      "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
      RTLD_LAZY);
  (void)au;
  Class axElement = NSClassFromString(@"AXElement");
  if (!axElement)
    return nil;

  SEL sysSel = sel_registerName("systemWideElement");
  if (![axElement respondsToSelector:sysSel])
    return nil;
  id (*msg0)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
  id root = msg0(axElement, sysSel);
  if (!root)
    return nil;

  NSMutableArray *nodes = [NSMutableArray array];

  __block __weak void (^weakWalk)(id, NSInteger) = nil;
  void (^walkImpl)(id, NSInteger) = ^(id el, NSInteger depth) {
    if (!el || nodes.count >= kVPAxMaxNodes)
      return;
    if (maxDepth >= 0 && depth > maxDepth)
      return;
    NSString *label = nil;
    NSString *ident = nil;
    NSString *role = nil;
    if ([el respondsToSelector:@selector(label)])
      label = ((id (*)(id, SEL))objc_msgSend)(el, @selector(label));
    if ([el respondsToSelector:@selector(identifier)])
      ident = ((id (*)(id, SEL))objc_msgSend)(el, @selector(identifier));
    if ([el respondsToSelector:@selector(role)])
      role = ((id (*)(id, SEL))objc_msgSend)(el, @selector(role));
    CGRect frame = CGRectZero;
    if ([el respondsToSelector:@selector(frame)]) {
      CGRect (*msgRect)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
      frame = msgRect(el, @selector(frame));
    }
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"index"] = @(nodes.count);
    node[@"type"] = [role isKindOfClass:[NSString class]] && role.length ? role : @"element";
    node[@"role"] = node[@"type"];
    if ([label isKindOfClass:[NSString class]] && label.length)
      node[@"label"] = label;
    if ([ident isKindOfClass:[NSString class]] && ident.length)
      node[@"identifier"] = ident;
    if (!CGRectIsEmpty(frame)) {
      node[@"rect"] = @{
        @"x" : @(frame.origin.x),
        @"y" : @(frame.origin.y),
        @"width" : @(frame.size.width),
        @"height" : @(frame.size.height),
      };
    }
    node[@"enabled"] = @YES;
    node[@"hittable"] = @YES;
    node[@"visible"] = @YES;
    node[@"depth"] = @(depth);
    [nodes addObject:node];

    NSArray *kids = nil;
    if ([el respondsToSelector:@selector(elements)])
      kids = ((id (*)(id, SEL))objc_msgSend)(el, @selector(elements));
    else if ([el respondsToSelector:@selector(children)])
      kids = ((id (*)(id, SEL))objc_msgSend)(el, @selector(children));
    if ([kids isKindOfClass:[NSArray class]]) {
      for (id child in kids) {
        if (weakWalk)
          weakWalk(child, depth + 1);
        if (nodes.count >= kVPAxMaxNodes)
          break;
      }
    }
  };
  weakWalk = walkImpl;
  walkImpl(root, 0);
  return nodes.count > 0 ? nodes : nil;
}

static NSArray *vp_icon_grid_fallback(void) {
  NSDictionary *listReq = @{
    @"t" : @"app_list",
    @"id" : @"0",
    @"filter" : @"user",
  };
  NSDictionary *listResp = vp_handle_apps_command(listReq);
  NSArray *apps = listResp[@"apps"];
  if (![apps isKindOfClass:[NSArray class]])
    return nil;

  CGSize screen = vp_screen_points();
  const double cols = 4.0;
  const double icon = fmin(screen.width, screen.height) * 0.14;
  const double left = screen.width * 0.08;
  const double top = screen.height * 0.18;
  const double gapX = (screen.width - left * 2 - icon * cols) / (cols - 1);
  const double gapY = icon * 0.55;

  NSMutableArray *nodes = [NSMutableArray array];
  NSUInteger i = 0;
  for (NSDictionary *app in apps) {
    if (![app isKindOfClass:[NSDictionary class]])
      continue;
    double col = (double)(i % (NSUInteger)cols);
    double row = (double)(i / (NSUInteger)cols);
    double x = left + col * (icon + gapX);
    double y = top + row * (icon + gapY);
    [nodes addObject:@{
      @"index" : @(i),
      @"type" : @"app_icon",
      @"role" : @"button",
      @"label" : app[@"name"] ?: @"",
      @"identifier" : app[@"bundle_id"] ?: @"",
      @"rect" : @{
        @"x" : @(x),
        @"y" : @(y),
        @"width" : @(icon),
        @"height" : @(icon),
      },
      @"enabled" : @YES,
      @"hittable" : @YES,
      @"visible" : @YES,
      @"depth" : @0,
      @"bundle_id" : app[@"bundle_id"] ?: @"",
      @"pid" : app[@"pid"] ?: @0,
    }];
    i++;
  }
  return nodes;
}

NSDictionary *vp_handle_accessibility_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSInteger maxDepth = kVPAxDefaultMaxDepth;
  id depthObj = msg[@"depth"];
  if ([depthObj respondsToSelector:@selector(integerValue)]) {
    NSInteger requested = [depthObj integerValue];
    if (requested >= 0)
      maxDepth = requested;
  }

  NSString *source = nil;
  NSArray *nodes = vp_try_axruntime(maxDepth);
  if (nodes.count > 0) {
    source = @"axruntime";
  } else {
    nodes = vp_try_axelement(maxDepth);
    if (nodes.count > 0)
      source = @"axelement";
  }
  if (nodes.count == 0) {
    nodes = vp_icon_grid_fallback();
    source = @"icon-grid";
  }
  if (![nodes isKindOfClass:[NSArray class]]) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"accessibility_tree unavailable";
    return r;
  }

  CGSize screen = vp_screen_points();
  NSMutableDictionary *r = vp_make_response(@"accessibility_tree", reqId);
  r[@"ok"] = @YES;
  r[@"nodes"] = nodes;
  r[@"screenWidth"] = @(screen.width);
  r[@"screenHeight"] = @(screen.height);
  r[@"source"] = source ?: @"unknown";
  if ([source isEqualToString:@"icon-grid"]) {
    r[@"warning"] =
        @"vphoned accessibility_tree: AXRuntime unavailable; app_list icon-grid fallback";
  }
  return r;
}
