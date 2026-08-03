import AVFoundation
import Photos

/// Wraps `AVCaptureMovieFileOutput` for the two straightforward recording paths: no cinematic
/// effect, and real hardware Cinematic capture (which Apple implements by embedding
/// disparity/focus metadata straight into the movie file when
/// `isCinematicVideoCaptureEnabled` is set on the active device input — no manual frame
/// compositing required).
final class MovieFileRecorder: NSObject {
    private let output: AVCaptureMovieFileOutput
    private var continuation: CheckedContinuation<URL, Error>?
    private(set) var isRecording = false
    private var startedAt: Date?

    var elapsedProvider: (() -> TimeInterval)? {
        didSet {}
    }

    init(output: AVCaptureMovieFileOutput) {
        self.output = output
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    func start() throws -> URL {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        // Rotation is kept live on this connection by `AVCameraSession`'s RotationCoordinator
        // observers, so no explicit angle needs to be set here — doing so would just stomp on
        // whatever the device's current physical orientation actually is.
        output.startRecording(to: outputURL, recordingDelegate: self)
        isRecording = true
        startedAt = Date()
        return outputURL
    }

    func stop() async throws -> URL {
        guard isRecording else { throw RecorderError.notRecording }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            output.stopRecording()
        }
    }
}

extension MovieFileRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        isRecording = false
        startedAt = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: outputFileURL)
        }
        continuation = nil
    }
}

enum RecorderError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "No recording is currently in progress."
        case .saveFailed(let reason): return "Failed to save recording: \(reason)"
        }
    }
}

/// Persists a finished recording into the app's own Documents/Recordings folder, and optionally
/// into the user's Photos library.
enum RecordingFileStore {
    static func persist(temporaryURL: URL, saveToPhotos: Bool) async throws -> (relativePath: String, savedToPhotos: Bool) {
        let recordingsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let filename = temporaryURL.lastPathComponent
        let destination = recordingsDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        var saved = false
        if saveToPhotos {
            saved = (try? await saveToPhotoLibrary(url: destination)) ?? false
        }
        return (filename, saved)
    }

    private static func saveToPhotoLibrary(url: URL) async throws -> Bool {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
        return true
    }
}
