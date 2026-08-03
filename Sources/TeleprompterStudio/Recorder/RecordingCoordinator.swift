import AVFoundation
import Observation
import SwiftData

enum CinematicMode: String, CaseIterable {
    case off
    case cinematic
}

/// Chooses between the plain/real-cinematic `MovieFileRecorder` path and the
/// `SyntheticCinematicPipeline` path based on device capability + user toggle, and persists the
/// finished take as a `Recording` model + optional Photos save.
@MainActor
@Observable
final class RecordingCoordinator {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastError: String?

    /// Raised when capture stops by itself mid-take, so Studio can drop out of the recording UI
    /// and tell the user why rather than sitting on a frozen timer.
    var onRecordingFailed: ((String) -> Void)?

    private var movieRecorder: MovieFileRecorder?
    private let syntheticPipeline = SyntheticCinematicPipeline()
    private var usingSynthetic = false
    private var elapsedTimer: Timer?
    private var recordingStartDate: Date?

    var synthetic: SyntheticCinematicPipeline { syntheticPipeline }

    func start(
        session: AVCameraSession,
        cinematicKind: CinematicKind,
        resolution: CaptureResolution,
        saveToPhotos: Bool
    ) throws {
        guard !isRecording else { return }
        guard session.captureSession.isRunning else { throw RecorderError.sessionNotRunning }

        switch cinematicKind {
        case .none, .real:
            let recorder = MovieFileRecorder(output: session.movieFileOutput)
            recorder.onUnexpectedStop = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.stopElapsedTimer()
                    self.isRecording = false
                    self.movieRecorder = nil
                    self.elapsed = 0
                    self.recordingStartDate = nil
                    let message = error?.localizedDescription ?? "Recording stopped unexpectedly."
                    self.lastError = message
                    self.onRecordingFailed?(message)
                }
            }
            _ = try recorder.start()
            movieRecorder = recorder
            usingSynthetic = false
        case .synthetic:
            _ = try syntheticPipeline.start(dimensions: resolution.dimensions)
            usingSynthetic = true
        }

        isRecording = true
        recordingStartDate = Date()
        startElapsedTimer()
    }

    func stop(
        script: Script?,
        cinematicKind: CinematicKind,
        cameraFacing: CameraFacing,
        resolution: CaptureResolution,
        saveToPhotos: Bool,
        modelContext: ModelContext
    ) async {
        guard isRecording else { return }
        stopElapsedTimer()
        isRecording = false

        do {
            let finishedURL: URL
            if usingSynthetic {
                finishedURL = try await syntheticPipeline.stop()
            } else if let movieRecorder {
                finishedURL = try await movieRecorder.stop()
            } else {
                return
            }

            let (relativePath, saved) = try await RecordingFileStore.persist(temporaryURL: finishedURL, saveToPhotos: saveToPhotos)

            let dims = resolution.dimensions
            let recording = Recording(
                script: script,
                relativePath: relativePath,
                durationSec: elapsed,
                isCinematic: cinematicKind != .none,
                cinematicKind: cinematicKind,
                cameraFacing: cameraFacing,
                resolutionWidth: dims.width,
                resolutionHeight: dims.height
            )
            recording.savedToPhotos = saved
            modelContext.insert(recording)
            try? modelContext.save()
        } catch {
            lastError = error.localizedDescription
            onRecordingFailed?(error.localizedDescription)
        }

        movieRecorder = nil
        elapsed = 0
        recordingStartDate = nil
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        // 0.5s, not 0.2s: the timecode readout has one-second resolution, so a faster tick only
        // bought extra SwiftUI invalidations of everything observing `elapsed`.
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
