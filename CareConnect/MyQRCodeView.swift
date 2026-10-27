import SwiftUI
import FirebaseAuth
import FirebaseFunctions
import CoreImage.CIFilterBuiltins

struct MyQRCodeView: View {
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    @State private var verificationURL: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var secondsRemaining = 0
    @State private var timer: Timer?

    private let functions = Functions.functions(region: "us-central1")

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                WordSpeakableText(
                    text: "Show this QR code to another CareConnect user to verify your identity."
                )
                .font(.system(size: 17))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

                if isLoading {

                    ProgressView("Creating secure QR code...")
                        .font(.system(size: 17))
                        .padding(.vertical, 30)

                } else if let verificationURL = verificationURL,
                          secondsRemaining > 0 {

                    if let qrImage = generateQRCode(from: verificationURL) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 260, height: 260)
                            .padding(20)
                            .background(Color.white)
                            .cornerRadius(16)
                            .shadow(
                                radius: 6,
                                x: 0,
                                y: 3
                            )
                    }

                    VStack(spacing: 8) {
                        WordSpeakableText(text: "Expires in")
                            .font(.system(size: 17))
                            .fontWeight(
                                accessibilitySettings.boldText
                                ? .bold
                                : .regular
                            )

                        Text("\(secondsRemaining) seconds")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(
                                secondsRemaining <= 30
                                ? .red
                                : .blue
                            )
                    }

                    WordSpeakableText(
                        text: "This QR code is temporary and can only be used once."
                    )
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                } else {

                    Image(systemName: "qrcode")
                        .font(.system(size: 80))
                        .foregroundColor(.secondary)
                        .padding(.top, 30)

                    WordSpeakableText(
                        text: "Generate a temporary QR code when you are ready to verify your identity."
                    )
                    .font(.system(size: 17))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                }

                if let errorMessage = errorMessage {
                    WordSpeakableText(text: errorMessage)
                        .font(.system(size: 15))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button(action: {
                    createQRCode()
                }) {
                    HStack {
                        Image(systemName: "qrcode")

                        Text(
                            verificationURL != nil && secondsRemaining <= 0
                            ? "Generate New QR Code"
                            : "Generate QR Code"
                        )
                    }
                    .font(
                        .system(
                            size: 17,
                            weight: accessibilitySettings.boldText
                            ? .bold
                            : .semibold
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(isLoading)
                .padding(.horizontal)

                WordSpeakableText(
                    text: "Your personal information is not stored in the QR code."
                )
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }
            .padding(.vertical, 20)
        }
        .navigationTitle("My QR Code")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            stopTimer()
        }
    }

    // MARK: - Create QR Token

    private func createQRCode() {
        guard Auth.auth().currentUser != nil else {
            errorMessage = "You must be signed in to generate a QR code."
            return
        }

        stopTimer()

        isLoading = true
        errorMessage = nil
        verificationURL = nil
        secondsRemaining = 0

        functions.httpsCallable("createQRCodeToken").call { result, error in
            DispatchQueue.main.async {
                isLoading = false

                if let error = error {
                    print("QR CODE ERROR:", error)
                    print(
                        "QR CODE ERROR DESCRIPTION:",
                        error.localizedDescription
                    )

                    let nsError = error as NSError

                    print(
                        "QR CODE ERROR DOMAIN:",
                        nsError.domain
                    )

                    print(
                        "QR CODE ERROR CODE:",
                        nsError.code
                    )

                    print(
                        "QR CODE ERROR USER INFO:",
                        nsError.userInfo
                    )

                    errorMessage = firebaseErrorMessage(
                        error,
                        nsError: nsError
                    )

                    return
                }

                guard
                    let data = result?.data as? [String: Any],
                    let success = data["success"] as? Bool,
                    success,
                    let url = data["verificationURL"] as? String,
                    let expiresIn = data["expiresInSeconds"] as? Int
                else {
                    errorMessage = "The QR code could not be created."
                    return
                }

                verificationURL = url
                secondsRemaining = expiresIn

                startTimer()
            }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()

        timer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { _ in
            DispatchQueue.main.async {
                if secondsRemaining > 0 {
                    secondsRemaining -= 1
                } else {
                    stopTimer()
                    verificationURL = nil
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - QR Generation

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scaleX = 1000 / outputImage.extent.width
        let scaleY = 1000 / outputImage.extent.height

        let transformedImage = outputImage.transformed(
            by: CGAffineTransform(
                scaleX: scaleX,
                y: scaleY
            )
        )

        guard let cgImage = context.createCGImage(
            transformedImage,
            from: transformedImage.extent
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - Firebase Error Handling

    private func firebaseErrorMessage(
        _ error: Error,
        nsError: NSError
    ) -> String {

        if nsError.domain == FunctionsErrorDomain {
            if let code = FunctionsErrorCode(rawValue: nsError.code) {
                switch code {

                case .unauthenticated:
                    return "You must be signed in to generate a QR code."

                case .failedPrecondition:
                    return "Your identity must be verified before generating a QR code."

                case .permissionDenied:
                    return "You do not have permission to generate a QR code."

                case .notFound:
                    return "The QR code service could not be found."

                case .unavailable:
                    return "The QR code service is temporarily unavailable. Please try again."

                case .deadlineExceeded:
                    return "The QR code request timed out. Please try again."

                case .resourceExhausted:
                    return "Too many QR code requests. Please wait and try again."

                default:
                    break
                }
            }
        }

        return "Firebase Error: \(error.localizedDescription)"
    }
}
