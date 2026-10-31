import SwiftUI

struct CalendarWeekdayHeader: View {
    let calendar: Calendar
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(0..<7) { offset in
                    Text(calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7])
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: geometry.size.width / 7, height: Tokens.Space.s8)
                }
            }
        }.frame(height: Tokens.Space.s8)
    }
}
