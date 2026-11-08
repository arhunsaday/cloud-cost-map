import CryptoKit
import Foundation

/// The two primitives Signature Version 4 needs, kept apart from the signer so
/// the rest of the AWS code has no CryptoKit dependency.
enum AWSCrypto {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
}
