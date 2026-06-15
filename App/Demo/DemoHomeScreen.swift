import SwiftUI
import WidgetKit
import GSDSnapshot

/// Demo-only faux iOS Home Screen for the marketing video's "Today's Focus widget" beat.
/// Renders the real `TodaysFocusView` in a Home-Screen tile among generic app icons.
/// Reachable ONLY when launched with `--demo-home` (the choreography test passes it; the app
/// never does), so this is unreachable in normal and App Store launches.
struct DemoHomeScreen: View {
    static let launchArgument = "--demo-home"

    @State private var appeared = false

    // The widget echoes the three Do-First tasks the rest of the demo already showed.
    private let entry = TodaysFocusEntry(
        date: Date(),
        snapshot: WidgetSnapshot(
            generatedAt: Date(),
            tasks: [
                WidgetTask(id: "demo-finance",  title: "Get finance sign-off", dueDate: nil),
                WidgetTask(id: "demo-deck",     title: "Finish the Q3 board deck", dueDate: nil),
                WidgetTask(id: "demo-investor", title: "Reply to the investor email", dueDate: nil),
            ],
            totalCount: 3))

    private let gridIcons: [(symbol: String, fill: Color, brand: Bool)] = [
        ("target",         Surface.surface,                        true),   // GSD's own motif (trademark-safe)
        ("envelope.fill",  Color(light: 0x4F6D7A, dark: 0x4F6D7A), false),
        ("calendar",       Color(light: 0xB23A2E, dark: 0xB23A2E), false),
        ("camera.fill",    Color(light: 0x6E6760, dark: 0x6E6760), false),
        ("map.fill",       Color(light: 0x3E7D52, dark: 0x3E7D52), false),
        ("music.note",     Color(light: 0x8A6A22, dark: 0x8A6A22), false),
        ("phone.fill",     Color(light: 0x2C6680, dark: 0x2C6680), false),
        ("gearshape.fill", Color(light: 0x4A4A4A, dark: 0x4A4A4A), false),
    ]

    var body: some View {
        ZStack {
            wallpaper.ignoresSafeArea()
            // The simulator supplies the real status bar + Dynamic Island above this, so the
            // VStack (which respects the safe area) sits just below it — no faux status bar needed.
            VStack(spacing: 28) {
                widgetTile
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                appGrid
                Spacer(minLength: 0)
                dock
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .accessibilityIdentifier("demo-home-screen")
        .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.3)) { appeared = true } }
    }

    private var wallpaper: LinearGradient {
        LinearGradient(colors: [Color(light: 0xEFE6D2, dark: 0x17150F),
                                Color(light: 0xDDCFAF, dark: 0x100E0A)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var widgetTile: some View {
        TodaysFocusView(entry: entry)
            .tint(Surface.tint)
            .padding(16)
            .frame(height: 158)
            .frame(maxWidth: .infinity)
            .background(Surface.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
    }

    private var appGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4), spacing: 18) {
            ForEach(gridIcons.indices, id: \.self) { i in
                appIcon(symbol: gridIcons[i].symbol, fill: gridIcons[i].fill, isBrand: gridIcons[i].brand)
            }
        }
    }

    private var dock: some View {
        HStack(spacing: 18) {
            appIcon(symbol: "message.fill", fill: Color(light: 0x3E7D52, dark: 0x3E7D52), isBrand: false)
            appIcon(symbol: "safari.fill",  fill: Color(light: 0x2C6680, dark: 0x2C6680), isBrand: false)
            appIcon(symbol: "photo.fill",   fill: Color(light: 0xB23A2E, dark: 0xB23A2E), isBrand: false)
            appIcon(symbol: "note.text",    fill: Color(light: 0x8A6A22, dark: 0x8A6A22), isBrand: false)
        }
        .padding(.vertical, 14).padding(.horizontal, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private func appIcon(symbol: String, fill: Color, isBrand: Bool) -> some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(fill)
            .frame(width: 58, height: 58)
            .overlay(Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isBrand ? Surface.ink : .white))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}
