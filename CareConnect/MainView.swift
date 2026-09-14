import SwiftUI
import Foundation
import Firebase
import FirebaseFirestore
import FirebaseAuth
import Combine

struct MainView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @EnvironmentObject var dailyPointsVM: DailyPointsViewModel

    @StateObject private var viewModel: MainViewModel

    @State private var showingInbox = false

    init() {
        _viewModel = StateObject(wrappedValue: MainViewModel(dailyPointsVM: DailyPointsViewModel()))
    }

    var body: some View {
        Group {
            if viewModel.userRole == "in_need" {
                SupportView(viewModel: viewModel, showingInbox: $showingInbox)
            } else if viewModel.userRole == "helper" {
                HelpView(viewModel: viewModel)
            } else {
                ProgressView("Loading...")
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
            }
        }
        .onAppear {
            viewModel.dailyPointsVM = dailyPointsVM
            Task {
                await viewModel.fetchUserData()
            }
        }
        .sheet(isPresented: $showingInbox) {
            InboxView()
                .environmentObject(viewModel)
        }
    }
}



struct InboxMessage: Identifiable, Codable {
    @DocumentID var id: String?
    var fromUserId: String
    var fromName: String
    var fromEmail: String
    var fromPhone: String
    var helpCardTitle: String
    var helpCardType: String
    var helpCardNotes: String
    var timestamp: Date?
}

struct User: Identifiable, Codable {
    @DocumentID var id: String?
    var name: String
    var email: String
    var phone: String
    var city: String
    var state: String
    var role: String
    var notes: String
    var needs: [String]
    var daysNeeded: [String]
    @ServerTimestamp var createdAt: Date?
}

@MainActor
class MainViewModel: ObservableObject {
    @Published var userRole: String = ""
    @Published var userCity: String = ""
    @Published var supportCards: [HelpCard] = []
    @Published var committedCards: [HelpCard] = []
    @Published var acceptedHelpCards: [HelpCard] = []
    @Published var inboxMessages: [InboxMessage] = []
    @Published var starredCards: [HelpCard] = []
    @Published var matchedCards: [HelpCard] = []
    @Published var helpCards: [HelpCard] = []
    @Published var otherCards: [HelpCard] = []
    @Published var filteredSupportCards: [HelpCard] = []

    private let db = Firestore.firestore()
    var dailyPointsVM: DailyPointsViewModel
    private var postedCardsListener: ListenerRegistration?
    private var allCardsListener: ListenerRegistration?
    private var committedCardsListener: ListenerRegistration?
    private var inboxListener: ListenerRegistration?
    private var userDocListener: ListenerRegistration?
    private var timerCancellable: AnyCancellable?

    private var allHelpCards: [HelpCard] = []
    private var currentNeeds: [String] = []
    private var currentHiddenIds: [String] = []

    init(dailyPointsVM: DailyPointsViewModel) {
        self.dailyPointsVM = dailyPointsVM

        timerCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.applyFiltering()
                self?.cleanupExpiredCards()
            }

        listenToUserDocChanges()
        listenToCommittedCards()
    }

    deinit {
        let posted = postedCardsListener
        let all = allCardsListener
        let committed = committedCardsListener
        let inbox = inboxListener
        let userDoc = userDocListener
        let timer = timerCancellable

        postedCardsListener = nil
        allCardsListener = nil
        committedCardsListener = nil
        inboxListener = nil
        userDocListener = nil
        timerCancellable = nil
        
        DispatchQueue.global(qos: .background).async {
            posted?.remove()
            all?.remove()
            committed?.remove()
            inbox?.remove()
            userDoc?.remove()
            timer?.cancel()
        }
    }
    
    private func listenToUserDocChanges() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        userDocListener?.remove()
        userDocListener = db.collection("users").document(uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, let data = snapshot?.data(), error == nil else { return }

                self.userRole = data["role"] as? String ?? ""
                self.userCity = data["city"] as? String ?? ""
                self.currentNeeds = data["needs"] as? [String] ?? []
                self.currentHiddenIds = data["hiddenHelpCards"] as? [String] ?? []
                self.listenToCommittedCards()

                if self.userRole == "in_need" {
                    self.listenToInboxMessages(forUser: uid)
                    self.listenToPostedHelpCards()
                    self.listenToAllHelpCards()
                } else {
                    self.inboxListener?.remove()
                    self.inboxMessages = []
                    self.listenToAllHelpCards()
                }

                self.applyCardFiltering()
            }
    }

    func listenToAllHelpCards() {
        allCardsListener?.remove()
        allCardsListener = db.collectionGroup("helpCards")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, error == nil else { return }
                let cards = snapshot?.documents.compactMap { try? $0.data(as: HelpCard.self) } ?? []
                self.allHelpCards = cards
                self.applyCardFiltering()
            }
    }

    func listenToPostedHelpCards() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        postedCardsListener?.remove()
        postedCardsListener = db.collection("users").document(uid)
            .collection("helpCards")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, error == nil else { return }
                let cards = snapshot?.documents.compactMap { try? $0.data(as: HelpCard.self) } ?? []

                DispatchQueue.main.async {
                    self.helpCards = cards
                    self.supportCards = cards.filter { !$0.isCommitted }
                    self.acceptedHelpCards = cards.filter { $0.isCommitted }
                    self.applyCardFiltering()
                }
            }
    }

    func listenToCommittedCards() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        committedCardsListener?.remove()

        if userRole == "helper" {
            committedCardsListener = db.collectionGroup("helpCards")
                .whereField("committedBy", isEqualTo: uid)
                .addSnapshotListener { [weak self] snapshot, error in
                    guard let self = self, error == nil else { return }
                    let cards = snapshot?.documents.compactMap { try? $0.data(as: HelpCard.self) } ?? []
                    self.committedCards = self.filterFutureAvailabilityCards(cards)
                    self.applyCardFiltering()
                }
        } else if userRole == "in_need" {
            committedCardsListener = db.collection("users").document(uid)
                .collection("helpCards")
                .whereField("isCommitted", isEqualTo: true)
                .addSnapshotListener { [weak self] snapshot, error in
                    guard let self = self, error == nil else { return }
                    let cards = snapshot?.documents.compactMap { try? $0.data(as: HelpCard.self) } ?? []
                    self.committedCards = self.filterFutureAvailabilityCards(cards)
                    self.applyCardFiltering()
                }
        }
    }


    private func listenToInboxMessages(forUser uid: String) {
        inboxListener?.remove()
        inboxListener = db.collection("users").document(uid)
            .collection("inbox")
            .order(by: "timestamp", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, error == nil else { return }
                self.inboxMessages = snapshot?.documents.compactMap { try? $0.data(as: InboxMessage.self) } ?? []
            }
    }

    private func applyCardFiltering() {
        let visibleCards = allHelpCards.filter { !currentHiddenIds.contains($0.id ?? "") }

        let futureCards = visibleCards.filter { $0.availabilityDates.contains { $0 > Date() } }

        let starred = futureCards.filter { card in
            guard let uid = Auth.auth().currentUser?.uid else { return false }
            return card.starredBy?.contains(uid) == true
        }

        let matched = futureCards.filter { card in
            currentNeeds.contains { $0.caseInsensitiveCompare(card.type) == .orderedSame }
        }

        let others = futureCards.filter { card in
            card.city.lowercased() == self.userCity.lowercased()
                && !(starred.contains { $0.id == card.id })
                && !(matched.contains { $0.id == card.id })
        }

        if userRole == "helper" {
            starredCards = starred
            matchedCards = matched
            otherCards   = others
            acceptedHelpCards = committedCards
        } else {
            acceptedHelpCards = committedCards

            func notInCommitted(_ card: HelpCard) -> Bool {
                guard let id = card.id else { return true }
                return !committedCards.contains { $0.id == id }
            }

            starredCards = starred.filter(notInCommitted)
            matchedCards = matched.filter(notInCommitted)
            otherCards   = others.filter(notInCommitted)
            supportCards = starredCards + matchedCards + otherCards
        }

        applyFiltering()
    }
    
    func notInCommitted(_ card: HelpCard) -> Bool {
        guard let id = card.id else { return true }
        return !committedCards.contains { $0.id == id }
    }

    private func applyFiltering() {
        filteredSupportCards = filterFutureAvailabilityCards(supportCards)
    }

    func fetchUserData() async -> (role: String, city: String)? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        do {
            let snapshot = try await db.collection("users").document(uid).getDocument()
            guard let data = snapshot.data() else { return nil }

            let role = data["role"] as? String ?? ""
            let city = data["city"] as? String ?? ""

            self.userRole = role
            self.userCity = city
            return (role, city)
        } catch {
            print("Error fetching user data: \(error)")
            return nil
        }
    }

    func addSingleHelpCard(
        title: String,
        type: String,
        name: String,
        contactInfo: String,
        notes: String,
        availabilityDates: [Date],
        city: String
    ) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let newCard = HelpCard(
            id: UUID().uuidString,
            title: title,
            contactInfo: contactInfo,
            name: name,
            availabilityDates: availabilityDates,
            type: type,
            notes: notes,
            city: city,
            starredBy: [],
            ownerId: userId,
            isCommitted: false,
            committedBy: nil
        )

        do {
            try db.collection("users")
                .document(userId)
                .collection("helpCards")
                .document(newCard.id!)
                .setData(from: newCard)
            self.helpCards.append(newCard)
            self.allHelpCards.append(newCard)
            if !newCard.isCommitted {
                self.supportCards.append(newCard)
            } else {
                self.acceptedHelpCards.append(newCard)
            }
            self.applyCardFiltering()

            if userRole == "in_need" {
                dailyPointsVM.addPoints(25)
            }
        } catch {
            print("Error writing new help card: \(error.localizedDescription)")
        }
    }

    func addHelpCardsForMultipleDates(
        title: String,
        type: String,
        name: String,
        contactInfo: String,
        notes: String,
        availabilityDates: [Date],
        city: String
    ) {
        availabilityDates.forEach {
            addSingleHelpCard(
                title: title,
                type: type,
                name: name,
                contactInfo: contactInfo,
                notes: notes,
                availabilityDates: [$0],
                city: city
            )
        }
    }

    func deleteHelpCard(_ card: HelpCard) {
        guard let cardId = card.id,
              let userId = Auth.auth().currentUser?.uid,
              userId == card.ownerId else {
            print("Delete failed: Unauthorized or missing ID")
            return
        }

        db.collection("users")
            .document(userId)
            .collection("helpCards")
            .document(cardId)
            .delete { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    print("Error deleting help card: \(error.localizedDescription)")
                } else {
                    self.helpCards.removeAll { $0.id == cardId }
                    self.supportCards.removeAll { $0.id == cardId }
                    self.acceptedHelpCards.removeAll { $0.id == cardId }
                    self.starredCards.removeAll { $0.id == cardId }
                    self.matchedCards.removeAll { $0.id == cardId }
                    self.otherCards.removeAll { $0.id == cardId }
                    self.allHelpCards.removeAll { $0.id == cardId }
                    self.applyFiltering()
                }
            }
    }

    func acceptHelpCard(_ card: HelpCard) {
        guard let currentUser = Auth.auth().currentUser, let cardId = card.id else { return }
        let userId = currentUser.uid

        db.collection("users").document(card.ownerId)
            .collection("helpCards").document(cardId)
            .updateData([
                "isCommitted": true,
                "committedBy": userId
            ]) { [weak self] error in
                guard let self = self, error == nil else { return }
                self.db.collection("users").document(userId)
                    .updateData(["acceptedHelpCards": FieldValue.arrayUnion([cardId])])

                self.fetchCurrentUser { user in
                    guard let user = user else { return }
                    self.sendInboxMessage(to: card.ownerId, from: user, card: card)
                }

                self.dailyPointsVM.addPoints(15)
                self.supportCards.removeAll { $0.id == cardId }
                self.starredCards.removeAll { $0.id == cardId }
                self.matchedCards.removeAll { $0.id == cardId }
                self.otherCards.removeAll { $0.id == cardId }

                self.applyCardFiltering()
            }
    }

    func hideHelpCardForCurrentUser(_ card: HelpCard) {
        guard let uid = Auth.auth().currentUser?.uid, let cardId = card.id else {
            print("Hide failed: missing user ID or card ID"); return
        }

        db.collection("users").document(uid).updateData([
            "hiddenHelpCards": FieldValue.arrayUnion([cardId])
        ]) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("Failed to hide help card: \(error.localizedDescription)")
            } else {
                self.supportCards.removeAll { $0.id == cardId }
                self.acceptedHelpCards.removeAll { $0.id == cardId }
                self.starredCards.removeAll { $0.id == cardId }
                self.matchedCards.removeAll { $0.id == cardId }
                self.otherCards.removeAll { $0.id == cardId }
                self.applyFiltering()
            }
        }
    }

    func refreshMatchedCards() {
        applyCardFiltering()
    }

    func canInNeedUserTapCard(_ card: HelpCard) -> Bool {
        if userRole == "in_need" { return false }
        guard let id = card.id else { return true }
        return !committedCards.contains { $0.id == id }
    }

    func setSupportCards(_ cards: [HelpCard]) {
        supportCards = cards
        applyFiltering()
    }

    func cleanupExpiredCards() {
        let now = Date()
        func isExpired(_ c: HelpCard) -> Bool { c.availabilityDates.allSatisfy { $0 <= now } }

        let expired = (supportCards + acceptedHelpCards + starredCards + matchedCards + otherCards + committedCards)
            .filter(isExpired)

        guard !expired.isEmpty, let uid = Auth.auth().currentUser?.uid else { return }

        let expiredIds = expired.compactMap { $0.id }

        db.collection("users").document(uid).updateData([
            "hiddenHelpCards": FieldValue.arrayUnion(expiredIds)
        ]) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("Error hiding expired cards: \(error.localizedDescription)")
            }
            self.supportCards.removeAll { expiredIds.contains($0.id ?? "") }
            self.acceptedHelpCards.removeAll { expiredIds.contains($0.id ?? "") }
            self.starredCards.removeAll { expiredIds.contains($0.id ?? "") }
            self.matchedCards.removeAll { expiredIds.contains($0.id ?? "") }
            self.otherCards.removeAll { expiredIds.contains($0.id ?? "") }
            self.committedCards.removeAll { expiredIds.contains($0.id ?? "") }
            self.applyFiltering()
        }
    }

    var upcomingPostedCards: [HelpCard] {
        helpCards.filter { card in
            guard let nextDate = card.availabilityDates.sorted().first else { return false }
            return nextDate >= Date()
        }
    }

    func fetchUserHelpCards() async -> [HelpCard] {
        guard let uid = Auth.auth().currentUser?.uid else { return [] }
        do {
            let snapshot = try await db.collection("users").document(uid)
                .collection("helpCards").getDocuments()
            let cards = snapshot.documents.compactMap { try? $0.data(as: HelpCard.self) }
            let futureCards = filterFutureAvailabilityCards(cards)
            self.helpCards = futureCards
            return futureCards
        } catch {
            print("Error fetching user help cards: \(error)")
            return []
        }
    }

    func fetchCommittedCards() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        db.collectionGroup("helpCards")
            .whereField("committedBy", isEqualTo: uid)
            .getDocuments { [weak self] snapshot, error in
                guard let self = self else { return }
                if let error = error {
                    print("Error fetching committed cards: \(error.localizedDescription)")
                    return
                }
                let cards = snapshot?.documents.compactMap { try? $0.data(as: HelpCard.self) } ?? []
                self.committedCards = self.filterFutureAvailabilityCards(cards)
                self.applyCardFiltering()
            }
    }

    func filterFutureAvailabilityCards(_ cards: [HelpCard]) -> [HelpCard] {
        let now = Date()
        return cards.filter { $0.availabilityDates.contains { $0 > now } }
    }

    private func fetchCurrentUser(completion: @escaping (User?) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else { completion(nil); return }
        db.collection("users").document(uid).getDocument { snapshot, _ in
            guard let snapshot = snapshot else { completion(nil); return }
            completion(try? snapshot.data(as: User.self))
        }
    }

    private func sendInboxMessage(to ownerId: String, from user: User, card: HelpCard) {
        let inboxData: [String: Any] = [
            "fromUserId": user.id ?? "",
            "fromName": user.name,
            "fromEmail": user.email,
            "fromPhone": user.phone,
            "helpCardTitle": card.title,
            "helpCardType": card.type,
            "helpCardNotes": card.notes,
            "timestamp": FieldValue.serverTimestamp()
        ]
        db.collection("users").document(ownerId)
            .collection("inbox").addDocument(data: inboxData)
    }
}

struct HelpCard: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var title: String
    var contactInfo: String
    var name: String
    var availabilityDates: [Date]
    var type: String
    var notes: String
    var city: String
    var starredBy: [String]?
    var ownerId: String
    var isCommitted: Bool = false
    var committedBy: String? = nil
}

struct SupportView: View {
    @ObservedObject var viewModel: MainViewModel
    @Binding var showingInbox: Bool
    @State private var showingAddHelpCard = false

    var body: some View {
        NavigationView {
            List {
                if !viewModel.acceptedHelpCards.isEmpty {
                    CardSectionView(
                        title: "Committed Help Cards",
                        cards: viewModel.acceptedHelpCards,
                        viewModel: viewModel
                    )
                }

                if !viewModel.supportCards.isEmpty {
                    CardSectionView(
                        title: "Available Help Requests",
                        cards: viewModel.supportCards,
                        viewModel: viewModel
                    )
                }

                if viewModel.supportCards.isEmpty && viewModel.acceptedHelpCards.isEmpty {
                    EmptyStateView(message: "No help requests in your area.")
                        .background(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Support Requests")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingInbox = true
                    } label: {
                        Image(systemName: "envelope")
                    }
                    .accessibilityLabel("Open Inbox")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddHelpCard = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Help Card")
                }
            }
            .sheet(isPresented: $showingAddHelpCard) {
                AddHelpCardView(viewModel: viewModel)
            }
        }
    }
}

struct HelpView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 28) {
                    if !viewModel.acceptedHelpCards.isEmpty {
                        CardSectionScrollView(
                            title: "Committed Help Cards",
                            cards: viewModel.acceptedHelpCards,
                            viewModel: viewModel,
                            isInNeedUser: true
                        )
                    }
                    
                    let acceptedIds = Set(viewModel.acceptedHelpCards.compactMap { $0.id })

                    if !viewModel.starredCards.filter({ !acceptedIds.contains($0.id ?? "") }).isEmpty {
                        CardSectionScrollView(
                            title: "Starred Help Cards",
                            cards: viewModel.starredCards.filter { !acceptedIds.contains($0.id ?? "") },
                            viewModel: viewModel,
                            isInNeedUser: true
                        )
                    }

                    if !viewModel.matchedCards.filter({ !acceptedIds.contains($0.id ?? "") }).isEmpty {
                        CardSectionScrollView(
                            title: "Matched Help Cards",
                            cards: viewModel.matchedCards.filter { !acceptedIds.contains($0.id ?? "") },
                            viewModel: viewModel,
                            isInNeedUser: true
                        )
                    }

                    if !viewModel.otherCards.filter({ !acceptedIds.contains($0.id ?? "") }).isEmpty {
                        CardSectionScrollView(
                            title: "Other Help Cards",
                            cards: viewModel.otherCards.filter { !acceptedIds.contains($0.id ?? "") },
                            viewModel: viewModel,
                            isInNeedUser: true
                        )
                    }

                    if allHelpSectionsEmpty {
                        EmptyStateView(message: "No help requests in your area yet.")
                            .padding(.top, 50)
                    }
                }
                .padding(.horizontal)
                .padding(.top)
            }
            .navigationTitle("Help Requests")
        }
    }

    private var allHelpSectionsEmpty: Bool {
        !(!viewModel.acceptedHelpCards.isEmpty ||
          !viewModel.starredCards.filter({ !Set(viewModel.acceptedHelpCards.compactMap { $0.id }).contains($0.id ?? "") }).isEmpty ||
          !viewModel.matchedCards.filter({ !Set(viewModel.acceptedHelpCards.compactMap { $0.id }).contains($0.id ?? "") }).isEmpty ||
          !viewModel.otherCards.filter({ !Set(viewModel.acceptedHelpCards.compactMap { $0.id }).contains($0.id ?? "") }).isEmpty)
    }
}

struct CardSectionView: View {
    let title: String
    let cards: [HelpCard]
    let viewModel: MainViewModel

    var body: some View {
        Section(header: SectionHeader(title: title)) {
            ForEach(cards) { card in
                HelpCardView(card: card, viewModel: viewModel)
                    .listRowBackground(Color.clear)
            }
        }
    }
}

struct CardSectionScrollView: View {
    let title: String
    let cards: [HelpCard]
    let viewModel: MainViewModel
    let isInNeedUser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            VStack(spacing: 12) {
                ForEach(cards) { card in
                    HelpCardView(card: card, viewModel: viewModel, isInNeedUser: isInNeedUser)
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        WordSpeakableText(text: title)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundColor(.primary)
    }
}

struct EmptyStateView: View {
    let message: String

    var body: some View {
        VStack {
            WordSpeakableText(text: message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

struct HelpCardSectionView: View {
    let title: String
    let cards: [HelpCard]
    var viewModel: MainViewModel
    var isInNeedUser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            WordSpeakableText(text: title)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .padding(.horizontal, 4)

            ForEach(cards) { card in
                HelpCardView(card: card, viewModel: viewModel, isInNeedUser: isInNeedUser)
            }
        }
    }
}
struct AddHelpCardView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var title = ""
    @State private var type = "Medical"
    @State private var contactInfo = ""
    @State private var name = ""
    @State private var notes = ""

    @State private var showingDatePicker = false
    @State private var newAvailabilityDate = Date()
    @State private var availabilityDates: [Date] = []

    private let db = Firestore.firestore()
    private let types = ["Medical", "Groceries", "Companionship", "Transportation", "Other"]

    var body: some View {
        NavigationView {
            Form {
                Section("Request Info") {
                    TextField("Title", text: $title)

                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { typeOption in
                            WordSpeakableText(text: typeOption).tag(typeOption)
                        }
                    }
                    .pickerStyle(.menu)
                    TextField("Name", text: $name)
                        .autocapitalization(.words)
                    TextField("Contact Info (Phone)", text: $contactInfo)
                        .keyboardType(.phonePad)

                    TextField("Notes", text: $notes)
                }

                Section("Availability") {
                    if availabilityDates.isEmpty {
                        WordSpeakableText(text: "No availability slots added")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(availabilityDates, id: \.self) { date in
                            WordSpeakableText(text: date.formatted(date: .abbreviated, time: .shortened))
                                .font(.callout)
                        }
                        .onDelete(perform: { indexSet in
                            availabilityDates.remove(atOffsets: indexSet)
                        })
                    }

                    Button("Add Availability Slot") {
                        newAvailabilityDate = Date()
                        showingDatePicker = true
                    }
                }
            }
            .navigationTitle("Add Help Card")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.addHelpCardsForMultipleDates(
                            title: title,
                            type: type.lowercased(),
                            name: name,
                            contactInfo: contactInfo,
                            notes: notes,
                            availabilityDates: availabilityDates,
                            city: viewModel.userCity
                        )
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(title.isEmpty || type.isEmpty || name.isEmpty || contactInfo.isEmpty || availabilityDates.isEmpty)
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingDatePicker) {
                VStack(spacing: 20) {
                    DatePicker("Select Date & Time", selection: $newAvailabilityDate, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .padding()

                    HStack(spacing: 20) {
                        Button("Add") {
                            availabilityDates.append(newAvailabilityDate)
                            showingDatePicker = false
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Cancel") {
                            showingDatePicker = false
                        }
                    }
                    .padding(.bottom)
                }
                .padding()
            }
            .onAppear(perform: loadUserInfo)
        }
    }

    private func loadUserInfo() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        let userDocRef = db.collection("users").document(userId)
        userDocRef.getDocument { document, error in
            if let document = document, document.exists {
                let data = document.data()
                if let fetchedName = data?["name"] as? String {
                    DispatchQueue.main.async {
                        if name.isEmpty { name = fetchedName }
                    }
                }
                if let fetchedPhone = data?["phone"] as? String {
                    DispatchQueue.main.async {
                        if contactInfo.isEmpty { contactInfo = fetchedPhone }
                    }
                }
            } else if let error = error {
                print("Error fetching user info: \(error.localizedDescription)")
            }
        }
    }
}

struct HelpCardView: View {
    let card: HelpCard
    @ObservedObject var viewModel: MainViewModel
    var isInNeedUser: Bool = false

    @State private var isStarred: Bool = false
    @State private var showDetail = false
    private let db = Firestore.firestore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    WordSpeakableText(text: card.title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    WordSpeakableText(text: card.type.capitalized)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(8)
                }

                Spacer()

                if isInNeedUser {
                    Button(action: toggleStar) {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .foregroundColor(isStarred ? .yellow : .gray)
                            .imageScale(.large)
                            .padding(6)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label(card.name, systemImage: "person.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Label(card.contactInfo, systemImage: "phone.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if !card.availabilityDates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    WordSpeakableText(text: "Availability")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ForEach(card.availabilityDates, id: \.self) { date in
                        WordSpeakableText(text: date.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if !card.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    WordSpeakableText(text: "Notes")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    WordSpeakableText(text: card.notes)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            if viewModel.userRole == "in_need", card.ownerId == Auth.auth().currentUser?.uid {
                Button(role: .destructive) {
                    print("Delete tapped")
                    viewModel.deleteHelpCard(card)
                } label: {
                    Label("Delete Help Card", systemImage: "trash")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }

            if viewModel.userRole == "in_need" {
                Button {
                    print("Don't Show Again tapped")
                    viewModel.hideHelpCardForCurrentUser(card)
                } label: {
                    Label("Don't Show Again", systemImage: "eye.slash")
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
        )
        .padding(.horizontal)
        .onTapGesture {
            if viewModel.canInNeedUserTapCard(card) {
                showDetail = true
            }
        }
        .sheet(isPresented: $showDetail) {
            HelpCardDetailView(card: card) {
                viewModel.acceptHelpCard(card)
            }
        }
        .onAppear {
            if isInNeedUser, let uid = Auth.auth().currentUser?.uid {
                isStarred = card.starredBy?.contains(uid) ?? false
            }
        }
    }
    
    private func toggleStar() {
        guard let uid = Auth.auth().currentUser?.uid,
              let cardId = card.id else { return }

        let docRef = db.collection("users")
            .document(card.ownerId)
            .collection("helpCards")
            .document(cardId)

        var updatedStarredBy = card.starredBy ?? []

        if isStarred {
            updatedStarredBy.removeAll { $0 == uid }
        } else {
            updatedStarredBy.append(uid)
        }

        docRef.updateData(["starredBy": updatedStarredBy]) { error in
            if let error = error {
                print("Error updating star: \(error.localizedDescription)")
            } else {
                DispatchQueue.main.async {
                    isStarred.toggle()
                }
            }
        }
    }
}

struct HelpCardDetailView: View {
    let card: HelpCard
    var onVerifiedAndCommitted: () -> Void
    @State private var cardToAccept: HelpCard?
    @Environment(\.presentationMode) var presentationMode
    @State private var showVerification = false
    @State private var showCommitment = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WordSpeakableText(text: card.title)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    detailRow(label: "Type:", value: card.type.capitalized)
                    detailRow(label: "Posted by:", value: card.name)
                    detailRow(label: "Contact:", value: card.contactInfo)

                    if !card.availabilityDates.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            WordSpeakableText(text: "Availability:")
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            ForEach(card.availabilityDates, id: \.self) { date in
                                WordSpeakableText(text: date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.callout)
                            }
                        }
                    }

                    if !card.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            WordSpeakableText(text: "Additional Notes:")
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            WordSpeakableText(text: card.notes)
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                    }

                    Spacer(minLength: 40)

                    Button(action: {
                            cardToAccept = card
                            showVerification = true
                        }) {
                        WordSpeakableText(text: "Accept")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .cornerRadius(12)
                            .shadow(color: Color.green.opacity(0.6), radius: 6, x: 0, y: 4)
                    }
                }
                .padding()
            }
            .navigationTitle("Help Request")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showVerification) {
                VerificationView(card: card) {
                    showVerification = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showCommitment = true
                    }
                }
            }
            .sheet(isPresented: $showCommitment) {
                CommitmentView(card: card) {
                    onVerifiedAndCommitted()
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            WordSpeakableText(text: label)
                .bold()
                .foregroundColor(.secondary)
            Spacer()
            WordSpeakableText(text: value)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.primary)
        }
        .font(.body)
    }
}

struct VerificationView: View {
    let card: HelpCard
    var onVerified: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var code: String
    @State private var input: String = ""
    @State private var error: String?

    init(card: HelpCard, onVerified: @escaping () -> Void) {
        self.card = card
        self.onVerified = onVerified
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
        self._code = State(initialValue: String((0..<6).compactMap { _ in chars.randomElement() }))
    }

    var body: some View {
        VStack(spacing: 30) {
            WordSpeakableText(text: "Verification Code")
                .font(.title2)
                .fontWeight(.semibold)

            WordSpeakableText(text: code)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .padding()
                .background(Color.blue.opacity(0.15))
                .cornerRadius(10)
                .textSelection(.enabled)

            TextField("Re-enter Code", text: $input)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.asciiCapable)
                .autocapitalization(.allCharacters)
                .disableAutocorrection(true)
                .padding(.horizontal)

            if let error = error {
                WordSpeakableText(text: error)
                    .foregroundColor(.red)
                    .font(.callout)
            }

            Button("Confirm") {
                if input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == code {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onVerified()
                    }
                } else {
                    error = "Code does not match. Please try again."
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
        .padding()
    }
}

struct CommitmentView: View {
    let card: HelpCard
    let onCommit: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 30) {
            WordSpeakableText(text: "Do you want to commit to this request?")
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            WordSpeakableText(text: "“\(card.title)” by \(card.name)")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(spacing: 16) {
                Button("Yes, I Commit") {
                    onCommit()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
    }
}

struct InboxView: View {
    @StateObject private var viewModel = InboxViewModel()

    var body: some View {
        NavigationView {
            Group {
                if viewModel.messages.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
                            .font(.system(size: 60))
                            .foregroundColor(.gray.opacity(0.5))

                        WordSpeakableText(text: "Your inbox is empty")
                            .foregroundColor(.gray)
                            .font(.title3)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.messages) { message in
                        VStack(alignment: .leading, spacing: 10) {
                            WordSpeakableText(text: "From: \(message.fromName)")
                                .font(.headline)
                                .foregroundColor(.primary)

                            if !message.fromEmail.isEmpty {
                                WordSpeakableText(text: "Email: \(message.fromEmail)")
                                    .foregroundColor(.blue)
                                    .textSelection(.enabled)
                            }

                            if !message.fromPhone.isEmpty {
                                WordSpeakableText(text: "Phone: \(message.fromPhone)")
                                    .textSelection(.enabled)
                            }

                            WordSpeakableText(text: "Help: \(message.helpCardTitle) (\(message.helpCardType))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            if !message.helpCardNotes.isEmpty {
                                WordSpeakableText(text: "Notes: \(message.helpCardNotes)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Inbox")
            .onAppear {
                viewModel.startListening()
            }
        }
    }
}

class InboxViewModel: ObservableObject {
    @Published var messages: [InboxMessage] = []
    private let db = Firestore.firestore()

    func startListening() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        db.collection("users")
            .document(userId)
            .collection("inbox")
            .order(by: "timestamp", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error = error {
                    print("Error listening to inbox: \(error.localizedDescription)")
                    return
                }
                guard let docs = snapshot?.documents else { return }
                self?.messages = docs.compactMap { doc in
                    try? doc.data(as: InboxMessage.self)
                }
                print("Inbox updated: \(self?.messages.count ?? 0) messages")
            }
    }
}
