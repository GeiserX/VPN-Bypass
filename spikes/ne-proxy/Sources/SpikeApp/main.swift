import AppKit

// A first argument that is not a flag runs the command-line mode (CLI.swift), which prints the usage
// for an unknown command. No arguments, or only flags (Launch Services and AppKit pass `-psn_…`,
// `-NS…`), open the window.
let args = Array(CommandLine.arguments.dropFirst())
if let first = args.first, !first.hasPrefix("-") {
    CLI.run(args)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
