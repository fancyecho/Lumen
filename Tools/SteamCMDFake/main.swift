import Foundation

// Drives SteamCMDSession against a fake steamcmd script and prints the events it parses.
// Usage: steamcmd-fake <fake-steamcmd.sh> <output folder>
let script = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let session = SteamCMDSession(arguments: ["+force_install_dir", output.path], script: script)
session.onEvent = { event in
    switch event {
    case .output: break
    case .needsPassword: print("EVENT needsPassword"); session.send("secret")
    case .needsGuardCode(let email): print("EVENT needsGuardCode email=\(email)"); session.send("ABCDE")
    default: print("EVENT", event)
    }
}
let done = DispatchSemaphore(value: 0)
Task { let status = await session.run(); print("exit", status); done.signal() }
done.wait()
