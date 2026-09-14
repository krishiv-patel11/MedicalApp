import SwiftUI
import FirebaseCore
import Firebase
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Combine

enum AppTab: Equatable {
    case home, medication, benefits, help, calendar, community, settings
}

struct DailyPointsManager {
    private let db = Firestore.firestore()
    private let calendar = Calendar.current
    private var userDoc: DocumentReference? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return db.collection("users").document(uid)
    }
    
    func getPoints(completion: @escaping (Int) -> Void) {
        guard let userDoc = userDoc else { return }
        userDoc.getDocument { snapshot, error in
            if let data = snapshot?.data(),
               let points = data["dailyPoints"] as? Int {
                completion(points)
            } else {
                completion(0)
            }
        }
    }
    
    func setPoints(_ points: Int) {
        guard let userDoc = userDoc else { return }
        userDoc.setData(["dailyPoints": points], merge: true)
    }
    
    func resetIfNeeded(completion: @escaping (Int) -> Void) {
        guard let userDoc = userDoc else { return }
        
        let today = calendar.startOfDay(for: Date())
        
        userDoc.getDocument { snapshot, error in
            var needsReset = false
            if let data = snapshot?.data(),
               let lastResetTimestamp = data["lastResetDate"] as? Timestamp {
                let lastResetDate = lastResetTimestamp.dateValue()
                if lastResetDate < today {
                    needsReset = true
                }
            } else {
                needsReset = true
            }
            
            if needsReset {
                userDoc.setData([
                    "dailyPoints": 0,
                    "lastResetDate": Timestamp(date: today)
                ], merge: true)
                completion(0)
            } else {
                self.getPoints(completion: completion)
            }
        }
    }
}

class DailyPointsViewModel: ObservableObject {
    @Published private(set) var points: Int = 0
    private let maxPoints = 100
    private var pointsManager: DailyPointsManager?
    private var authStateListener: AuthStateDidChangeListenerHandle?
    private var midnightTimer: Timer?

    init() {
        setupAuthListener()
    }

    private func setupAuthListener() {
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self = self else { return }
            if user != nil {
                self.pointsManager = DailyPointsManager()
                self.loadPointsForCurrentUser()
                self.scheduleMidnightReset()
            } else {
                DispatchQueue.main.async {
                    self.points = 0
                }
                self.pointsManager = nil
                self.invalidateMidnightTimer()
            }
        }
    }

    func loadPointsForCurrentUser() {
        pointsManager?.resetIfNeeded { [weak self] points in
            DispatchQueue.main.async {
                self?.points = points
            }
        }
    }

    func addPoints(_ pointsToAdd: Int) {
        var newPoints = points + pointsToAdd
        if newPoints > maxPoints {
            newPoints = maxPoints
        }
        pointsManager?.setPoints(newPoints)
        points = newPoints
    }

    func resetPoints() {
        pointsManager?.setPoints(0)
        points = 0
    }

    var progress: Double {
        Double(points) / Double(maxPoints)
    }

    private func scheduleMidnightReset() {
        invalidateMidnightTimer()

        guard let nextMidnight = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour:0, minute:0, second:0), matchingPolicy: .nextTime) else {
            return
        }

        let interval = nextMidnight.timeIntervalSinceNow
        midnightTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.resetPoints()
            self.scheduleMidnightReset()
        }
    }

    private func invalidateMidnightTimer() {
        midnightTimer?.invalidate()
        midnightTimer = nil
    }

    deinit {
        if let handle = authStateListener {
            Auth.auth().removeStateDidChangeListener(handle)
        }
        invalidateMidnightTimer()
    }
}

struct HomeView: View {
    @State private var selectedTab: AppTab = .home
    @State private var name: String = ""
    @State private var role: String = ""
    @State private var userCity: String = ""
    @State private var userState: String = ""
    @State private var calendarEvents: [CalendarEvent] = []
    @State private var isLoading: Bool = false
    @State private var animatedProgress: Double = 0.0
    @State private var showingInbox = false
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings
    @EnvironmentObject var authViewModel: AuthViewModel
    @EnvironmentObject var medicationVM: MedicationListViewModel
    @EnvironmentObject var dailyPointsVM: DailyPointsViewModel
    @StateObject var viewModel: MainViewModel
    
    private let db = Firestore.firestore()
    
    private var safeAreaBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom }
            .first ?? 0
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                contentView
                    .padding(.bottom, safeAreaBottom + 16)
                    .background(Color.black.edgesIgnoringSafeArea(.all))
                
                if authViewModel.isLoggedIn {
                    VStack(spacing: 0) {
                        Spacer()
                        CustomNavBar(selectedTab: $selectedTab)
                            .frame(maxWidth: .infinity)
                            .background(Color.black)
                            .offset(y: -15)
                    }
                    .edgesIgnoringSafeArea(.bottom)
                }
            }
            .task {
                if authViewModel.isLoggedIn {
                    await loadInitialData()
                }
            }
            .onAppear {
                if authViewModel.isLoggedIn {
                    observeCalendarEvents()
                    Task { await fetchUserData() }
                    dailyPointsVM.loadPointsForCurrentUser()
                }
                if selectedTab == .home {
                    animatedProgress = dailyPointsVM.progress
                }
            }
            .onChange(of: selectedTab) { newTab in
                if newTab == .home {
                    animatedProgress = dailyPointsVM.progress
                    medicationVM.fetchMedications()
                }
            }
            .onChange(of: authViewModel.isLoggedIn) { loggedIn in
                if loggedIn {
                    Task {
                        await loadInitialData()
                        observeCalendarEvents()
                    }
                    dailyPointsVM.loadPointsForCurrentUser()
                } else {
                    dailyPointsVM.resetPoints()
                    clearUserData()
                }
            }
            .onReceive(dailyPointsVM.$points) { _ in
                withAnimation(.easeInOut(duration: 1.0)) {
                    animatedProgress = dailyPointsVM.progress
                }
            }
            .navigationTitle(selectedTab == .home ? "Home" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if selectedTab == .home {
                        WordSpeakableText(text: "Home")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .home: homeMainContent
        case .medication: MedicationView()
        case .benefits: BenefitsView()
        case .help: MainView()
        case .calendar: CalendarView(viewModel: viewModel)
        case .community: CommunityView()
        case .settings: SettingsView()
        }
    }
    
    private var homeMainContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                progressSection
                medicationsBar
                calendarBar
                if viewModel.userRole == "in_need" {
                    postedCardsBar
                } else {
                    committedCardsBar
                }
                quickActionsSection
            }
            .padding([.horizontal, .top])
            .frame(maxWidth: UIScreen.main.bounds.width)
            .clipped()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("Welcome, \(name.isEmpty ? "User" : name)")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
            
            WordSpeakableText(
                text: DateFormatter.localizedString(
                    from: Date(),
                    dateStyle: .medium,
                    timeStyle: .none
                )
            )
            .font(.system(size: 15))
            .foregroundColor(.white.opacity(0.75))
        }
    }
    
    private var progressSection: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 14)
                .frame(width: 160, height: 160)
            Circle()
                .trim(from: 0, to: CGFloat(animatedProgress))
                .stroke(Color.blue.opacity(0.6), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 160, height: 160)
            VStack(spacing: 4) {
                WordSpeakableText(text: "CareConnect Score")
                    .foregroundColor(.white)
                    .font(.system(size: 13))
                Text("\(Int(animatedProgress * 100))%")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
    
    private var medicationsBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            barHeader(icon: "pills.fill", title: "Today's Medications")
            if medicationVM.medications.isEmpty {
                placeholderText("No medications for today")
            } else {
                VStack(spacing: 8) {
                    ForEach(medicationVM.medications, id: \.id) { med in
                        NavigationLink(destination: MedicationView()) {
                            medicationRow(med: med)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(14)
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            barHeader(icon: "bolt.fill", title: "Quick Actions")

            HStack(spacing: 10) {
                quickActionButton(
                    title: "Medications",
                    subtitle: "View & manage",
                    icon: "pills.fill"
                ) {
                    selectedTab = .medication
                }

                quickActionButton(
                    title: "Get Help",
                    subtitle: "Find support",
                    icon: "hands.sparkles.fill"
                ) {
                    selectedTab = .help
                }
            }

            HStack(spacing: 10) {
                quickActionButton(
                    title: "Community",
                    subtitle: "Connect locally",
                    icon: "person.3.fill"
                ) {
                    selectedTab = .community
                }

                quickActionButton(
                    title: "Benefits",
                    subtitle: "Find resources",
                    icon: "doc.text.fill"
                ) {
                    selectedTab = .benefits
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(14)
    }

    private func quickActionButton(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.cyan)

                WordSpeakableText(text: title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                WordSpeakableText(text: subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var calendarBar: some View {
        NavigationLink(destination: CalendarView(viewModel: viewModel)) {
            VStack(alignment: .leading, spacing: 12) {
                barHeader(icon: "calendar", title: "Upcoming Events", showChevron: true)
                let upcomingEvents = calendarEvents.filter { $0.date >= Date() }
                
                let committedCardEvents = viewModel.committedCards.flatMap { card in
                    card.availabilityDates
                        .filter { $0 >= Date() }
                        .map { date in
                            CalendarEvent(fromHelpCard: card, date: date)
                        }
                }

                let combinedUpcoming = (upcomingEvents + committedCardEvents)
                    .sorted(by: { $0.date < $1.date })

                if combinedUpcoming.isEmpty {
                    placeholderText("No upcoming events")
                } else {
                    VStack(spacing: 6) {
                        ForEach(combinedUpcoming.prefix(3)) { event in
                            HStack {
                                WordSpeakableText(text: event.name)
                                    .foregroundColor(.white)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text(formattedDateTime(event.date))
                                    .foregroundColor(.blue.opacity(0.8))
                                    .font(.caption)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(14)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var committedCardsBar: some View {
        cardListBar(title: "My Accepted Cards", icon: "checkmark.seal.fill", cards: viewModel.committedCards)
    }

    private var postedCardsBar: some View {
        cardListBar(
            title: "My Accepted Cards",
            icon: "checkmark.circle.fill",
            cards: viewModel.acceptedHelpCards.filter { card in
                guard let nextDate = card.availabilityDates.sorted().first else { return false }
                return nextDate >= Date()
            }
        )
    }
    
    private func cardListBar(title: String, icon: String, cards: [HelpCard]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            barHeader(icon: icon, title: title)
            
            if cards.isEmpty {
                placeholderText("No cards available")
            } else {
                VStack(spacing: 10) {
                    ForEach(cards, id: \.id) { card in
                        NavigationLink(destination: destinationView(for: card)) {
                            cardRow(card: card)
                                .padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(14)
    }

    private func destinationView(for card: HelpCard) -> some View {
        viewModel.userRole == "helper"
            ? AnyView(SupportView(viewModel: viewModel, showingInbox: $showingInbox))
            : AnyView(HelpView(viewModel: viewModel))
    }


    private func cardRow(card: HelpCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WordSpeakableText(text: card.title)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            
            if !card.notes.isEmpty {
                WordSpeakableText(text: card.notes)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            
            if let nextDate = card.availabilityDates.sorted().first {
                WordSpeakableText(text: formattedDate(nextDate))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(12)
        .frame(minWidth: 0, maxWidth: .infinity)
        .cornerRadius(10)
    }

    private func barHeader(icon: String, title: String, showChevron: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            if showChevron {
                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
            }
        }
    }

    private func placeholderText(_ text: String) -> some View {
        Text(text)
            .foregroundColor(.gray)
            .font(.caption)
            .italic()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func medicationRow(med: Medication) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                WordSpeakableText(text: med.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
                    .font(.caption)
            }
            ForEach(med.times.sorted(), id: \.self) { time in
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.blue)
                        .font(.caption)
                    Text(time.formatted(date: .omitted, time: .shortened))
                        .foregroundColor(.gray)
                        .font(.caption)
                }
            }
        }
        .padding(8)
        .cornerRadius(8)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formattedDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    @MainActor
    private func loadInitialData() async {
        guard FirebaseApp.app() != nil else { return }
        await viewModel.fetchUserData()
        await viewModel.fetchUserHelpCards()
        medicationVM.fetchMedications()
    }
    
    @MainActor
    private func fetchUserData() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let snapshot = try await db.collection("users").document(uid).getDocument()
            guard let data = snapshot.data() else { return }
            role = data["role"] as? String ?? ""
            userCity = data["city"] as? String ?? ""
            name = data["name"] as? String ?? ""
            userState = data["state"] as? String ?? ""
        } catch { print("Error fetching user data: \(error)") }
    }
    
    private func observeCalendarEvents() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        db.collection("users").document(uid).collection("calendarEvents")
            .order(by: "date")
            .addSnapshotListener { snapshot, error in
                if let error = error { print("Error fetching events: \(error)"); return }
                guard let docs = snapshot?.documents else { return }
                let events = docs.compactMap { try? $0.data(as: CalendarEvent.self) }
                DispatchQueue.main.async { calendarEvents = events }
            }
    }
    
    private func clearUserData() {
        name = ""; role = ""; userCity = ""; userState = ""
        calendarEvents = []
        medicationVM.medications.removeAll()
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .background(Color.white.opacity(0.03))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            )
    }
}

struct CustomNavBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            navBarButton(icon: "house.fill", tab: .home)
            navBarButton(icon: "pills.fill", tab: .medication)
            navBarButton(icon: "doc.text.fill", tab: .benefits)

            Spacer(minLength: 8)

            helperButton()

            Spacer(minLength: 8)

            navBarButton(icon: "calendar", tab: .calendar)
            navBarButton(icon: "person.3.fill", tab: .community)
            navBarButton(icon: "gearshape.fill", tab: .settings)
        }
        .padding(.horizontal)
        .frame(height: 70)
        .background(Color.black)
        .shadow(radius: 2)
    }

    private func navBarButton(icon: String, tab: AppTab) -> some View {
        Button(action: {
            selectedTab = tab
        }) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(selectedTab == tab ? .cyan : .gray)
                .frame(maxWidth: .infinity)
        }
    }

    private func helperButton() -> some View {
        Button(action: {
            selectedTab = .help
        }) {
            Image(systemName: "text.page.badge.magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(.primary)
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        var chunks: [[Element]] = []
        var index = 0
        while index < self.count {
            let end = Swift.min(index + size, self.count)
            chunks.append(Array(self[index..<end]))
            index += size
        }
        return chunks
    }
}
