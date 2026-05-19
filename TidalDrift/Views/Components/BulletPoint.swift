import SwiftUI

/// Small checked/unchecked bullet used on informational tab views. Lives
/// here (outside any DEBUG-guarded file) so non-DEBUG builds can still use
/// it from the Clipboard Sync tab even when the per-app streaming UI is
/// compiled out.
struct BulletPoint: View {
    let text: String
    let done: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundColor(done ? .green : .secondary)
            Text(text)
                .font(.subheadline)
                .foregroundColor(done ? .primary : .secondary)
        }
    }
}
