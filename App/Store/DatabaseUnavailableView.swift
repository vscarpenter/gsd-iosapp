import SwiftUI

/// Shown in place of the main UI when the local database can't be opened at launch even after
/// recovery (e.g. an unwritable or full storage container). A deliberate, non-editable screen:
/// it must NOT silently present an empty store the user could type into and lose. The on-disk
/// data is preserved (a corrupt store is moved aside, never deleted), so relaunching retries.
struct DatabaseUnavailableView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Surface.ink3)
            Text(String(localized: "Couldn't open your tasks"))
                .font(.serif(.title2).weight(.semibold))
                .foregroundStyle(Surface.ink)
            Text(String(localized: "GSD couldn't open its local storage. Your data hasn't been deleted. Please quit and reopen the app. If this keeps happening, free up some storage space, then try again."))
                .font(.body)
                .foregroundStyle(Surface.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Link(String(localized: "Contact support"), destination: URL(string: "mailto:gsdapp@vinny.dev")!)
                .font(.callout.weight(.medium))
                .foregroundStyle(Surface.tint)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.paper)
    }
}
