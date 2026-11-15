import Foundation

public func wholeLines(_ height: CGFloat, line: CGFloat) -> CGFloat {
    max(line, ceil((height - 0.01) / line) * line)
}
