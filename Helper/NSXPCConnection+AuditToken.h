//
//  NSXPCConnection+AuditToken.h
//  VPN Bypass privileged helper
//
//  NSXPCConnection carries a private `auditToken` property (audit_token_t) that names the
//  EXACT process on the other end of the connection — kernel-issued, and unlike a PID it
//  cannot be reused or spoofed for the life of the connection. Re-declaring it in a category
//  exposes it to Swift; the real (private) getter is what runs at runtime, so no implementation
//  is needed here. The helper uses it to validate the caller by audit token (race-free) instead
//  of by PID (which is subject to a PID-reuse race — see Helper/HelperTool.swift).
//
//  This is a private API. VPN Bypass is ad-hoc-signed and self-distributed (Homebrew cask), NOT
//  submitted to the App Store, so relying on it here is acceptable — it's the standard technique
//  for hardening XPC on macOS. If Apple ever removes the property, the Swift call site falls back
//  to the PID check (see verifyCaller), so this can never brick the helper.
//

#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>

@interface NSXPCConnection (VPNBypassAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end
