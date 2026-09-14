import SwiftUI
import Firebase
import FirebaseFirestore
import FirebaseAuth
import Foundation
import Combine

struct Medication: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var dosage: String
    var times: [Date]
    var streak: Int
    var lastTaken: Date?
    var takenTimes: Set<String> = []
    var takenTimesActual: [String: Date] = [:]

    static func == (lhs: Medication, rhs: Medication) -> Bool {
        lhs.id == rhs.id
    }
}

class MedicationListViewModel: ObservableObject {
    @Published var medications: [Medication] = []
    @Published var showAlert: Bool = false
    @Published var alertMessage: String = ""
    @Published var takenStatus: [String: Bool] = [:]

    @Published private(set) var overallStreak: Int {
        didSet {
            userDefaults.set(overallStreak, forKey: overallStreakKey)
        }
    }

    private let db = Firestore.firestore()
    private let calendar = Calendar.current
    private let userDefaults = UserDefaults.standard

    private let lastResetKey = "lastStreakResetDate"
    private let overallStreakKey = "overallStreak"
    private var midnightTimer: Timer?

    init() {
        overallStreak = userDefaults.integer(forKey: overallStreakKey)
        resetStreaksIfNeeded()
        fetchMedications()
        scheduleMidnightReset()
    }

    func fetchMedications() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        db.collection("users").document(uid).collection("medications")
            .getDocuments { [weak self] snapshot, error in
                guard let self = self else { return }
                if let error = error {
                    self.alertMessage = "Error fetching medications: \(error.localizedDescription)"
                    self.showAlert = true
                    return
                }
                self.medications = snapshot?.documents.compactMap {
                    try? $0.data(as: Medication.self)
                } ?? []

                self.medications.sort {
                    ($0.times.min() ?? Date.distantFuture) < ($1.times.min() ?? Date.distantFuture)
                }
                self.rebuildTakenStatus()
            }
    }

    private func rebuildTakenStatus() {
        takenStatus.removeAll()
        for med in medications {
            for time in med.times {
                let key = takenKey(for: med.id, at: time)
                takenStatus[key] = med.takenTimes.contains(key)
            }
        }
    }

    func addMedication(_ medication: Medication) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            try db.collection("users").document(uid)
                .collection("medications").document(medication.id)
                .setData(from: medication) { [weak self] error in
                    if let error = error {
                        self?.alertMessage = "Error adding medication: \(error.localizedDescription)"
                        self?.showAlert = true
                        return
                    }
                    self?.fetchMedications()
                }
        } catch {
            alertMessage = "Error adding medication: \(error.localizedDescription)"
            showAlert = true
        }
    }

    func updateMedication(_ medication: Medication) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            try db.collection("users").document(uid)
                .collection("medications").document(medication.id)
                .setData(from: medication) { [weak self] error in
                    if let error = error {
                        self?.alertMessage = "Error updating medication: \(error.localizedDescription)"
                        self?.showAlert = true
                        return
                    }
                    self?.fetchMedications()
                }
        } catch {
            alertMessage = "Error updating medication: \(error.localizedDescription)"
            showAlert = true
        }
    }

    func deleteMedication(_ medication: Medication) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        medications.removeAll { $0.id == medication.id }
        rebuildTakenStatus()

        db.collection("users").document(uid)
            .collection("medications").document(medication.id)
            .delete { [weak self] error in
                if let error = error {
                    self?.alertMessage = "Error deleting medication: \(error.localizedDescription)"
                    self?.showAlert = true
                    self?.fetchMedications()
                }
            }
    }

    func updateStreak(for medication: Medication, takenTime: Date) {
        resetStreaksIfNeeded()
        var updatedMed = medication

        guard let scheduledTime = medication.times.min(by: {
            abs($0.timeIntervalSince(takenTime)) < abs($1.timeIntervalSince(takenTime))
        }) else {
            alertMessage = "No scheduled time found."
            showAlert = true
            return
        }

        let key = takenKey(for: medication.id, at: scheduledTime)
        if takenStatus[key] == true {
            alertMessage = "You already marked this dose as taken."
            showAlert = true
            return
        }

        let earlyBoundary = calendar.date(byAdding: .minute, value: -60, to: scheduledTime)!
        let lateBoundary = calendar.date(byAdding: .minute, value: 60, to: scheduledTime)!

        updatedMed.takenTimes.insert(key)
        updatedMed.takenTimesActual[key] = takenTime
        takenStatus[key] = true

        if takenTime >= earlyBoundary && takenTime <= lateBoundary {
            updatedMed.streak += 1
            updatedMed.lastTaken = takenTime
            updateOverallStreak(overallStreak + 1)
            alertMessage = "Taken on time. Streak increased!"
        } else if takenTime < earlyBoundary {
            alertMessage = "Taken early. Streak unchanged."
        } else if takenTime > lateBoundary {
            updateOverallStreak(0)
            updatedMed.streak = 0
            alertMessage = "Taken late. Streak reset."
        }

        showAlert = true
        updateMedication(updatedMed)
    }

    private func resetStreaksIfNeeded() {
        let today = calendar.startOfDay(for: Date())
        let lastReset = userDefaults.object(forKey: lastResetKey) as? Date ?? Date.distantPast

        if !calendar.isDate(today, inSameDayAs: lastReset) {
            for index in medications.indices {
                medications[index].streak = 0
                medications[index].takenTimes.removeAll()
                medications[index].takenTimesActual.removeAll()
            }
            updateOverallStreak(0)
            userDefaults.set(today, forKey: lastResetKey)
            takenStatus.removeAll()
            saveAllMedications()
        }
    }

    private func saveAllMedications() {
        for med in medications {
            updateMedication(med)
        }
    }

    private func scheduleMidnightReset() {
        let now = Date()
        guard let midnight = calendar.nextDate(after: now,
                                               matching: DateComponents(hour: 0),
                                               matchingPolicy: .nextTime) else { return }
        midnightTimer?.invalidate()
        midnightTimer = Timer(fireAt: midnight,
                              interval: 86400,
                              target: self,
                              selector: #selector(handleMidnightReset),
                              userInfo: nil,
                              repeats: true)
        RunLoop.main.add(midnightTimer!, forMode: .common)
    }

    @objc private func handleMidnightReset() {
        DispatchQueue.main.async {
            self.resetStreaksIfNeeded()
            self.fetchMedications()
        }
    }

    func takenKey(for medID: String, at time: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH:mm"
        return "\(medID)_\(formatter.string(from: time))"
    }

    private func updateOverallStreak(_ newValue: Int) {
        overallStreak = newValue
        userDefaults.set(newValue, forKey: overallStreakKey)
    }
}

struct MedicationView: View {
    @StateObject private var vm = MedicationListViewModel()
    @State private var showAdd = false
    @State private var showMedScan = false
    @State private var scannedMedication: ScannedMedication?
    @State private var selectedMed: Medication?
    @State private var editingTime: Date?

    @EnvironmentObject var dailyPointsVM: DailyPointsViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView { medicationListView }
                VStack { Spacer(); addMedicationButton }
            }
            .navigationTitle("My Medications")
            .onAppear { vm.fetchMedications() }
            .sheet(isPresented: $showAdd) {
                AddMedicationView(vm: vm, prefilledMedication: scannedMedication) {
                    vm.fetchMedications()
                    showAdd = false
                    scannedMedication = nil
                }
            }
            .sheet(isPresented: $showMedScan) {
                MedicationScannerView { medication in
                    scannedMedication = medication
                    showMedScan = false
                    showAdd = true
                }
            }
            .sheet(item: $scannedMedication) { medication in
                ScannedMedicationView(medication: medication) {
                    scannedMedication = medication
                    showAdd = true
                }
            }
            .sheet(item: $selectedMed) { med in
                EditMedicationView(
                    medicationToEdit: med,
                    vm: vm,
                    onSave: {
                        vm.fetchMedications()
                        selectedMed = nil
                    },
                    onCancel: { selectedMed = nil }
                )
            }
            .alert(isPresented: $vm.showAlert) {
                Alert(
                    title: Text("Medication Update"),
                    message: Text(vm.alertMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    var medicationListView: some View {
        VStack(spacing: 16) {
            Text("Streak: \(vm.overallStreak)")
                .font(.headline)
                .padding(.top)

            if vm.medications.isEmpty {
                WordSpeakableText(text: "No medications added yet.")
                    .foregroundColor(.gray)
                    .padding()
            }

            ForEach(vm.medications) { med in
                medicationTimesView(for: med)
            }

            Spacer(minLength: 120)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    func medicationTimesView(for med: Medication) -> some View {
        ForEach(med.times.sorted(), id: \.self) { time in
            MedicationCard(
                med: med,
                time: time,
                isTaken: vm.takenStatus[vm.takenKey(for: med.id, at: time)] ?? false,
                onTake: {
                    vm.updateStreak(for: med, takenTime: Date())
                    let basePoints = 10
                    let streakBonus = med.streak
                    dailyPointsVM.addPoints(basePoints + streakBonus)
                },
                onEdit: { selectedMed = med; editingTime = time },
                onDelete: { vm.deleteMedication(med) }
            )
        }
    }

    var addMedicationButton: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Button(action: { showMedScan = true }) {
                Label("Scan Medication", systemImage: "barcode.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .shadow(radius: 4)
            }

            Button(action: { showAdd = true }) {
                Label("Add Manually", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Color(UIColor.secondarySystemBackground))
                    .foregroundColor(.primary)
                    .clipShape(Capsule())
                    .shadow(radius: 3)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

struct MedicationCard: View {
    let med: Medication
    let time: Date
    let isTaken: Bool

    var onTake: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: { if !isTaken { onTake() } }) {
                    Image(systemName: isTaken ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isTaken ? .green : .gray)
                        .font(.title2)
                }
                .disabled(isTaken)

                WordSpeakableText(text: med.name)
                    .font(.title3.bold())
                Spacer()
            }

            WordSpeakableText(text: "Dosage: \(med.dosage)")
                .foregroundColor(.secondary)

            WordSpeakableText(text: "Scheduled Time: \(formattedTime(time))")
                .foregroundColor(.secondary)

            WordSpeakableText(text: "Next dose in: \(timeUntilNextDose(from: time))")
                .foregroundColor(.blue)
                .font(.subheadline)

            HStack {
                Spacer()
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(BorderlessButtonStyle())
                .padding(.trailing, 12)

                Button(action: onDelete) {
                    Label("Delete", systemImage: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 3)
        )
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func timeUntilNextDose(from scheduledTime: Date) -> String {
        let now = Date()
        let diff = scheduledTime.timeIntervalSince(now)
        if diff <= 0 { return "Due now" }

        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

struct AddMedicationView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var vm: MedicationListViewModel

    @State private var name: String
    @State private var dosage: String
    @State private var times: [Date] = [Date()]

    var onSave: () -> Void

    init(vm: MedicationListViewModel,
         prefilledMedication: ScannedMedication? = nil,
         onSave: @escaping () -> Void) {
        self.vm = vm
        self.onSave = onSave
        _name = State(initialValue: prefilledMedication?.displayName ?? "")
        _dosage = State(initialValue: prefilledMedication?.displayDosage ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: WordSpeakableText(text: "Medication Info")) {
                    TextField("Name", text: $name)
                    TextField("Dosage", text: $dosage)
                }

                Section(header: WordSpeakableText(text: "Medication Times")) {
                    ForEach(times.indices, id: \.self) { i in
                        HStack {
                            DatePicker("Time \(i + 1)",
                                       selection: $times[i],
                                       displayedComponents: .hourAndMinute)
                            if times.count > 1 {
                                Button { times.remove(at: i) } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                    Button { times.append(Date()) } label: {
                        Label("Add Time", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("Add Medication")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveMedication() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func saveMedication() {
        let newMed = Medication(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            dosage: dosage.trimmingCharacters(in: .whitespaces),
            times: times,
            streak: 0,
            lastTaken: nil
        )
        vm.addMedication(newMed)
        onSave()
        dismiss()
    }
}

struct EditMedicationView: View {
    @Environment(\.dismiss) var
    dismiss
    @ObservedObject var vm: MedicationListViewModel

    @State private var name: String
    @State private var dosage: String
    @State private var times: [Date]

    var medicationToEdit: Medication
    var onSave: () -> Void
    var onCancel: () -> Void

    init(medicationToEdit: Medication,
         vm: MedicationListViewModel,
         onSave: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.medicationToEdit = medicationToEdit
        self.vm = vm
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: medicationToEdit.name)
        _dosage = State(initialValue: medicationToEdit.dosage)
        _times = State(initialValue: medicationToEdit.times)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: WordSpeakableText(text: "Name & Dosage")) {
                    TextField("Name", text: $name)
                    TextField("Dosage", text: $dosage)
                }

                Section(header: WordSpeakableText(text: "Times")) {
                    ForEach(times.indices, id: \.self) { i in
                        HStack {
                            DatePicker("Time \(i + 1)",
                                       selection: $times[i],
                                       displayedComponents: .hourAndMinute)
                            if times.count > 1 {
                                Button { times.remove(at: i) } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                    Button { times.append(Date()) } label: {
                        Label("Add Time", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("Edit Medication")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let updatedMed = Medication(
                            id: medicationToEdit.id,
                            name: name.trimmingCharacters(in: .whitespaces),
                            dosage: dosage.trimmingCharacters(in: .whitespaces),
                            times: times,
                            streak: medicationToEdit.streak,
                            lastTaken: medicationToEdit.lastTaken,
                            takenTimes: medicationToEdit.takenTimes,
                            takenTimesActual: medicationToEdit.takenTimesActual
                        )
                        vm.updateMedication(updatedMed)
                        onSave()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

