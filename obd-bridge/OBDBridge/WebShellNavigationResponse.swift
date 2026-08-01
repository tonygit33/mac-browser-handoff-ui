import WebKit

extension WebShellView.Coordinator {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse,
           !(200...399).contains(response.statusCode) {
            decisionHandler(.cancel)
            if let fallback = Bundle.main.url(forResource: "obd-shell-fallback", withExtension: "html") {
                DispatchQueue.main.async {
                    webView.loadFileURL(fallback, allowingReadAccessTo: fallback.deletingLastPathComponent())
                }
            }
            return
        }
        decisionHandler(.allow)
    }
}
