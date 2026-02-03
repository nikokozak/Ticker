import AppKit
import WebKit

/// WKWebView subclass that handles file drag-and-drop
/// Based on: https://stackoverflow.com/questions/25096910/receiving-nsdraggingdestination-messages-with-a-wkwebview
class DroppableWebView: WKWebView {
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // Register for file URL drags
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasFileURLs(sender) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasFileURLs(sender) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = getFileURLs(from: sender), !urls.isEmpty else {
            return super.performDragOperation(sender)
        }

        DebugLog.log("DroppableWebView: Received \(urls.count) file(s)")
        onFilesDropped?(urls)
        return true
    }

    // MARK: - Helpers

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        return sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    private func getFileURLs(from sender: NSDraggingInfo) -> [URL]? {
        return sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }
}
