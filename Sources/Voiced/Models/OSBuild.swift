import Foundation

enum OSBuild {
    /// The running macOS build, such as "25F84". Core ML keeps the Neural Engine programs it
    /// compiles per build, so a record of what has been compiled is only good for one build.
    static let current: String = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }()
}
