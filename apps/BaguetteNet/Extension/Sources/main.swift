import Foundation
import NetworkExtension

// System-extension entry point. Hands control to NetworkExtension, which
// instantiates the provider named in Info.plist's NEProviderClasses
// (FilterDataProvider) when the filter starts. Integration-only.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
