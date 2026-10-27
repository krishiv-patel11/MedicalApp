import SwiftUI
import Firebase
import FirebaseFirestore
import FirebaseAuth
import Foundation
import Combine

// MARK: - Medication Model

struct Medication: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var dosage: String
    var times: [Date]
    var streak: Int
    var lastTaken: Date?
    var takenTimes: Set<String> = []
    var takenTimesActual: [String: Date] = [:]

    // Calendar weekday values: Sunday = 1, Monday = 2, ..., Saturday = 7.
    // Older medication documents without scheduleDays default to every day.
    var scheduleDays: [Int] = Array(1...7)

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case dosage
        case times
        case streak
        case lastTaken
        case takenTimes
        case takenTimesActual
        case scheduleDays
    }

    init(
        id: String,
        name: String,
        dosage: String,
        times: [Date],
        streak: Int = 0,
        lastTaken: Date? = nil,
        takenTimes: Set<String> = [],
        takenTimesActual: [String: Date] = [:],
        scheduleDays: [Int] = Array(1...7)
    ) {
        self.id = id
        self.name = name
        self.dosage = dosage
        self.times = times
        self.streak = streak
        self.lastTaken = lastTaken
        self.takenTimes = takenTimes
        self.takenTimesActual = takenTimesActual
        self.scheduleDays = scheduleDays
    }

    // Keeps older Firestore documents readable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        dosage = try container.decodeIfPresent(String.self, forKey: .dosage) ?? ""
        times = try container.decodeIfPresent([Date].self, forKey: .times) ?? []
        streak = try container.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        lastTaken = try container.decodeIfPresent(Date.self, forKey: .lastTaken)
        takenTimes = try container.decodeIfPresent(Set<String>.self, forKey: .takenTimes) ?? []
        takenTimesActual = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .takenTimesActual
        ) ?? [:]
        scheduleDays = try container.decodeIfPresent(
            [Int].self,
            forKey: .scheduleDays
        ) ?? Array(1...7)
    }

    static func == (lhs: Medication, rhs: Medication) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Dose Status

enum DoseStatus {
    case onTime
    case early
    case late
    case taken

    var title: String {
        switch self {
        case .onTime:
            return "Taken on time"
        case .early:
            return "Taken early"
        case .late:
            return "Taken late"
        case .taken:
            return "Already marked taken"
        }
    }

    var color: Color {
        switch self {
        case .onTime:
            return .green
        case .early:
            return .orange
        case .late:
            return .red
        case .taken:
            return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .onTime:
            return "checkmark.circle.fill"
        case .early:
            return "clock.arrow.circlepath"
        case .late:
            return "exclamationmark.circle.fill"
        case .taken:
            return "checkmark.circle"
        }
    }
}

enum DoseResult {
    case onTime(streak: Int)
    case early
    case late
    case alreadyTaken
    case unavailable
}

// MARK: - Medication View Model

@MainActor
final class MedicationListViewModel: ObservableObject {
    @Published var medications: [Medication] = []
    @Published var showAlert = false
    @Published var alertMessage = ""

    @Published private(set) var overallStreak: Int {
        didSet {
            userDefaults.set(overallStreak, forKey: overallStreakKey)
        }
    }

    private let db = Firestore.firestore()
    private let calendar = Calendar.current
    private let userDefaults = UserDefaults.standard
    private let overallStreakKey = "overallStreak"

    private let earlyLateBuffer: TimeInterval = 60 * 60

    init() {
        overallStreak = userDefaults.integer(forKey: overallStreakKey)
        fetchMedications()
    }

    // MARK: Fetch

    func fetchMedications() {
        guard let uid = Auth.auth().currentUser?.uid else {
            return
        }

        db.collection("users")
            .document(uid)
            .collection("medications")
            .getDocuments { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }

                    if let error {
                        self.alertMessage =
                            "Error fetching medications: \(error.localizedDescription)"
                        self.showAlert = true
                        return
                    }

                    self.medications = snapshot?.documents.compactMap {
                        try? $0.data(as: Medication.self)
                    } ?? []

                    self.medications.sort {
                        ($0.times.min() ?? .distantFuture) <
                        ($1.times.min() ?? .distantFuture)
                    }
                }
            }
    }

    // MARK: Save

    func addMedication(_ medication: Medication) {
        saveMedication(medication, errorPrefix: "adding")
    }

    func updateMedication(_ medication: Medication) {
        saveMedication(medication, errorPrefix: "updating")
    }

    private func saveMedication(
        _ medication: Medication,
        errorPrefix: String
    ) {
        guard let uid = Auth.auth().currentUser?.uid else {
            alertMessage = "Please sign in before saving medications."
            showAlert = true
            return
        }

        do {
            try db.collection("users")
                .document(uid)
                .collection("medications")
                .document(medication.id)
                .setData(from: medication) { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }

                        if let error {
                            self.alertMessage =
                                "Error \(errorPrefix) medication: \(error.localizedDescription)"
                            self.showAlert = true
                        } else {
                            self.fetchMedications()
                        }
                    }
                }
        } catch {
            alertMessage =
                "Error \(errorPrefix) medication: \(error.localizedDescription)"
            showAlert = true
        }
    }

    // MARK: Delete

    func deleteMedication(_ medication: Medication) {
        guard let uid = Auth.auth().currentUser?.uid else {
            return
        }

        medications.removeAll { $0.id == medication.id }

        db.collection("users")
            .document(uid)
            .collection("medications")
            .document(medication.id)
            .delete { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }

                    if let error {
                        self.alertMessage =
                            "Error deleting medication: \(error.localizedDescription)"
                        self.showAlert = true
                        self.fetchMedications()
                    }
                }
            }
    }

    // MARK: Date and Time Helpers

    func scheduledDate(for storedTime: Date, on date: Date) -> Date {
        let hour = calendar.component(.hour, from: storedTime)
        let minute = calendar.component(.minute, from: storedTime)

        return calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: date
        ) ?? date
    }

    func dateForWeekday(_ weekday: Int) -> Date {
        let today = calendar.startOfDay(for: Date())
        let currentWeekday = calendar.component(.weekday, from: today)
        let difference = weekday - currentWeekday

        return calendar.date(
            byAdding: .day,
            value: difference,
            to: today
        ) ?? today
    }

    func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    func takenKey(for medicationID: String, at scheduledTime: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd-HH:mm"

        return "\(medicationID)_\(formatter.string(from: scheduledTime))"
    }

    // MARK: Dose Status

    func doseStatus(
        for medication: Medication,
        scheduledTime: Date
    ) -> DoseStatus? {
        let key = takenKey(for: medication.id, at: scheduledTime)

        guard medication.takenTimes.contains(key) else {
            return nil
        }

        guard let actualTime = medication.takenTimesActual[key] else {
            return .taken
        }

        let difference = actualTime.timeIntervalSince(scheduledTime)

        if difference < -earlyLateBuffer {
            return .early
        }

        if difference > earlyLateBuffer {
            return .late
        }

        return .onTime
    }

    // MARK: Mark Dose Taken

    @discardableResult
    func updateStreak(
        for medication: Medication,
        scheduledTime: Date,
        takenTime: Date = Date()
    ) -> DoseResult {
        guard let index = medications.firstIndex(
            where: { $0.id == medication.id }
        ) else {
            alertMessage = "Medication could not be found."
            showAlert = true
            return .unavailable
        }

        // Always use the latest local version to avoid overwriting
        // a streak update with an outdated medication object.
        var updatedMedication = medications[index]

        let key = takenKey(
            for: updatedMedication.id,
            at: scheduledTime
        )

        guard !updatedMedication.takenTimes.contains(key) else {
            alertMessage = "You already marked this dose as taken."
            showAlert = true
            return .alreadyTaken
        }

        // Record the dose regardless of whether it was early, on time, or late.
        updatedMedication.takenTimes.insert(key)
        updatedMedication.takenTimesActual[key] = takenTime

        let difference = takenTime.timeIntervalSince(scheduledTime)
        let result: DoseResult

        if abs(difference) <= earlyLateBuffer {
            updatedMedication.streak += 1
            updatedMedication.lastTaken = takenTime

            updateOverallStreak(overallStreak + 1)

            alertMessage = "Taken on time. You earned points and increased your streak!"
            result = .onTime(streak: updatedMedication.streak)

        } else if difference < -earlyLateBuffer {
            // Early: record the dose, but don't increase or reset the streak.
            alertMessage = "Taken early. No points awarded; your streak stays the same."
            result = .early

        } else {
            // Late: reset this medication's streak only.
            updatedMedication.streak = 0

            alertMessage = "Taken late. This medication's streak has been reset."
            result = .late
        }

        medications[index] = updatedMedication
        updateMedication(updatedMedication)
        showAlert = true

        return result
    }

    private func updateOverallStreak(_ newValue: Int) {
        overallStreak = newValue
    }
}

// MARK: - Medication Page

struct MedicationView: View {
    @StateObject private var vm = MedicationListViewModel()

    @State private var showAdd = false
    @State private var selectedMed: Medication?
    @State private var expandedDay: Int? =
        Calendar.current.component(.weekday, from: Date())
    @State private var currentTime = Date()

    @EnvironmentObject var dailyPointsVM: DailyPointsViewModel

    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 16) {
                        Text("Streak: \(vm.overallStreak)")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)

                        ForEach(weekdayOrder, id: \.self) { day in
                            weekdaySection(day)
                        }

                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal)
                }

                Button {
                    showAdd = true
                } label: {
                    Label("Add Medication", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .shadow(radius: 4)
                }
                .padding()
            }
            .navigationTitle("My Medications")
            .sheet(isPresented: $showAdd) {
                AddMedicationView(vm: vm) {
                    vm.fetchMedications()
                    showAdd = false
                }
            }
            .sheet(item: $selectedMed) { medication in
                EditMedicationView(
                    medicationToEdit: medication,
                    vm: vm,
                    onSave: {
                        vm.fetchMedications()
                        selectedMed = nil
                    },
                    onCancel: {
                        selectedMed = nil
                    }
                )
            }
            .alert(isPresented: $vm.showAlert) {
                Alert(
                    title: Text("Medication Update"),
                    message: Text(vm.alertMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .onReceive(
                Timer.publish(
                    every: 30,
                    on: .main,
                    in: .common
                ).autoconnect()
            ) { date in
                currentTime = date

                let weekday = Calendar.current.component(.weekday, from: date)

                // Automatically open the new day's dropdown at midnight.
                if expandedDay != weekday &&
                    Calendar.current.isDateInToday(date) {
                    let previousDate = Calendar.current.date(
                        byAdding: .second,
                        value: -30,
                        to: date
                    ) ?? date

                    if Calendar.current.component(.day, from: previousDate) !=
                        Calendar.current.component(.day, from: date) {
                        expandedDay = weekday
                    }
                }
            }
        }
    }

    // MARK: Day Dropdown

    @ViewBuilder
    private func weekdaySection(_ day: Int) -> some View {
        let date = vm.dateForWeekday(day)
        let todaysMedications = vm.medications.filter {
            $0.scheduleDays.contains(day)
        }

        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedDay == day },
                set: { expandedDay = $0 ? day : nil }
            )
        ) {
            VStack(spacing: 14) {
                if todaysMedications.isEmpty {
                    Text("No medications scheduled for this day.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(todaysMedications) { medication in
                        ForEach(medication.times.sorted(), id: \.self) { storedTime in
                            let scheduledTime = vm.scheduledDate(
                                for: storedTime,
                                on: date
                            )

                            MedicationCard(
                                med: medication,
                                scheduledTime: scheduledTime,
                                isToday: vm.isToday(date),
                                currentTime: currentTime,
                                status: vm.doseStatus(
                                    for: medication,
                                    scheduledTime: scheduledTime
                                ),
                                onTake: {
                                    let result = vm.updateStreak(
                                        for: medication,
                                        scheduledTime: scheduledTime,
                                        takenTime: Date()
                                    )

                                    // Only on-time doses earn points.
                                    if case .onTime(let streak) = result {
                                        dailyPointsVM.addPoints(10 + streak)
                                    }
                                },
                                onEdit: {
                                    selectedMed = medication
                                },
                                onDelete: {
                                    vm.deleteMedication(medication)
                                }
                            )
                        }
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            HStack {
                Text(weekdayName(day))
                    .font(.headline)

                if vm.isToday(date) {
                    Text("Today")
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                }

                Spacer()

                Text("\(todaysMedications.count) medication\(todaysMedications.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }

    private func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "Sunday"
        case 2: return "Monday"
        case 3: return "Tuesday"
        case 4: return "Wednesday"
        case 5: return "Thursday"
        case 6: return "Friday"
        case 7: return "Saturday"
        default: return ""
        }
    }
}

// MARK: - Medication Card

struct MedicationCard: View {
    let med: Medication
    let scheduledTime: Date
    let isToday: Bool
    let currentTime: Date
    let status: DoseStatus?

    var onTake: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(med.name)
                        .font(.title3.bold())

                    if !med.dosage.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty {
                        Text("Dosage: \(med.dosage)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let status {
                    Label(status.title, systemImage: status.symbol)
                        .font(.caption.bold())
                        .foregroundColor(status.color)
                        .multilineTextAlignment(.trailing)
                }
            }

            Label(
                "Scheduled: \(formattedTime(scheduledTime))",
                systemImage: "clock"
            )
            .font(.subheadline)
            .foregroundColor(.secondary)

            if isToday && status == nil {
                Text(timeUntilDose())
                    .font(.subheadline.bold())
                    .foregroundColor(
                        scheduledTime < currentTime ? .orange : .blue
                    )

                Button(action: onTake) {
                    Label("Mark as Taken", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

            } else if !isToday && status == nil {
                Text("Scheduled for this day")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()

                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.systemBackground))
                .shadow(
                    color: .black.opacity(0.06),
                    radius: 4,
                    x: 0,
                    y: 2
                )
        )
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func timeUntilDose() -> String {
        let difference = scheduledTime.timeIntervalSince(currentTime)

        if difference < -3600 {
            return "Scheduled time has passed"
        }

        if difference < 0 {
            let minutes = Int(abs(difference) / 60)
            return "Within late buffer (\(minutes) min past due)"
        }

        let hours = Int(difference) / 3600
        let minutes = (Int(difference) % 3600) / 60

        if hours > 0 {
            return "Due in \(hours)h \(minutes)m"
        }

        return "Due in \(minutes)m"
    }
}

// MARK: - Add Medication

struct AddMedicationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: MedicationListViewModel

    @State private var name = ""
    @State private var dosage = ""
    @State private var times: [Date] = [Date()]
    @State private var selectedDays: Set<Int> = Set(1...7)

    var onSave: () -> Void

    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        NavigationStack {
            Form {
                Section("Medication Information") {
                    TextField("Medication name", text: $name)
                    TextField("Dosage (optional)", text: $dosage)
                }

                Section("Days of the Week") {
                    Text("Select each day this medication should appear.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    ForEach(weekdayOrder, id: \.self) { day in
                        Toggle(
                            weekdayName(day),
                            isOn: dayBinding(day)
                        )
                    }
                }

                Section("Scheduled Times") {
                    ForEach(times.indices, id: \.self) { index in
                        HStack {
                            DatePicker(
                                "Dose \(index + 1)",
                                selection: $times[index],
                                displayedComponents: .hourAndMinute
                            )

                            if times.count > 1 {
                                Button(role: .destructive) {
                                    times.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                            }
                        }
                    }

                    Button {
                        times.append(Date())
                    } label: {
                        Label("Add Time", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Add Medication")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveMedication()
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        selectedDays.isEmpty ||
                        times.isEmpty
                    )
                }
            }
        }
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { selectedDays.contains(day) },
            set: { selected in
                if selected {
                    selectedDays.insert(day)
                } else {
                    selectedDays.remove(day)
                }
            }
        )
    }

    private func saveMedication() {
        let medication = Medication(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            dosage: dosage.trimmingCharacters(in: .whitespacesAndNewlines),
            times: times,
            streak: 0,
            lastTaken: nil,
            scheduleDays: selectedDays.sorted()
        )

        vm.addMedication(medication)
        onSave()
        dismiss()
    }

    private func weekdayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }
}

// MARK: - Edit Medication

struct EditMedicationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: MedicationListViewModel

    @State private var name: String
    @State private var dosage: String
    @State private var times: [Date]
    @State private var selectedDays: Set<Int>

    let medicationToEdit: Medication
    var onSave: () -> Void
    var onCancel: () -> Void

    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    init(
        medicationToEdit: Medication,
        vm: MedicationListViewModel,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.medicationToEdit = medicationToEdit
        self.vm = vm
        self.onSave = onSave
        self.onCancel = onCancel

        _name = State(initialValue: medicationToEdit.name)
        _dosage = State(initialValue: medicationToEdit.dosage)
        _times = State(initialValue: medicationToEdit.times)
        _selectedDays = State(
            initialValue: Set(medicationToEdit.scheduleDays)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Medication Information") {
                    TextField("Medication name", text: $name)
                    TextField("Dosage (optional)", text: $dosage)
                }

                Section("Days of the Week") {
                    ForEach(weekdayOrder, id: \.self) { day in
                        Toggle(
                            weekdayName(day),
                            isOn: dayBinding(day)
                        )
                    }
                }

                Section("Scheduled Times") {
                    ForEach(times.indices, id: \.self) { index in
                        HStack {
                            DatePicker(
                                "Dose \(index + 1)",
                                selection: $times[index],
                                displayedComponents: .hourAndMinute
                            )

                            if times.count > 1 {
                                Button(role: .destructive) {
                                    times.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                            }
                        }
                    }

                    Button {
                        times.append(Date())
                    } label: {
                        Label("Add Time", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Edit Medication")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        selectedDays.isEmpty ||
                        times.isEmpty
                    )
                }
            }
        }
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { selectedDays.contains(day) },
            set: { selected in
                if selected {
                    selectedDays.insert(day)
                } else {
                    selectedDays.remove(day)
                }
            }
        )
    }

    private func saveChanges() {
        let updatedMedication = Medication(
            id: medicationToEdit.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            dosage: dosage.trimmingCharacters(in: .whitespacesAndNewlines),
            times: times,
            streak: medicationToEdit.streak,
            lastTaken: medicationToEdit.lastTaken,
            takenTimes: medicationToEdit.takenTimes,
            takenTimesActual: medicationToEdit.takenTimesActual,
            scheduleDays: selectedDays.sorted()
        )

        vm.updateMedication(updatedMedication)
        onSave()
        dismiss()
    }

    private func weekdayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }
}
