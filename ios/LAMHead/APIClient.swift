import Foundation

enum APIError: LocalizedError {
    case invalidData

    var errorDescription: String? {
        switch self {
        case .invalidData: return "收到的資料格式不正確"
        }
    }
}
