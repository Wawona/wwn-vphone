/*
 * vphoned_accessibility — Accessibility tree query over vsock (Wawona).
 *
 * Walks AXRuntime / AccessibilityUtilities when the jailbreak guest exposes
 * them, then falls back to an LSApplicationWorkspace icon grid so
 * agent-device can always emit snapshot -i @eN refs.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Handle an accessibility_tree command. Returns a response dict.
NSDictionary *vp_handle_accessibility_command(NSDictionary *msg);
