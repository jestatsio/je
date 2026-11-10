import Foundation
import JECore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(FoundationModels)
import FoundationModels
#endif

// Evaluation-only Q11 helper. One JSON request on stdin, one JSON
// response on stdout. Input text is never echoed in errors.

private func respond(_ response: FoundationHelperResponse, code: Int32) -> Never {
    if let data = try? StableJSON.encodeLine(response) {
        FileHandle.standardOutput.write(data)
    }
    exit(code)
}

private func fail() -> Never {
    respond(FoundationHelperResponse(ok: false), code: 2)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= 16 * 1024,
      let request = try? JSONDecoder().decode(FoundationHelperRequest.self, from: input),
      request.schemaVersion == 1 else {
    fail()
}

func availabilityLabel() -> (available: Bool, reason: String?) {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, nil)
        case .unavailable(.deviceNotEligible):
            return (false, "deviceNotEligible")
        case .unavailable(.appleIntelligenceNotEnabled):
            return (false, "appleIntelligenceNotEnabled")
        case .unavailable(.modelNotReady):
            return (false, "modelNotReady")
        case .unavailable:
            return (false, "other")
        }
    }
    return (false, "operatingSystemTooOld")
    #else
    return (false, "unsupportedPlatform")
    #endif
}

switch request.operation {
case "availability":
    guard request.text == nil else { fail() }
    let state = availabilityLabel()
    respond(
        FoundationHelperResponse(ok: true, available: state.available, reason: state.reason),
        code: 0
    )
case "title":
    guard let text = request.text,
          !text.isEmpty,
          text.count <= TitlingEvaluationRunner.maximumInputCharacters,
          !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
        fail()
    }
    #if canImport(FoundationModels)
    guard #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable else {
        fail()
    }
    let semaphore = DispatchSemaphore(value: 0)
    var generated: String?
    var generatedFailed = false
    Task {
        let session = LanguageModelSession(
            instructions: "Write a short title of at most six words for the user's text. Reply with the title only."
        )
        do {
            generated = try await session.respond(to: text).content
        } catch {
            generatedFailed = true
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 25) == .success,
          !generatedFailed,
          let generated else {
        fail()
    }
    let cleaned = TitlingEvaluationRunner.sanitize(generated)
    guard !cleaned.isEmpty else { fail() }
    respond(FoundationHelperResponse(ok: true, title: cleaned), code: 0)
    #else
    fail()
    #endif
default:
    fail()
}
