// The per-app routing system extension. sysextd starts it; NEProvider then finds the provider
// class named in Info.plist (NEProviderClasses) and runs it.
import Foundation
import NetworkExtension

if #available(macOS 15, *) {
    autoreleasepool {
        NEProvider.startSystemExtensionMode()
    }
    dispatchMain()
} else {
    // LSMinimumSystemVersion is 15.0, so macOS never starts it on an older system.
    exit(1)
}
