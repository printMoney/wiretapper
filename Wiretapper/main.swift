import AppKit

// This is where the app starts. It creates the app, connects our
// AppDelegate to it, and then keeps running until the user chooses Quit.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
