import AVFoundation
import Photos

/// Centralizes the three permission prompts this app needs (camera, mic, photo add-only) so
/// Studio can request/explain/handle denial in one place instead of scattering `AVCaptureDevice`
/// calls through the UI layer.
enum CameraAuthorization {
    struct Status {
        var camera: AVAuthorizationStatus
        var microphone: AVAuthorizationStatus
        var photos: PHAuthorizationStatus

        var isFullyAuthorized: Bool {
            camera == .authorized && microphone == .authorized && (photos == .authorized || photos == .limited)
        }

        var isDenied: Bool {
            camera == .denied || camera == .restricted
            || microphone == .denied || microphone == .restricted
        }
    }

    static func currentStatus() -> Status {
        Status(
            camera: AVCaptureDevice.authorizationStatus(for: .video),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            photos: PHPhotoLibrary.authorizationStatus(for: .addOnly)
        )
    }

    static func requestAll() async -> Status {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return currentStatus()
    }
}
