import Foundation

// rondo-cli — headless harness over the same engines the app uses.
// See `rondo-cli help`.
let status = await CLI.run(Array(CommandLine.arguments.dropFirst()))
exit(status)
