
import SwiftUI
import FirebaseFirestore
import Firebase
import FirebaseAuth
import Firebase
import AVFoundation


struct CalendarEvent: Identifiable, Codable, Equatable {
    @DocumentID var id: String?

    var name: String
    var date: Date
    var type: String
    var helpCardID: String?

    init(fromHelpCard card: HelpCard, date: Date) {
        let cardID = card.id ?? card.title
        self.id = "help_\(cardID)_\(Int(date.timeIntervalSince1970))"
        self.name = card.title
        self.date = date
        self.type = card.postType ?? "Help"
        self.helpCardID = card.id
    }

    init(name: String, date: Date, type: String) {
        self.id = UUID().uuidString
        self.name = name
        self.date = date
        self.type = type
        self.helpCardID = nil
    }
}

struct CalendarView: View {
    @State private var manualEvents: [CalendarEvent] = []
    @State private var selectedDate = Date()
    @State private var showAddEvent = false

    @EnvironmentObject var dailyPointsVM: DailyPointsViewModel
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings
    @ObservedObject var viewModel: MainViewModel

    private let calendar = Calendar.current
    private let db = Firestore.firestore()

    
    private var acceptedHelpEvents: [CalendarEvent] {
        let currentUserID = Auth.auth().currentUser?.uid

        return viewModel.helpCards
            .filter { card in
                guard card.isCommitted,
                      let currentUserID else {
                    return false
                }

                // The current user is either the card owner
                // (requester) or the person who accepted it.
                return card.ownerId == currentUserID
                    || card.committedBy == currentUserID
            }
            .flatMap { card in
                card.availabilityDates
                    .filter { $0 >= Calendar.current.startOfDay(for: Date()) }
                    .map { date in
                        CalendarEvent(fromHelpCard: card, date: date)
                    }
            }
            .sorted { $0.date < $1.date }
    }
    
    private func formattedEventType(_ type: String) -> String {
        switch type.lowercased() {
        case "help_offer":
            return "Help Offer"
        case "support_request":
            return "Support Request"
        default:
            return type.capitalized
        }
    }

    private var events: [CalendarEvent] {
        (manualEvents + acceptedHelpEvents)
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    if let next = nextEvent {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Next Event")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.8))

                            Text(next.name)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)

                            Text("\(formattedDate(next.date)), \(formattedTime(next.date)) • \(formattedEventType(next.type))")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(eventTypeColor(next.type).opacity(0.2))
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    }

                    MonthlyCalendarView(
                        selectedDate: $selectedDate,
                        events: events
                    )
                    .padding(.horizontal)

                    sectionCard(title: "Events on \(formattedDate(selectedDate))") {
                        let dayEvents = eventsForDay(selectedDate)

                        if dayEvents.isEmpty {
                            Text("No events.")
                                .foregroundColor(.gray)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(dayEvents) { event in
                                eventRow(event)
                                    .padding(.vertical, 4)
                            }
                        }
                    }

                    sectionCard(title: "Upcoming Events This Week") {
                        let weekEvents = eventsThisWeek

                        if weekEvents.isEmpty {
                            Text("No events this week.")
                                .foregroundColor(.gray)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(weekEvents) { event in
                                eventRow(event)
                                    .padding(.vertical, 4)
                            }
                        }
                    }

                    sectionCard(title: "Accepted Help Opportunities") {
                        if acceptedHelpEvents.isEmpty {
                            Text("No accepted help opportunities yet.")
                                .foregroundColor(.gray)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(acceptedHelpEvents) { event in
                                eventRow(event)
                                    .padding(.vertical, 4)
                            }
                        }
                    }

                    Spacer(minLength: 100)
                }
                .padding(.top)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("My Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAddEvent) {
                AddEventView { newEvent in
                    addEventToFirestore(newEvent)
                    showAddEvent = false
                }
            }
            .onAppear {
                fetchEvents()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .overlay(alignment: .bottomTrailing) {
            Button {
                showAddEvent = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 46))
                    .foregroundColor(.blue)
                    .shadow(radius: 2)
            }
            .padding()
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)

            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .padding(.horizontal)
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(eventTypeColor(event.type))
                .frame(width: 12, height: 12)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text("\(formattedDate(event.date)), \(formattedTime(event.date))")
                    .font(.footnote)
                    .foregroundColor(.gray)

                Text(formattedEventType(event.type))
                    .font(.caption)
                    .foregroundColor(eventTypeColor(event.type))
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func eventTypeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "important":
            return .red
        case "medical":
            return .blue
        case "appointment":
            return .yellow
        case "personal":
            return .green
        case "help", "support", "request", "offer":
            return .purple
        default:
            return .purple
        }
    }

    private var nextEvent: CalendarEvent? {
        events.first { $0.date >= Date() }
    }

    private func eventsForDay(_ date: Date) -> [CalendarEvent] {
        events.filter {
            calendar.isDate($0.date, inSameDayAs: date)
        }
    }

    private var eventsThisWeek: [CalendarEvent] {
        guard
            let startOfWeek = calendar.date(
                from: calendar.dateComponents(
                    [.yearForWeekOfYear, .weekOfYear],
                    from: Date()
                )
            ),
            let endOfWeek = calendar.date(
                byAdding: .day,
                value: 7,
                to: startOfWeek
            )
        else {
            return []
        }

        return events.filter {
            $0.date >= Date() && $0.date < endOfWeek
        }
    }

    private func formattedDate(_ date: Date) -> String {
        DateFormatter.localizedString(
            from: date,
            dateStyle: .medium,
            timeStyle: .none
        )
    }

    private func formattedTime(_ date: Date) -> String {
        DateFormatter.localizedString(
            from: date,
            dateStyle: .none,
            timeStyle: .short
        )
    }

    private func fetchEvents() {
        guard let uid = Auth.auth().currentUser?.uid else {
            manualEvents = []
            return
        }

        db.collection("users")
            .document(uid)
            .collection("calendarEvents")
            .order(by: "date")
            .getDocuments { snapshot, error in
                if let error {
                    print("Calendar fetch error: \(error.localizedDescription)")
                    return
                }

                guard let snapshot else {
                    return
                }

                do {
                    let fetchedEvents = try snapshot.documents.compactMap {
                        try $0.data(as: CalendarEvent.self)
                    }

                    DispatchQueue.main.async {
                        manualEvents = fetchedEvents.sorted {
                            $0.date < $1.date
                        }
                    }
                } catch {
                    print("Calendar decoding error: \(error)")
                }
            }
    }

    private func addEventToFirestore(_ event: CalendarEvent) {
        guard let uid = Auth.auth().currentUser?.uid else {
            return
        }

        var localEvent = event
        let localID = UUID().uuidString
        localEvent.id = localID

        manualEvents.append(localEvent)
        manualEvents.sort { $0.date < $1.date }

        var eventToSave = event
        eventToSave.id = nil

        do {
            var documentReference: DocumentReference?

            documentReference = try db.collection("users")
                .document(uid)
                .collection("calendarEvents")
                .addDocument(from: eventToSave) { error in
                    DispatchQueue.main.async {
                        if let error {
                            manualEvents.removeAll {
                                $0.id == localID
                            }

                            print(
                                "Error adding calendar event: \(error.localizedDescription)"
                            )
                            return
                        }

                        guard let documentID = documentReference?.documentID else {
                            return
                        }

                        if let index = manualEvents.firstIndex(
                            where: { $0.id == localID }
                        ) {
                            manualEvents[index].id = documentID
                        }

                        manualEvents.sort { $0.date < $1.date }
                        dailyPointsVM.addPoints(3)
                    }
                }
        } catch {
            manualEvents.removeAll { $0.id == localID }
            print("Calendar encoding error: \(error.localizedDescription)")
        }
    }
}

struct MonthlyCalendarView: View {
    @Binding var selectedDate: Date
    let events: [CalendarEvent]

    private let calendar = Calendar.current
    private let columns = Array(
        repeating: GridItem(.flexible()),
        count: 7
    )

    private var monthDates: [Date] {
        guard
            let range = calendar.range(
                of: .day,
                in: .month,
                for: selectedDate
            ),
            let firstDay = calendar.date(
                from: calendar.dateComponents(
                    [.year, .month],
                    from: selectedDate
                )
            )
        else {
            return []
        }

        var dates = [Date]()
        let weekdayOfFirst = calendar.component(.weekday, from: firstDay)
        let firstWeekdayIndex = calendar.firstWeekday
        let offset = (weekdayOfFirst - firstWeekdayIndex + 7) % 7

        for _ in 0..<offset {
            dates.append(Date.distantPast)
        }

        for day in range {
            if let date = calendar.date(
                byAdding: .day,
                value: day - 1,
                to: firstDay
            ) {
                dates.append(date)
            }
        }

        return dates
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    changeMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.blue)
                }

                Spacer()

                Text(monthTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Spacer()

                Button {
                    changeMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(
                    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
                    id: \.self
                ) { day in
                    Text(day)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthDates, id: \.self) { date in
                    if date == Date.distantPast {
                        Color.clear
                            .frame(height: 48)
                    } else {
                        dayCell(date)
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func dayCell(_ date: Date) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(
            date,
            inSameDayAs: selectedDate
        )
        let dayEvents = eventsForDay(date)

        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundColor(
                        isSelected
                        ? .white
                        : (isToday ? .blue : .white)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)

                HStack(spacing: 3) {
                    ForEach(
                        Array(Set(dayEvents.map { $0.type.lowercased() }))
                            .sorted()
                            .prefix(3),
                        id: \.self
                    ) { type in
                        Circle()
                            .fill(eventTypeColor(type))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                        ? Color.blue.opacity(0.65)
                        : Color.clear
                    )
            )
            .overlay {
                if isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func changeMonth(by amount: Int) {
        guard let newDate = calendar.date(
            byAdding: .month,
            value: amount,
            to: selectedDate
        ) else {
            return
        }

        selectedDate = newDate
    }

    private func eventsForDay(_ date: Date) -> [CalendarEvent] {
        events.filter {
            calendar.isDate($0.date, inSameDayAs: date)
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: selectedDate)
    }

    private func eventTypeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "important":
            return .red
        case "medical":
            return .blue
        case "appointment":
            return .yellow
        case "personal":
            return .green
        case "help", "support", "request", "offer":
            return .purple
        default:
            return .purple
        }
    }
}

struct AddEventView: View {
    @Environment(\.dismiss) private var dismiss

    var onSave: (CalendarEvent) -> Void

    @State private var name = ""
    @State private var date = Date()
    @State private var type = "important"

    private let eventTypes = [
        "important",
        "medical",
        "appointment",
        "personal",
        "other"
    ]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Event Name", text: $name)

                    DatePicker(
                        "Date & Time",
                        selection: $date,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    Picker("Type", selection: $type) {
                        ForEach(eventTypes, id: \.self) { eventType in
                            Text(eventType.capitalized)
                                .tag(eventType)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedName = name.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )

                        guard !trimmedName.isEmpty else {
                            return
                        }

                        let event = CalendarEvent(
                            name: trimmedName,
                            date: date,
                            type: type
                        )

                        onSave(event)
                        dismiss()
                    }
                    .disabled(
                        name.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
