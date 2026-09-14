import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import Firebase
import AVFoundation

struct CalendarEvent: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var name: String
    var date: Date
    var type: String
    
    init(fromHelpCard card: HelpCard, date: Date) {
        self.id = card.id
        self.name = card.title
        self.date = date
        self.type = card.type
    }
    
    init(name: String, date: Date, type: String) {
        self.id = UUID().uuidString
        self.name = name
        self.date = date
        self.type = type
    }
}

struct CalendarView: View {
    @State private var events: [CalendarEvent] = []
    @State private var selectedDate = Date()
    @State private var showAddEvent = false
    
    @EnvironmentObject var dailyPointsVM: DailyPointsViewModel
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings
    @ObservedObject var viewModel: MainViewModel
    
    private let calendar = Calendar.current
    private let db = Firestore.firestore()

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
                            
                            Text("\(formattedDate(next.date)), \(formattedTime(next.date)) • \(next.type.capitalized)")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(eventTypeColor(next.type).opacity(0.2))
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .animation(.easeInOut, value: next)
                    }
                    
                    MonthlyCalendarView(selectedDate: $selectedDate, events: events)
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
                    
                    Spacer(minLength: 100)
                }
                .padding(.top)
            }
            .background(Color.black.edgesIgnoringSafeArea(.all))
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
                mergeCommittedHelpCards(viewModel.committedCards)
            }
            .onChange(of: viewModel.committedCards) { newCommittedCards in
                mergeCommittedHelpCards(newCommittedCards)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .overlay(
            Button(action: { showAddEvent.toggle() }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 46))
                    .foregroundColor(.blue)
                    .shadow(radius: 2)
            }
                .padding(),
            alignment: .bottomTrailing
        )
    }
    
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            content()
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .padding(.horizontal)
    }
    
    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(eventTypeColor(event.type).opacity(0.35))
                .frame(width: 12, height: 12)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Text("\(formattedDate(event.date)), \(formattedTime(event.date)) • \(event.type.capitalized)")
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    private func eventTypeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "important": return .red
        case "medical": return .blue
        case "appointment": return .yellow
        case "personal": return .green
        default: return .purple
        }
    }
    
    private var nextEvent: CalendarEvent? {
        events.first(where: { $0.date > Date() })
    }

    private func eventsForDay(_ date: Date) -> [CalendarEvent] {
        events.filter { calendar.isDate($0.date, inSameDayAs: date) }
    }

    private var eventsThisWeek: [CalendarEvent] {
        guard let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())),
              let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfWeek) else {
            return []
        }
        return events.filter { $0.date >= Date() && $0.date < endOfWeek }
    }

    private func formattedDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    private func formattedTime(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
    
    private func fetchEvents() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        db.collection("users").document(uid).collection("calendarEvents")
            .order(by: "date")
            .getDocuments { snapshot, error in
                guard let snapshot = snapshot else {
                    print("Fetch error: \(error?.localizedDescription ?? "Unknown error")")
                    return
                }

                do {
                    let fetchedEvents = try snapshot.documents.compactMap {
                        try $0.data(as: CalendarEvent.self)
                    }
                    DispatchQueue.main.async {
                        self.events = fetchedEvents
                        mergeCommittedHelpCards(viewModel.committedCards)
                    }
                } catch {
                    print("Decoding error: \(error)")
                }
            }
    }

    private func addEventToFirestore(_ event: CalendarEvent) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        var pendingEvent = event
        pendingEvent.id = UUID().uuidString
        self.events.append(pendingEvent)
        self.events.sort { $0.date < $1.date }

        do {
            var ref: DocumentReference? = nil
            ref = try db.collection("users").document(uid).collection("calendarEvents")
                .addDocument(from: event) { err in
                    if let err = err {
                        print("Error adding event: \(err.localizedDescription)")
                    } else if let docID = ref?.documentID {
                        DispatchQueue.main.async {
                            self.events.removeAll { $0.id == pendingEvent.id }
                            var savedEvent = event
                            savedEvent.id = docID
                            self.events.append(savedEvent)
                            self.events.sort { $0.date < $1.date }
                            self.dailyPointsVM.addPoints(3)
                        }
                    }
                }
        } catch {
            print("Encoding error: \(error.localizedDescription)")
        }
    }

    private func mergeCommittedHelpCards(_ committedCards: [HelpCard]) {
        let newEvents = committedCards.flatMap { card in
            card.availabilityDates.map { date in
                CalendarEvent(fromHelpCard: card, date: date)
            }
        }
        
        let allEvents = events.filter { e in
            !newEvents.contains { $0.id == e.id }
        } + newEvents
        
        self.events = allEvents.sorted { $0.date < $1.date }
    }
}

struct MonthlyCalendarView: View {
    @Binding var selectedDate: Date
    let events: [CalendarEvent]
    
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible()), count: 7)

    private var monthDates: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: selectedDate),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate)) else {
            return []
        }

        var dates = [Date]()
        let weekdayOfFirst = calendar.component(.weekday, from: firstDay)
        let firstWeekdayIndex = calendar.firstWeekday
        let offset = (weekdayOfFirst - firstWeekdayIndex + 7) % 7

        for _ in 0..<offset { dates.append(Date.distantPast) }
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                dates.append(date)
            }
        }
        return dates
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(monthTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.vertical, 6)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthDates, id: \.self) { date in
                    if calendar.isDate(date, equalTo: Date.distantPast, toGranularity: .day) {
                        Color.clear.frame(width: 36, height: 36)
                    } else {
                        let isToday = calendar.isDateInToday(date)
                        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                        let hasEvents = eventsForDay(date).count > 0

                        VStack(spacing: 4) {
                            Text("\(calendar.component(.day, from: date))")
                                .fontWeight(isSelected ? .bold : .regular)
                                .foregroundColor(isSelected ? Color.blue.opacity(0.9) : (isToday ? Color.blue.opacity(0.8) : .white))
                                .frame(width: 36, height: 36)

                            if hasEvents {
                                HStack(spacing: 4) {
                                    ForEach(Array(Set(eventsForDay(date).map { $0.type.lowercased() })).prefix(3), id: \.self) { type in
                                        Circle()
                                            .fill(eventTypeColor(type).opacity(0.35))
                                            .frame(width: 6, height: 6)
                                    }
                                }
                            } else {
                                Spacer().frame(height: 6)
                            }
                        }
                        .padding(6)
                        .background(isSelected ? Color.blue.opacity(0.2) : Color.clear)
                        .cornerRadius(8)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedDate = date }
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func eventsForDay(_ date: Date) -> [CalendarEvent] {
        events.filter { calendar.isDate($0.date, inSameDayAs: date) }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: selectedDate)
    }

    private func eventTypeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "important": return .red
        case "medical": return .blue
        case "appointment": return .yellow
        case "personal": return .green
        default: return .purple
        }
    }
}

struct AddEventView: View {
    @Environment(\.dismiss) var dismiss
    var onSave: (CalendarEvent) -> Void

    @State private var name = ""
    @State private var date = Date()
    @State private var type = "important"

    let eventTypes = ["important", "medical", "appointment", "personal", "other"]

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
                        ForEach(eventTypes, id: \.self) { t in
                            Text(t.capitalized)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
            }
            .navigationBarTitle("New Event", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Save") {
                    let event = CalendarEvent(name: name, date: date, type: type)
                    onSave(event)
                    dismiss()
                }
                .disabled(name.isEmpty)
            )
        }
        .preferredColorScheme(.dark)
    }
}
