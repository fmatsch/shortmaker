import Foundation

let args = CommandLine.arguments
if args.count > 1, args[1] == "--selftest" {
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached { code = await SelfTest.run(Array(args.dropFirst(2))); sema.signal() }
    sema.wait()
    exit(code)
} else {
    ShortMakerApp.main()
}
