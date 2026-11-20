import Foundation
import Darwin

do { try ScrollStitcher.selfTest() } catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
