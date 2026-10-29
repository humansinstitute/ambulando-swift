import SwiftUI

// Geometry is collected only by the isolated synthetic renderer fixture in Debug/Test builds.
#if DEBUG
private struct RichLayoutFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
extension EnvironmentValues {
    @Entry var richLayoutProbeEnabled = false
}
private struct RichLayoutFrame: ViewModifier {
    @Environment(\.richLayoutProbeEnabled) private var enabled
    let name: String
    func body(content: Content) -> some View {
        content.background {
            if enabled {
                GeometryReader { proxy in
                    Color.clear.preference(key: RichLayoutFrames.self, value: [name: proxy.frame(in: .global)])
                }
            }
        }
    }
}
#endif
extension View {
    @ViewBuilder func richLayoutFrame(_ name: String) -> some View {
        #if DEBUG
        modifier(RichLayoutFrame(name: name))
        #else
        self
        #endif
    }
    @ViewBuilder func observeRichLayout(_ action: @escaping ([String: CGRect]) -> Void) -> some View {
        #if DEBUG
        onPreferenceChange(RichLayoutFrames.self, perform: action)
        #else
        self
        #endif
    }
}
