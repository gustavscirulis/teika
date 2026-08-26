import Foundation

enum TeikaURL {
    static let scheme = "teika"
    static let recordHost = "record"
    static let record = URL(string: "\(scheme)://\(recordHost)")!
}
