import SwiftUI
import VisionKit
import UIKit
import AVFoundation
import Combine
import FirebaseFunctions
import FirebaseAuth
import FirebaseFirestore
import SafariServices

struct IdentityVerificationView: View {
    @Environment(\.dismiss) private var dismiss

    let onVerified: () -> Void

    @StateObject private var scanner = IdentityScannerController()
    @State private var showingInformation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if scanner.permissionDenied {
                    unavailableView(
                        icon: "camera.fill",
                        title: "Camera Access Needed",
                        message: "CareConnect needs camera access to begin identity verification. Enable Camera access in Settings, then try again."
                    )
                } else if scanner.isUnavailable {
                    unavailableView(
                        icon: "camera.viewfinder",
                        title: "Verification Unavailable",
                        message: "This device cannot use the identity verification camera."
                    )
                } else if let scannerView = scanner.scannerView {
                    IdentityScannerContainerView(
                        scannerView: scannerView
                    )
                    .ignoresSafeArea()
                    .overlay {
                        VStack {
                            Spacer()

                            RoundedRectangle(cornerRadius: 20)
                                .stroke(
                                    Color.white,
                                    lineWidth: 3
                                )
                                .frame(
                                    width: 320,
                                    height: 210
                                )

                            Text("Position your ID inside the frame")
                                .font(
                                    .subheadline.weight(.semibold)
                                )
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(
                                    .black.opacity(0.7)
                                )
                                .clipShape(Capsule())

                            Spacer()
                        }
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }

                if scanner.isProcessing {
                    Color.black
                        .opacity(0.65)
                        .ignoresSafeArea()

                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.15)

                        Text("Processing verification")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text(
                            "Your identity verification is being processed securely."
                        )
                        .font(.subheadline)
                        .foregroundColor(
                            .white.opacity(0.85)
                        )
                        .multilineTextAlignment(.center)
                    }
                    .padding(26)
                    .frame(maxWidth: 310)
                    .background(.ultraThinMaterial)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 20)
                    )
                }
            }
            .navigationTitle("Verify Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(
                .dark,
                for: .navigationBar
            )
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }

                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button {
                        showingInformation = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundColor(.white)
                    }
                }
            }

            // Information sheet
            .sheet(
                isPresented: $showingInformation
            ) {
                VerificationInformationView()
            }

            // Didit verification opens inside CareConnect
            // using Safari's secure in-app browser.
            .sheet(
                isPresented: $scanner.showDiditBrowser
            ) {
                if let url = scanner.verificationURL {
                    DiditSafariView(url: url)
                        .ignoresSafeArea()
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)

            .onAppear {
                scanner.start()
            }

            .onDisappear {
                scanner.stop()
            }

            // This fires only after the Firebase webhook
            // records status == "verified".
            .onReceive(
                scanner.$verificationCompleted
                    .filter { $0 }
            ) { _ in
                scanner.showDiditBrowser = false

                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.25
                ) {
                    onVerified()
                }
            }

            .alert(
                "Identity Verification",
                isPresented: $scanner.showMessage
            ) {
                Button("Try Again") {
                    scanner.reset()
                }

                Button("Close", role: .cancel) {}
            } message: {
                Text(scanner.message)
            }
        }
    }

    private func unavailableView(
        icon: String,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 52))

            Text(title)
                .font(.title2.bold())

            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundColor(.white)
        .padding()
    }
}

// MARK: - Didit In-App Safari

struct DiditSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(
        context: Context
    ) -> SFSafariViewController {
        let safariViewController =
            SFSafariViewController(url: url)

        safariViewController.dismissButtonStyle = .close

        return safariViewController
    }

    func updateUIViewController(
        _ uiViewController: SFSafariViewController,
        context: Context
    ) {
        // The verification URL does not change
        // while this screen is presented.
    }
}

// MARK: - Scanner Container

struct IdentityScannerContainerView:
    UIViewControllerRepresentable {

    let scannerView: UIViewController

    func makeUIViewController(
        context: Context
    ) -> UIViewController {
        scannerView
    }

    func updateUIViewController(
        _ uiViewController: UIViewController,
        context: Context
    ) {
        // Scanner manages its own session.
    }
}

// MARK: - Scanner Controller

@MainActor
final class IdentityScannerController:
    NSObject,
    ObservableObject {

    @Published var scannerView:
        UIViewController?

    @Published var permissionDenied = false

    @Published var isUnavailable = false

    @Published var isProcessing = false

    @Published var showMessage = false

    @Published var message = ""

    // Controls the in-app Didit browser.
    @Published var showDiditBrowser = false

    // URL returned by Firebase.
    @Published var verificationURL: URL?

    // Becomes true only after Firestore receives
    // the server-confirmed "verified" status.
    @Published var verificationCompleted = false

    private lazy var functions =
        Functions.functions(region: "us-central1")

    private var dataScanner:
        DataScannerViewController?

    private var hasProcessedScan = false

    private var isStarting = false

    // Firestore listener waiting for Didit's webhook result.
    private var verificationListener:
        ListenerRegistration?

    // MARK: - Start Didit Verification

    func startDiditVerification() {
        isProcessing = true
        message = ""
        verificationCompleted = false

        functions
            .httpsCallable("createIdentityVerification")
            .call { [weak self] result, error in

                DispatchQueue.main.async {
                    guard let self = self else {
                        return
                    }

                    if let error = error {
                        print(
                            "Didit session creation failed: "
                            + error.localizedDescription
                        )

                        self.isProcessing = false

                        self.message = """
                        We could not start identity verification.
                        Please try again.
                        """

                        self.showMessage = true
                        return
                    }

                    guard
                        let data =
                            result?.data as? [String: Any],
                        let verificationURLString =
                            data["verificationURL"] as? String,
                        let verificationURL =
                            URL(
                                string:
                                    verificationURLString
                            )
                    else {
                        print(
                            "Didit response was missing a verification URL."
                        )

                        self.isProcessing = false

                        self.message = """
                        Identity verification could not be started because the verification link was missing.
                        """

                        self.showMessage = true
                        return
                    }

                    print(
                        "Didit verification URL received."
                    )

                    self.verificationURL =
                        verificationURL

                    // Start listening before opening Didit.
                    self.listenForVerificationResult()

                    // Present Didit inside CareConnect.
                    self.showDiditBrowser = true
                }
            }
    }

    // MARK: - Firestore Verification Listener

    private func listenForVerificationResult() {
        guard
            let uid =
                Auth.auth().currentUser?.uid
        else {
            isProcessing = false

            message = """
            Your account could not be identified.
            Please sign in again.
            """

            showMessage = true
            return
        }

        verificationListener?.remove()
        verificationListener = nil

        let db = Firestore.firestore()

        print(
            "Listening for verification result for UID: \(uid)"
        )

        verificationListener = db
            .collection("verificationRecords")
            .document(uid)
            .addSnapshotListener {
                [weak self] snapshot, error in

                guard let self = self else {
                    return
                }

                if let error = error {
                    print(
                        "Verification listener error: "
                        + error.localizedDescription
                    )
                    return
                }

                guard
                    let data = snapshot?.data(),
                    let status =
                        data["status"] as? String
                else {
                    return
                }

                print(
                    "CareConnect verification status: \(status)"
                )

                DispatchQueue.main.async {
                    switch status {

                    case "verified":
                        print(
                            "Identity verification confirmed by Firebase."
                        )

                        self.isProcessing = false

                        self.verificationListener?.remove()
                        self.verificationListener = nil

                        self.verificationCompleted = true

                    case "rejected":
                        self.isProcessing = false

                        self.verificationListener?.remove()
                        self.verificationListener = nil

                        self.message = """
                        We could not verify your identity.
                        You can try again.
                        """

                        self.showMessage = true

                    case "needs_review":
                        self.isProcessing = false

                        self.verificationListener?.remove()
                        self.verificationListener = nil

                        self.message = """
                        Your identity verification needs additional review.
                        """

                        self.showMessage = true

                    case "processing":
                        self.isProcessing = true

                    case "not_started":
                        self.isProcessing = false

                    default:
                        break
                    }
                }
            }
    }

    // MARK: - Start

    func start() {
        guard !isStarting else {
            return
        }

        guard dataScanner == nil else {
            startScanningIfPossible()
            return
        }

        #if targetEnvironment(simulator)

        isUnavailable = true

        #else

        guard #available(iOS 16.0, *) else {
            isUnavailable = true
            return
        }

        guard DataScannerViewController.isSupported else {
            isUnavailable = true
            return
        }

        let authorizationStatus =
            AVCaptureDevice.authorizationStatus(
                for: .video
            )

        switch authorizationStatus {

        case .authorized:
            createScanner()

        case .notDetermined:
            requestCameraPermission()

        case .denied, .restricted:
            permissionDenied = true

        @unknown default:
            permissionDenied = true
        }

        #endif
    }

    // MARK: - Camera Permission

    private func requestCameraPermission() {
        guard !isStarting else {
            return
        }

        isStarting = true

        Task {
            let granted =
                await AVCaptureDevice.requestAccess(
                    for: .video
                )

            await MainActor.run {
                self.isStarting = false

                if granted {
                    self.permissionDenied = false
                    self.createScanner()
                } else {
                    self.permissionDenied = true
                }
            }
        }
    }

    // MARK: - Create Scanner

    private func createScanner() {
        guard #available(iOS 16.0, *) else {
            isUnavailable = true
            return
        }

        guard DataScannerViewController.isSupported else {
            isUnavailable = true
            return
        }

        guard DataScannerViewController.isAvailable else {
            isUnavailable = true
            return
        }

        let scanner =
            DataScannerViewController(
                recognizedDataTypes: [
                    .barcode(
                        symbologies: [
                            .qr,
                            .pdf417,
                            .code128,
                            .code39,
                            .code93,
                            .ean13,
                            .ean8,
                            .upce,
                            .itf14
                        ]
                    )
                ],
                qualityLevel: .balanced,
                recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: true,
                isPinchToZoomEnabled: true,
                isGuidanceEnabled: true,
                isHighlightingEnabled: true
            )

        scanner.delegate = self

        dataScanner = scanner
        scannerView = scanner

        DispatchQueue.main.async {
            [weak self] in

            self?.startScanningIfPossible()
        }
    }

    // MARK: - Start Scanning

    private func startScanningIfPossible() {
        guard #available(iOS 16.0, *) else {
            isUnavailable = true
            return
        }

        guard let scanner = dataScanner else {
            return
        }

        guard !scanner.isScanning else {
            return
        }

        guard DataScannerViewController.isAvailable else {
            isUnavailable = true
            return
        }

        do {
            try scanner.startScanning()
        } catch {
            message =
                "The identity scanner could not start: "
                + error.localizedDescription

            isUnavailable = true
        }
    }

    // MARK: - Stop

    func stop() {
        #if !targetEnvironment(simulator)

        if #available(iOS 16.0, *) {
            dataScanner?.stopScanning()
        }

        #endif
    }

    // MARK: - Reset

    func reset() {
        stop()

        verificationListener?.remove()
        verificationListener = nil

        verificationURL = nil
        showDiditBrowser = false
        verificationCompleted = false

        hasProcessedScan = false

        showMessage = false
        message = ""

        isProcessing = false

        permissionDenied = false
        isUnavailable = false

        dataScanner = nil
        scannerView = nil

        start()
    }

    // MARK: - Process Scan

    private func processScan(_ value: String) {
        guard !hasProcessedScan else {
            return
        }

        hasProcessedScan = true

        // The barcode is only the trigger for starting
        // identity verification. It is not proof of identity.
        stop()

        startDiditVerification()
    }
}

// MARK: - Scanner Delegate

@available(iOS 16.0, *)
extension IdentityScannerController:
    DataScannerViewControllerDelegate {

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        for item in addedItems {

            if case .barcode(let barcode) = item,
               let value =
                barcode.payloadStringValue {

                processScan(value)
                break
            }
        }
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didRemove removedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        // Nothing needed here.
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        becameUnavailableWithError error: Error
    ) {
        isUnavailable = true

        message =
            "The identity scanner became unavailable: "
            + error.localizedDescription
    }
}

// MARK: - Information Sheet

struct VerificationInformationView: View {
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: 20
                ) {
                    Image(
                        systemName:
                            "checkmark.shield.fill"
                    )
                    .font(.system(size: 50))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)

                    Text("Why verify your identity?")
                        .font(.title2.bold())

                    Text(
                        "CareConnect uses identity verification to help create a safer community for people giving and receiving assistance."
                    )

                    Text("Your privacy matters")
                        .font(.headline)

                    Text(
                        "CareConnect should only retain the minimum information needed to establish your verification status. Government identification numbers and document images should not be displayed on your public CareConnect profile."
                    )

                    Text(
                        "Verification is not a background check"
                    )
                    .font(.headline)

                    Text(
                        "Identity verification confirms identity information. It does not by itself establish that someone is safe, trustworthy, or eligible for every type of volunteer activity. Additional screening may be required for certain roles."
                    )
                }
                .padding()
            }
            .navigationTitle("About Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(
                    placement: .confirmationAction
                ) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
