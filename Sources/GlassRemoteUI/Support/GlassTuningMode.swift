/// Tuning belongs to the build configuration, never to launch arguments.
public enum GlassTuningMode {
    #if DEBUG
    public static let isEnabled = true
    #else
    public static let isEnabled = false
    #endif
}
