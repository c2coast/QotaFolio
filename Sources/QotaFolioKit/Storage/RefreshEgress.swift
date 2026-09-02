import Foundation
import QotaFolioCore

nonisolated enum RefreshEgress {
    private static let anthropicClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let openAIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func materialize(
        _ route: OAuthRefreshRoute,
        injecting refreshToken: SecretString
    ) -> URLRequest {
        switch route {
        case .anthropic:
            return anthropicRequest(refreshToken: refreshToken)
        case .openAI:
            return openAIRequest(refreshToken: refreshToken)
        }
    }

    private static func anthropicRequest(refreshToken: SecretString) -> URLRequest {
        let url = URL(string: "https://platform.claude.com/v1/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        refreshToken.withUnsafeRawValue { token in
            let body = "{\"client_id\":\(jsonStringLiteral(anthropicClientID)),"
                + "\"grant_type\":\"refresh_token\","
                + "\"refresh_token\":\(jsonStringLiteral(token))}"
            request.httpBody = Data(body.utf8)
        }
        return request
    }

    private static func openAIRequest(refreshToken: SecretString) -> URLRequest {
        let url = URL(string: "https://auth.openai.com/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        refreshToken.withUnsafeRawValue { token in
            let fields = [
                ("grant_type", "refresh_token"),
                ("client_id", openAIClientID),
                ("refresh_token", token),
            ]
            let body = fields
                .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
                .joined(separator: "&")
            request.httpBody = Data(body.utf8)
        }
        return request
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var output = [UInt8]()
        output.append(UInt8(ascii: "\""))

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case 0x5c:
                output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x00...0x1f:
                output.append(contentsOf: [
                    UInt8(ascii: "\\"), UInt8(ascii: "u"),
                    UInt8(ascii: "0"), UInt8(ascii: "0"),
                    hexadecimal[Int(scalar.value >> 4)],
                    hexadecimal[Int(scalar.value & 0x0f)],
                ])
            default:
                output.append(contentsOf: String(scalar).utf8)
            }
        }
        output.append(UInt8(ascii: "\""))
        return String(decoding: output, as: UTF8.self)
    }

    private static func formEncode(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var output = [UInt8]()
        output.reserveCapacity(value.utf8.count)

        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                output.append(byte)
            case UInt8(ascii: " "):
                output.append(UInt8(ascii: "+"))
            default:
                output.append(UInt8(ascii: "%"))
                output.append(hexadecimal[Int(byte >> 4)])
                output.append(hexadecimal[Int(byte & 0x0f)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
