import AppKit
import WebKit

final class TransportTest: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    let bytes = Data([0, 137, 80, 78, 71, 13, 10, 255])
    let filename = "截图 café.png"
    var csp = ""
    var received = false
    var webview: WKWebView!

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let request = task.request
        if request.url?.scheme == "tauri" {
            task.didReceive(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": "text/html", "Content-Security-Policy": csp
            ])!)
            task.didReceive(Data("<!doctype html><title>IPC transport test</title>".utf8))
            task.didFinish()
            return
        }
        guard request.httpMethod == "POST",
              request.httpBody == bytes,
              request.value(forHTTPHeaderField: "X-Filename")?.removingPercentEncoding == filename else {
            fail("Native IPC received different bytes or filename: \(request)")
        }
        received = true
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
            "Access-Control-Allow-Origin": "*",
            "Content-Type": "text/plain"
        ])!
        task.didReceive(response)
        task.didReceive(Data("staged".utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.body as? String == "staged", received else {
            fail("Binary IPC blocked before native handler: \(message.body); native received: \(received)")
        }
        print("PASS: 1 WKWebView binary IPC transport test (exact bytes and Unicode filename)")
        exit(0)
    }

    func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }

    func run(configPath: String) throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configPath))) as! [String: Any]
        let app = config["app"] as! [String: Any]
        let security = app["security"] as! [String: Any]
        csp = security["csp"] as! String
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: "ipc")
        configuration.setURLSchemeHandler(self, forURLScheme: "tauri")
        configuration.userContentController.add(self, name: "result")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            fetch('ipc://localhost/stage_attachment_bytes', {
                method: 'POST',
                headers: { 'Content-Type': 'application/octet-stream', 'X-Filename': encodeURIComponent('截图 café.png') },
                body: new Uint8Array([0, 137, 80, 78, 71, 13, 10, 255])
            }).then(response => response.text()).then(
                result => window.webkit.messageHandlers.result.postMessage(result),
                error => window.webkit.messageHandlers.result.postMessage(String(error))
            );
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webview = WKWebView(frame: .zero, configuration: configuration)
        webview.load(URLRequest(url: URL(string: "tauri://localhost")!))
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.fail("Timed out waiting for binary IPC") }
    }
}

let application = NSApplication.shared
let test = TransportTest()
do {
    try test.run(configPath: CommandLine.arguments.dropFirst().first ?? "desktop/src-tauri/tauri.conf.json")
    application.run()
} catch {
    test.fail(String(describing: error))
}
