// Two-tier swipe on a row, both directions: a short drag arms the first
// action, a longer one the second. Each threshold ticks with a haptic and
// the revealed colour/icon changes, so the user always knows what letting go
// will do. The system's swipeActions can't do distance tiers, hence this.
//
// Which action sits on which tier comes from Settings (AppModel.swipeActions).

import SwiftUI

struct SwipeAction {
    let title: String
    let systemImage: String
    let tint: Color
    let perform: () -> Void
}

struct SwipeableRow<Content: View>: View {
    /// Revealed when dragging to the right; index 0 = short, 1 = long.
    let leading: [SwipeAction]
    /// Revealed when dragging to the left; index 0 = short, 1 = long.
    let trailing: [SwipeAction]
    /// Opaque colour behind the content so the revealed panel hides under it.
    let background: Color
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var tier = 0 // -2, -1, 0, 1, 2 (negative = trailing)
    @State private var dragging = false

    private let shortThreshold: CGFloat = 72
    private let longThreshold: CGFloat = 150

    private var armed: SwipeAction? {
        switch tier {
        case 1: leading.first
        case 2: leading.count > 1 ? leading[1] : leading.first
        case -1: trailing.first
        case -2: trailing.count > 1 ? trailing[1] : trailing.first
        default: nil
        }
    }

    var body: some View {
        ZStack {
            // The revealed panel fills the whole row height, whatever the
            // content's height is.
            if let action = armed {
                HStack {
                    if tier < 0 { Spacer(minLength: 0) }
                    VStack(spacing: 3) {
                        Image(systemName: action.systemImage).font(.title3.weight(.semibold))
                        Text(action.title).font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .frame(width: max(abs(offset), 64))
                    if tier > 0 { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(action.tint)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.12), value: tier)
            }
            // The row itself tracks the finger; only the revealed action animates.
            content()
                .background(background)
                .offset(x: offset)
        }
        .clipped()
        .gesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // Vertical intent belongs to the list; only take clearly horizontal drags.
                    guard dragging || abs(dx) > abs(dy) * 1.5 else { return }
                    dragging = true
                    offset = rubberBand(dx)
                    let newTier: Int
                    switch abs(dx) {
                    case ..<shortThreshold: newTier = 0
                    case ..<longThreshold: newTier = dx > 0 ? 1 : -1
                    default: newTier = dx > 0 ? 2 : -2
                    }
                    if newTier != tier {
                        tier = newTier
                        if newTier != 0 { Haptics.light() }
                    }
                }
                .onEnded { _ in
                    let action = armed
                    withAnimation(.spring(duration: 0.3)) {
                        offset = 0
                        tier = 0
                    }
                    dragging = false
                    action?.perform()
                }
        )
        .accessibilityActions {
            ForEach(Array((leading + trailing).enumerated()), id: \.offset) { _, a in
                Button(a.title, action: a.perform)
            }
        }
    }

    /// Past the long threshold the row resists, so the gesture reads as "done".
    private func rubberBand(_ dx: CGFloat) -> CGFloat {
        let limit = longThreshold + 24
        if abs(dx) <= limit { return dx }
        let extra = abs(dx) - limit
        return (limit + extra * 0.25) * (dx < 0 ? -1 : 1)
    }
}
