import SwiftUI

struct StatusBadge: View {
    let status: TransactionStatus

    var body: some View {
        Circle()
            .fill(Color(hex: status.dotColor))
            .frame(width: 6, height: 6)
            .accessibilityLabel(status.displayName)
    }
}
