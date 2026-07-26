import Foundation

enum ServerProbe {
    private static let compatibleEndpoints = [
        "/run_voice_clone",
        "/generate_voice_clone"
    ]

    static func isCompatibleInfo(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let endpoints = dictionary["named_endpoints"] as? [String: Any]
        else {
            return false
        }

        return compatibleEndpoints.contains { endpoints[$0] != nil }
    }
}
