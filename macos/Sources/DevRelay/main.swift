import DisteeCore
import DisteeTestSupport
import Foundation

// Development-only local relay. Not part of the product: the real relay is a Cloudflare
// Worker (Phase 3). Used to exercise the agent's connection, auth and reconnection paths
// without deploying anything.
//
//   swift run distee-devrelay [port]
//   open Distee.app --args --dev-relay ws://127.0.0.1:8799

let arguments = CommandLine.arguments.dropFirst()
let port = UInt16(arguments.first ?? "8799") ?? 8799

do {
    let server = try MiniRelayServer(port: port)
    server.verbose = true
    server.onText = { _, text in
        print("[relay] frame: \(text.prefix(160))")
    }
    try server.start()
    print("Distee development relay listening on \(server.url.absoluteString)/ws/device/<deviceId>")
    print("Start the agent with: Distee.app/Contents/MacOS/Distee --dev-relay \(server.url.absoluteString)")
    fflush(stdout)
    RunLoop.main.run()
    withExtendedLifetime(server) {}
} catch {
    FileHandle.standardError.write(Data("dev relay failed to start: \(error)\n".utf8))
    exit(1)
}
