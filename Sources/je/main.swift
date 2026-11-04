import Foundation
import JECore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let result = JECommandLine.run(Array(CommandLine.arguments.dropFirst()))
if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(result.code)
