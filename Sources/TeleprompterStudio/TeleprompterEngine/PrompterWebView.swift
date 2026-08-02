import SwiftUI
import WebKit

/// Loads `prompter.html` (Markdown + bundled KaTeX renderer) from `Bundle.module` into a
/// `WKWebView`. This is the single source of truth for prompter text styling — the same HTML
/// bundle is served to the laptop browser by `LANHTTPServer`, so rendering is identical
/// everywhere.
struct PrompterWebView: UIViewRepresentable {
    var document: PrompterDocument
    var controller: PrompterController
    /// Interactive preview (editor) vs. read-only display (studio/companion) — controls
    /// whether the web content can receive scroll gestures directly from the user.
    var isInteractivePreview: Bool = false

    /// `prompter.html` references `../../SharedWebResources/...` for KaTeX/marked, so WKWebView
    /// needs read access to the whole resource bundle root (their common ancestor), not just
    /// `prompter.html`'s own directory.
    static func resourceDirectory() -> URL? {
        Bundle.module.resourceURL
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "prompter")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = isInteractivePreview
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator

        controller.attach(webView: webView)

        if let htmlURL = Bundle.module.url(forResource: "prompter", withExtension: "html", subdirectory: "TeleprompterEngine/Resources"),
           let readAccessURL = Self.resourceDirectory() {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: readAccessURL)
        }

        context.coordinator.pendingDocument = document
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.isPageReady {
            if context.coordinator.lastDocument != document {
                controller.loadDocument(document)
                context.coordinator.lastDocument = document
            }
        } else {
            context.coordinator.pendingDocument = document
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let controller: PrompterController
        var isPageReady = false
        var pendingDocument: PrompterDocument?
        var lastDocument: PrompterDocument?

        init(controller: PrompterController) {
            self.controller = controller
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" {
                isPageReady = true
                if let pendingDocument {
                    controller.loadDocument(pendingDocument)
                    lastDocument = pendingDocument
                }
            }
            controller.handleMessage(type: type, body: body)
        }
    }
}
