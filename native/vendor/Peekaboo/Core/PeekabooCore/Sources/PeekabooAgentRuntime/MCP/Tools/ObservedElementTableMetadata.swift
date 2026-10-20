import MCP
import PeekabooAutomationKit

/// Opt-in structured element table for the `see` and `inspect_ui` MCP tools.
///
/// Rows use `UIElementSummary`, the same type `peekaboo see --json` encodes for `ui_elements[]`.
enum ObservedElementTableMetadata {
    static let argumentName = "include_elements"
    static let key = "ui_elements"

    static let argumentDescription = """
    Optional. Also return the element table as structured data in `_meta.ui_elements`, using the same fields as
    `peekaboo see --json`, together with `_meta.snapshot_id`. Off by default because a window can expose hundreds
    of elements.
    """

    static func value(for elements: [DetectedElement], metadata: DetectionMetadata) throws -> Value {
        let mutationTargetingAvailable = !metadata.isApplicationScopedAccessibilityFallback
        return try Value(elements.map {
            UIElementSummary($0, mutationTargetingAvailable: mutationTargetingAvailable)
        })
    }
}
