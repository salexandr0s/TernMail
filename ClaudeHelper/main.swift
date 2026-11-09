import Foundation

let listener = NSXPCListener.service()
let delegate = ClaudeCLIHelperListener()
listener.delegate = delegate
listener.resume()
