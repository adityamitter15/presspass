import Foundation
import PushupEval

func writeStandardError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

exit(CLI.main(
    arguments: Array(CommandLine.arguments.dropFirst()),
    out: { print($0) },
    err: writeStandardError
))
