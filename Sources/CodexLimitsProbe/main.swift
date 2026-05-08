import CodexLimitsCore
import Foundation

@main
struct CodexLimitsProbe {
    static func main() async {
        let chain = ProviderChain()
        do {
            let snapshot = try await chain.fetchSnapshot()
            let data = try JSONEncoder.codexLimits.encode(snapshot)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            let payload = [
                "error": error.localizedDescription,
                "hint": "The live provider reads ~/.codex/auth.json and calls Codex's structured usage endpoint. It does not use screenshots, OCR, or Accessibility by default."
            ]
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data ?? Data("{}".utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
            Foundation.exit(1)
        }
    }
}
