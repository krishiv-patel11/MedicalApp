import SwiftUI
import VisionKit
import UIKit
import AVFoundation

// MARK: - Scanned Medication

struct ScannedMedication: Identifiable {
    let id = UUID()
    let barcode: String
    let brandName: String?
    let genericName: String?
    let activeIngredients: [String]
    let strength: String?
    let dosageForm: String?
    let route: String?
    let manufacturer: String?
    let indications: String?
    let warnings: String?
    let contraindications: String?
    let dosageAndAdministration: String?
    let adverseReactions: String?
    let sourceName: String
    let sourceURL: String?

    var displayName: String {
        brandName ?? genericName ?? "Medication"
    }

    var displayDosage: String {
        switch (strength, dosageForm) {
        case let (strength?, form?):
            return "\(strength) \(form)"

        case let (strength?, nil):
            return strength

        case let (nil, form?):
            return form

        default:
            return ""
        }
    }
}

// MARK: - Medication Scanner View

struct MedicationScannerView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var scanner = MedicationScannerController()

    let onFound: (ScannedMedication) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if scanner.permissionDenied {
                    unavailableView(
                        icon: "camera.fill",
                        title: "Camera Access Needed",
                        message: "CareConnect needs camera access to scan medication barcodes. Enable Camera access in Settings, then try again."
                    )
                } else if scanner.isUnavailable {
                    unavailableView(
                        icon: "barcode.viewfinder",
                        title: "Scanner Unavailable",
                        message: "MedScan needs a supported device with a working camera. You can still add the medication manually."
                    )
                } else if let scannerView = scanner.scannerView {
                    ScannerContainerView(scannerView: scannerView)
                        .ignoresSafeArea()
                        .overlay {
                            VStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.white, lineWidth: 3)
                                    .frame(width: 300, height: 190)

                                Text("Place the barcode or QR code inside the box")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(.black.opacity(0.65))
                                    .clipShape(Capsule())
                            }
                        }
                } else {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }

                if scanner.isLookingUp {
                    Color.black
                        .opacity(0.55)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.15)

                        Text("Identifying medication…")
                            .foregroundColor(.white)
                            .font(.headline)

                        Text("Checking FDA medication data")
                            .foregroundColor(.white.opacity(0.85))
                            .font(.subheadline)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            }
            .navigationTitle("Scan Medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .onAppear {
                scanner.start()
            }
            .onDisappear {
                scanner.stop()
            }
            .alert(
                "Medication Lookup Error",
                isPresented: $scanner.showError
            ) {
                Button("Try Again") {
                    scanner.reset()
                }

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text(scanner.errorMessage)
            }
            .onReceive(
                scanner.$foundMedication.compactMap { $0 }
            ) { medication in
                onFound(medication)
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

// MARK: - Scanner Container

struct ScannerContainerView: UIViewControllerRepresentable {
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
        // The scanner controller manages its own scanning session.
    }
}

// MARK: - Medication Scanner Controller

@MainActor
final class MedicationScannerController: NSObject, ObservableObject {

    @Published var scannerView: UIViewController?
    @Published var foundMedication: ScannedMedication?

    @Published var isLookingUp = false
    @Published var permissionDenied = false
    @Published var isUnavailable = false
    @Published var showError = false
    @Published var errorMessage = ""

    private var dataScanner: DataScannerViewController?
    private var hasProcessedScan = false
    private var isStarting = false

    // MARK: Start

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
        return

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
            AVCaptureDevice.authorizationStatus(for: .video)

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

    // MARK: Camera Permission

    private func requestCameraPermission() {
        guard !isStarting else {
            return
        }

        isStarting = true

        Task {
            let granted = await AVCaptureDevice.requestAccess(
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

    // MARK: Create Scanner

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

        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(
                    symbologies: [
                        // QR codes
                        .qr,

                        // Common retail medication barcodes
                        .ean13,
                        .ean8,
                        .upce,

                        // Other common 1D formats
                        .code128,
                        .code39,
                        .code93,
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

        DispatchQueue.main.async { [weak self] in
            self?.startScanningIfPossible()
        }
    }

    // MARK: Start Scanning

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
            errorMessage =
                "The camera scanner could not start: \(error.localizedDescription)"

            isUnavailable = true
        }
    }

    // MARK: Stop

    func stop() {
        #if !targetEnvironment(simulator)

        if #available(iOS 16.0, *) {
            dataScanner?.stopScanning()
        }

        #endif
    }

    // MARK: Reset

    func reset() {
        stop()

        hasProcessedScan = false
        showError = false
        errorMessage = ""
        foundMedication = nil
        isLookingUp = false
        permissionDenied = false
        isUnavailable = false

        dataScanner = nil
        scannerView = nil

        start()
    }

    // MARK: Barcode / QR Processing

    private func processBarcode(_ code: String) {
        guard !hasProcessedScan else {
            return
        }

        hasProcessedScan = true
        isLookingUp = true

        Task {
            do {
                let medication =
                    try await MedicationLookupService.lookup(
                        code: code
                    )

                await MainActor.run {
                    self.isLookingUp = false

                    if let medication {
                        self.foundMedication = medication
                        self.stop()
                    } else {
                        self.errorMessage =
                            "We couldn't identify this code as a medication in the available FDA data. Try another package or add the medication manually."

                        self.showError = true
                        self.hasProcessedScan = false
                    }
                }

            } catch {
                await MainActor.run {
                    self.isLookingUp = false
                    self.errorMessage =
                        error.localizedDescription
                    self.showError = true
                    self.hasProcessedScan = false
                }
            }
        }
    }
}

// MARK: - Data Scanner Delegate

@available(iOS 16.0, *)
extension MedicationScannerController:
    DataScannerViewControllerDelegate {

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        for item in addedItems {
            if case .barcode(let barcode) = item,
               let value = barcode.payloadStringValue {

                processBarcode(value)
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
        errorMessage =
            "The medication scanner became unavailable: \(error.localizedDescription)"
    }
}

// MARK: - Medication Lookup Errors

enum MedicationLookupError: LocalizedError {
    case invalidURL
    case networkError(String)
    case serverError(statusCode: Int, message: String)
    case invalidResponse
    case medicationNotFound

    var errorDescription: String? {
        switch self {

        case .invalidURL:
            return "The medication lookup request could not be created."

        case let .networkError(message):
            return "Could not connect to the medication database: \(message)"

        case let .serverError(statusCode, message):
            return "Medication database error (\(statusCode)): \(message)"

        case .invalidResponse:
            return "The medication database returned an unexpected response."

        case .medicationNotFound:
            return "This code could not be matched to medication information in the available FDA data."
        }
    }
}

// MARK: - Medication Lookup Service

enum MedicationLookupService {

    static func lookup(
        code: String
    ) async throws -> ScannedMedication? {

        guard var components = URLComponents(
            string:
                "https://us-central1-careconnect-3bd75.cloudfunctions.net/lookupMedication"
        ) else {
            throw MedicationLookupError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(
                name: "barcode",
                value: code
            )
        ]

        guard let url = components.url else {
            throw MedicationLookupError.invalidURL
        }

        var request = URLRequest(url: url)

        request.httpMethod = "GET"
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse

        do {
            (data, response) =
                try await URLSession.shared.data(
                    for: request
                )
        } catch {
            throw MedicationLookupError.networkError(
                error.localizedDescription
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MedicationLookupError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {

            let serverMessage =
                String(
                    data: data,
                    encoding: .utf8
                ) ?? "Unknown server error"

            throw MedicationLookupError.serverError(
                statusCode: httpResponse.statusCode,
                message: serverMessage
            )
        }

        do {
            let decoded =
                try JSONDecoder().decode(
                    MedicationLookupResponse.self,
                    from: data
                )

            return decoded.medication?.toModel()

        } catch {
            throw MedicationLookupError.invalidResponse
        }
    }
}

// MARK: - Medication Lookup Response

private struct MedicationLookupResponse: Decodable {
    let medication: ScannedMedicationDTO?
}

private struct ScannedMedicationDTO: Decodable {

    let barcode: String
    let brandName: String?
    let genericName: String?
    let activeIngredients: [String]
    let strength: String?
    let dosageForm: String?
    let route: String?
    let manufacturer: String?
    let indications: String?
    let warnings: String?
    let contraindications: String?
    let dosageAndAdministration: String?
    let adverseReactions: String?
    let sourceName: String
    let sourceURL: String?

    func toModel() -> ScannedMedication {
        ScannedMedication(
            barcode: barcode,
            brandName: brandName,
            genericName: genericName,
            activeIngredients: activeIngredients,
            strength: strength,
            dosageForm: dosageForm,
            route: route,
            manufacturer: manufacturer,
            indications: indications,
            warnings: warnings,
            contraindications: contraindications,
            dosageAndAdministration: dosageAndAdministration,
            adverseReactions: adverseReactions,
            sourceName: sourceName,
            sourceURL: sourceURL
        )
    }
}

// MARK: - Medication Information

struct ScannedMedicationView: View {

    @Environment(\.dismiss) private var dismiss

    let medication: ScannedMedication
    let onAdd: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: 18
                ) {

                    // MARK: Header

                    VStack(
                        alignment: .leading,
                        spacing: 6
                    ) {
                        Text(medication.displayName)
                            .font(.largeTitle.bold())

                        if !medication.displayDosage.isEmpty {
                            Text(medication.displayDosage)
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }

                        Text("Barcode: \(medication.barcode)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // MARK: Generic Name

                    if let generic = medication.genericName,
                       generic.caseInsensitiveCompare(
                           medication.displayName
                       ) != .orderedSame {

                        infoCard(
                            title: "Generic Name",
                            text: generic,
                            icon: "pill.fill"
                        )
                    }

                    // MARK: Active Ingredients

                    if !medication.activeIngredients.isEmpty {
                        infoCard(
                            title:
                                medication.activeIngredients.count == 1
                                ? "Active Ingredient"
                                : "Active Ingredients",
                            text:
                                medication.activeIngredients.joined(
                                    separator: "\n"
                                ),
                            icon: "flask.fill"
                        )
                    }

                    // MARK: Indications

                    if let indications = medication.indications,
                       !indications.isEmpty {

                        infoCard(
                            title: "What It Is Used For",
                            text: indications,
                            icon: "cross.case.fill"
                        )
                    }

                    // MARK: Manufacturer

                    if let manufacturer = medication.manufacturer,
                       !manufacturer.isEmpty {

                        infoCard(
                            title: "Manufacturer",
                            text: manufacturer,
                            icon: "building.2.fill"
                        )
                    }

                    // MARK: Route

                    if let route = medication.route,
                       !route.isEmpty {

                        infoCard(
                            title: "Route",
                            text: route,
                            icon: "arrow.up.right"
                        )
                    }

                    // MARK: Warnings

                    if let warnings = medication.warnings,
                       !warnings.isEmpty {

                        infoCard(
                            title: "Important Warnings",
                            text: warnings,
                            icon: "exclamationmark.triangle.fill"
                        )
                    }

                    // MARK: Contraindications

                    if let contraindications =
                        medication.contraindications,
                       !contraindications.isEmpty {

                        infoCard(
                            title: "Contraindications",
                            text: contraindications,
                            icon: "hand.raised.fill"
                        )
                    }

                    // MARK: Dosage

                    if let dosage =
                        medication.dosageAndAdministration,
                       !dosage.isEmpty {

                        infoCard(
                            title: "Official Dosage Information",
                            text: dosage,
                            icon: "clock.fill"
                        )
                    }

                    // MARK: Adverse Reactions

                    if let adverse =
                        medication.adverseReactions,
                       !adverse.isEmpty {

                        infoCard(
                            title: "Possible Adverse Reactions",
                            text: adverse,
                            icon: "heart.text.square.fill"
                        )
                    }

                    // MARK: Source

                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {
                        Text("Information Source")
                            .font(.headline)

                        Text(medication.sourceName)
                            .font(.subheadline)

                        Text(
                            "This information comes from public government drug data. Follow the medication label and ask a pharmacist or healthcare professional if you have questions."
                        )
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    }

                    // MARK: Add Medication

                    Button {
                        dismiss()
                        onAdd()
                    } label: {
                        Label(
                            "Add to My Medications",
                            systemImage: "plus.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.headline)
                }
                .padding()
            }
            .navigationTitle("Medication Information")
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func infoCard(
        title: String,
        text: String,
        icon: String
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            Label(title, systemImage: icon)
                .font(.headline)

            Text(text)
                .font(.body)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .padding()
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color(UIColor.secondarySystemBackground)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: 16)
        )
    }
}
