import SwiftUI
import Swift
import Foundation
import Firebase
import FirebaseAuth
import FirebaseFirestore
import Combine


struct MainView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var dailyPointsVM: DailyPointsViewModel
    @StateObject private var viewModel = MainViewModel()

    var body: some View {
        Group {
            if viewModel.isLoadingUser {
                ProgressView("Loading CareConnect...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.userRole == "in_need" {
                SupportView(viewModel: viewModel)
            } else if viewModel.userRole == "helper" {
                HelpView(viewModel: viewModel)
            } else {
                ContentUnavailableView(
                    "Profile Not Ready",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Your account details could not be loaded. Please try again.")
                )
            }
        }
        .task {
            viewModel.configure(dailyPointsVM: dailyPointsVM)
            await viewModel.fetchUserData()
        }
    }
}

// MARK: - Models

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
    var postType: String? = nil
    var isCommitted: Bool = false
    var committedBy: String? = nil
}

// MARK: - Main View Model

@MainActor
final class MainViewModel: ObservableObject {
    @Published var userRole = ""
    @Published var userCity = ""
    @Published var supportCards: [HelpCard] = []
    @Published var committedCards: [HelpCard] = []
    @Published var acceptedHelpCards: [HelpCard] = []
    @Published var inboxMessages: [InboxMessage] = []
    @Published var starredCards: [HelpCard] = []
    @Published var matchedCards: [HelpCard] = []
    @Published var helpCards: [HelpCard] = []
    @Published var otherCards: [HelpCard] = []
    @Published var filteredSupportCards: [HelpCard] = []
    @Published private(set) var isLoadingUser = true

    private let db = Firestore.firestore()
    private var dailyPointsVM: DailyPointsViewModel?

    private var postedCardsListener: ListenerRegistration?
    private var allCardsListener: ListenerRegistration?
    private var committedCardsListener: ListenerRegistration?
    private var inboxListener: ListenerRegistration?
    private var userDocListener: ListenerRegistration?
    private var timerCancellable: AnyCancellable?

    private var allHelpCards: [HelpCard] = []
    private var currentNeeds: [String] = []
    private var currentHiddenIds: [String] = []
    private var configuredUserID: String?

    init() {}

    func configure(dailyPointsVM: DailyPointsViewModel) {
        self.dailyPointsVM = dailyPointsVM

        guard let uid = Auth.auth().currentUser?.uid else {
            stopListening()
            isLoadingUser = false
            return
        }

        guard configuredUserID != uid || userDocListener == nil else {
            return
        }

        stopListening()
        configuredUserID = uid
        isLoadingUser = true

        listenToUserDocChanges(for: uid)

        timerCancellable = Timer.publish(
            every: 60,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            self?.applyCardFiltering()
        }
    }

    private func stopListening() {
        postedCardsListener?.remove()
        allCardsListener?.remove()
        committedCardsListener?.remove()
        inboxListener?.remove()
        userDocListener?.remove()
        timerCancellable?.cancel()

        postedCardsListener = nil
        allCardsListener = nil
        committedCardsListener = nil
        inboxListener = nil
        userDocListener = nil
        timerCancellable = nil
        configuredUserID = nil
    }

    deinit {
        postedCardsListener?.remove()
        allCardsListener?.remove()
        committedCardsListener?.remove()
        inboxListener?.remove()
        userDocListener?.remove()
        timerCancellable?.cancel()
    }

    // MARK: User Profile Listener

    private func listenToUserDocChanges(for uid: String) {
        userDocListener = db.collection("users")
            .document(uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                DispatchQueue.main.async {
                    guard error == nil,
                          let data = snapshot?.data() else {
                        self.isLoadingUser = false
                        return
                    }

                    self.userRole = data["role"] as? String ?? ""
                    self.userCity = data["city"] as? String ?? ""
                    self.currentNeeds = data["needs"] as? [String] ?? []
                    self.currentHiddenIds =
                        data["hiddenHelpCards"] as? [String] ?? []

                    self.isLoadingUser = false

                    self.listenToCommittedCards()
                    self.listenToPostedHelpCards()
                    self.listenToAllHelpCards()

                    if self.userRole == "in_need" {
                        self.listenToInboxMessages(forUser: uid)
                    } else {
                        self.inboxListener?.remove()
                        self.inboxListener = nil
                        self.inboxMessages = []
                    }

                    self.applyCardFiltering()
                }
            }
    }

    func fetchUserData() async -> (role: String, city: String)? {
        guard let uid = Auth.auth().currentUser?.uid else {
            isLoadingUser = false
            return nil
        }

        do {
            let snapshot = try await db.collection("users")
                .document(uid)
                .getDocument()

            guard let data = snapshot.data() else {
                isLoadingUser = false
                return nil
            }

            let role = data["role"] as? String ?? ""
            let city = data["city"] as? String ?? ""

            userRole = role
            userCity = city
            currentNeeds = data["needs"] as? [String] ?? []
            currentHiddenIds = data["hiddenHelpCards"] as? [String] ?? []
            isLoadingUser = false

            return (role, city)
        } catch {
            print("Error fetching user data: \(error.localizedDescription)")
            isLoadingUser = false
            return nil
        }
    }

    // MARK: Help Card Listeners

    func listenToAllHelpCards() {
        allCardsListener?.remove()

        allCardsListener = db.collectionGroup("helpCards")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self, error == nil else {
                    if let error {
                        print("Error listening to help cards: \(error.localizedDescription)")
                    }
                    return
                }

                let cards = snapshot?.documents.compactMap {
                    try? $0.data(as: HelpCard.self)
                } ?? []

                DispatchQueue.main.async {
                    self.allHelpCards = cards
                    self.applyCardFiltering()
                }
            }
    }

    func listenToPostedHelpCards() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        postedCardsListener?.remove()

        postedCardsListener = db.collection("users")
            .document(uid)
            .collection("helpCards")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self, error == nil else {
                    if let error {
                        print("Error listening to your cards: \(error.localizedDescription)")
                    }
                    return
                }

                let cards = snapshot?.documents.compactMap {
                    try? $0.data(as: HelpCard.self)
                } ?? []

                DispatchQueue.main.async {
                    self.helpCards = self.filterFutureAvailabilityCards(cards)
                    self.applyCardFiltering()
                }
            }
    }

    func listenToCommittedCards() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        committedCardsListener?.remove()

        committedCardsListener = db.collectionGroup("helpCards")
            .whereField("committedBy", isEqualTo: uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self, error == nil else {
                    if let error {
                        print("Error listening to accepted cards: \(error.localizedDescription)")
                    }
                    return
                }

                let cards = snapshot?.documents.compactMap {
                    try? $0.data(as: HelpCard.self)
                } ?? []

                DispatchQueue.main.async {
                    self.committedCards =
                        self.filterFutureAvailabilityCards(cards)
                    self.acceptedHelpCards = self.committedCards
                    self.applyCardFiltering()
                }
            }
    }

    private func listenToInboxMessages(forUser uid: String) {
        inboxListener?.remove()

        inboxListener = db.collection("users")
            .document(uid)
            .collection("inbox")
            .order(by: "timestamp", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self, error == nil else {
                    if let error {
                        print("Error listening to inbox: \(error.localizedDescription)")
                    }
                    return
                }

                let messages = snapshot?.documents.compactMap {
                    try? $0.data(as: InboxMessage.self)
                } ?? []

                DispatchQueue.main.async {
                    self.inboxMessages = messages
                }
            }
    }

    // MARK: Filtering

    private func applyCardFiltering() {
        let now = Date()

        guard let uid = Auth.auth().currentUser?.uid else {
            supportCards = []
            starredCards = []
            matchedCards = []
            otherCards = []
            filteredSupportCards = []
            return
        }

        let visibleCards = allHelpCards.filter { card in
            !currentHiddenIds.contains(card.id ?? "")
                && card.availabilityDates.contains(where: { $0 > now })
        }

        let oppositePostType =
            userRole == "helper" ? "support_request" : "help_offer"

        let availableCards = visibleCards.filter { card in
            let postType = card.postType ?? "support_request"

            return card.ownerId != uid
                && !card.isCommitted
                && postType == oppositePostType
        }

        let starred = availableCards.filter {
            $0.starredBy?.contains(uid) == true
        }

        let matched = availableCards.filter { card in
            currentNeeds.contains {
                $0.caseInsensitiveCompare(card.type) == .orderedSame
            } && !starred.contains(where: { $0.id == card.id })
        }

        let others = availableCards.filter { card in
            card.city.caseInsensitiveCompare(userCity) == .orderedSame
                && !starred.contains(where: { $0.id == card.id })
                && !matched.contains(where: { $0.id == card.id })
        }

        starredCards = starred
        matchedCards = matched
        otherCards = others
        supportCards = availableCards
        acceptedHelpCards = committedCards
        filteredSupportCards = filterFutureAvailabilityCards(availableCards)
    }

    func refreshMatchedCards() {
        applyCardFiltering()
    }

    func setSupportCards(_ cards: [HelpCard]) {
        supportCards = cards
        filteredSupportCards = filterFutureAvailabilityCards(cards)
    }

    func notInCommitted(_ card: HelpCard) -> Bool {
        guard let id = card.id else { return true }
        return !committedCards.contains { $0.id == id }
    }

    func filterFutureAvailabilityCards(_ cards: [HelpCard]) -> [HelpCard] {
        let now = Date()
        return cards.filter {
            $0.availabilityDates.contains(where: { $0 > now })
        }
    }

    var upcomingPostedCards: [HelpCard] {
        helpCards.filter { card in
            guard let nextDate = card.availabilityDates.sorted().first else {
                return false
            }
            return nextDate >= Date()
        }
    }

    // MARK: Create Help Cards

    func addSingleHelpCard(
        title: String,
        type: String,
        name: String,
        contactInfo: String,
        notes: String,
        availabilityDates: [Date],
        city: String
    ) {
        guard let userId = Auth.auth().currentUser?.uid,
              userRole == "helper" || userRole == "in_need" else {
            return
        }

        let postType = userRole == "helper"
            ? "help_offer"
            : "support_request"

        let card = HelpCard(
            id: nil,
            title: title,
            contactInfo: contactInfo,
            name: name,
            availabilityDates: availabilityDates,
            type: type,
            notes: notes,
            city: city,
            starredBy: [],
            ownerId: userId,
            postType: postType,
            isCommitted: false,
            committedBy: nil
        )

        let documentRef = db.collection("users")
            .document(userId)
            .collection("helpCards")
            .document(UUID().uuidString)

        do {
            // @DocumentID should be nil when encoding a new Firestore document.
            try documentRef.setData(from: card)

            var localCard = card
            localCard.id = documentRef.documentID

            helpCards.removeAll { $0.id == localCard.id }
            helpCards.append(localCard)
            allHelpCards.append(localCard)

            applyCardFiltering()

            if userRole == "in_need" {
                dailyPointsVM?.addPoints(25)
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
        for date in availabilityDates where date > Date() {
            addSingleHelpCard(
                title: title,
                type: type,
                name: name,
                contactInfo: contactInfo,
                notes: notes,
                availabilityDates: [date],
                city: city
            )
        }
    }

    // MARK: Delete / Hide Cards

    func deleteHelpCard(_ card: HelpCard) {
        guard let cardId = card.id,
              let userId = Auth.auth().currentUser?.uid,
              userId == card.ownerId else {
            print("Delete failed: unauthorized or missing card ID.")
            return
        }

        db.collection("users")
            .document(userId)
            .collection("helpCards")
            .document(cardId)
            .delete { [weak self] error in
                guard let self else { return }

                DispatchQueue.main.async {
                    if let error {
                        print("Error deleting help card: \(error.localizedDescription)")
                        return
                    }

                    self.helpCards.removeAll { $0.id == cardId }
                    self.supportCards.removeAll { $0.id == cardId }
                    self.acceptedHelpCards.removeAll { $0.id == cardId }
                    self.starredCards.removeAll { $0.id == cardId }
                    self.matchedCards.removeAll { $0.id == cardId }
                    self.otherCards.removeAll { $0.id == cardId }
                    self.allHelpCards.removeAll { $0.id == cardId }
                    self.applyCardFiltering()
                }
            }
    }

    func hideHelpCardForCurrentUser(_ card: HelpCard) {
        guard let uid = Auth.auth().currentUser?.uid,
              let cardId = card.id else {
            print("Hide failed: missing user or card ID.")
            return
        }

        db.collection("users")
            .document(uid)
            .updateData([
                "hiddenHelpCards": FieldValue.arrayUnion([cardId])
            ]) { [weak self] error in
                guard let self else { return }

                DispatchQueue.main.async {
                    if let error {
                        print("Failed to hide card: \(error.localizedDescription)")
                        return
                    }

                    self.currentHiddenIds.append(cardId)
                    self.applyCardFiltering()
                }
            }
    }

    // Expired cards are filtered out; they are not permanently added to a user's hidden list.
    func cleanupExpiredCards() {
        applyCardFiltering()
    }

    // MARK: Accept a Card

    func canAcceptCard(_ card: HelpCard) -> Bool {
        guard let uid = Auth.auth().currentUser?.uid,
              uid != card.ownerId,
              !card.isCommitted,
              card.availabilityDates.contains(where: { $0 > Date() }) else {
            return false
        }

        let postType = card.postType ?? "support_request"

        switch (userRole, postType) {
        case ("in_need", "help_offer"),
             ("helper", "support_request"):
            return true
        default:
            return false
        }
    }

    func acceptHelpCard(_ card: HelpCard) {
        guard let currentUser = Auth.auth().currentUser,
              let cardId = card.id,
              canAcceptCard(card) else {
            print("Accept failed: this card cannot be accepted.")
            return
        }

        let accepterId = currentUser.uid
        let currentRole = userRole

        let cardRef = db.collection("users")
            .document(card.ownerId)
            .collection("helpCards")
            .document(cardId)

        db.runTransaction({ transaction, errorPointer -> Any? in
            do {
                let snapshot = try transaction.getDocument(cardRef)

                guard let data = snapshot.data() else {
                    errorPointer?.pointee = NSError(
                        domain: "CareConnect",
                        code: 404,
                        userInfo: [
                            NSLocalizedDescriptionKey: "This card no longer exists."
                        ]
                    )
                    return nil
                }

                let ownerId = data["ownerId"] as? String ?? ""
                let isCommitted = data["isCommitted"] as? Bool ?? false
                let dates = data["availabilityDates"] as? [Timestamp] ?? []
                let stillAvailable = dates.contains {
                    $0.dateValue() > Date()
                }
                let postType = data["postType"] as? String ?? "support_request"

                let roleCanAccept =
                    (currentRole == "in_need" && postType == "help_offer")
                    || (currentRole == "helper" && postType == "support_request")

                guard ownerId != accepterId,
                      !isCommitted,
                      stillAvailable,
                      roleCanAccept else {
                    errorPointer?.pointee = NSError(
                        domain: "CareConnect",
                        code: 409,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "This card is no longer available to accept."
                        ]
                    )
                    return nil
                }

                transaction.updateData([
                    "isCommitted": true,
                    "committedBy": accepterId,
                    "committedAt": FieldValue.serverTimestamp()
                ], forDocument: cardRef)

                return true
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }
        }) { [weak self] result, error in
            guard let self else { return }

            if let error {
                print("Could not accept card: \(error.localizedDescription)")
                return
            }

            guard result as? Bool == true else { return }

            self.createConversation(for: card, acceptedBy: accepterId)
            self.dailyPointsVM?.addPoints(15)
            self.applyCardFiltering()
        }
    }

    // MARK: Conversations

    private func createConversation(
        for card: HelpCard,
        acceptedBy accepterId: String
    ) {
        guard let cardId = card.id else { return }

        let postType = card.postType ?? "support_request"
        let requesterId = postType == "help_offer" ? accepterId : card.ownerId
        let helperId = postType == "help_offer" ? card.ownerId : accepterId

        guard requesterId != helperId else { return }

        let requesterRef = db.collection("users").document(requesterId)
        let helperRef = db.collection("users").document(helperId)

        let conversationId = "\(card.ownerId)_\(cardId)"
        let conversationRef = db.collection("conversations")
            .document(conversationId)

        let messagesRef = conversationRef.collection("messages")
        let requesterMessageRef = messagesRef.document("admin_requester_contact")
        let helperMessageRef = messagesRef.document("admin_helper_contact")

        let group = DispatchGroup()
        let lock = NSLock()

        var requesterData: [String: Any] = [:]
        var helperData: [String: Any] = [:]
        var fetchFailed = false

        group.enter()
        requesterRef.getDocument { snapshot, error in
            lock.lock()
            defer {
                lock.unlock()
                group.leave()
            }

            if error != nil || snapshot?.data() == nil {
                fetchFailed = true
            } else {
                requesterData = snapshot?.data() ?? [:]
            }
        }

        group.enter()
        helperRef.getDocument { snapshot, error in
            lock.lock()
            defer {
                lock.unlock()
                group.leave()
            }

            if error != nil || snapshot?.data() == nil {
                fetchFailed = true
            } else {
                helperData = snapshot?.data() ?? [:]
            }
        }

        group.notify(queue: .main) {
            lock.lock()
            let requester = requesterData
            let helper = helperData
            let failed = fetchFailed
            lock.unlock()

            guard !failed else {
                print("Conversation not created: a profile could not be loaded.")
                return
            }

            func contactText(_ data: [String: Any]) -> String {
                let name = data["name"] as? String ?? "Not provided"
                let city = data["city"] as? String ?? "Not provided"
                let state = data["state"] as? String ?? "Not provided"
                let phone = data["phone"] as? String ?? "Not provided"
                let email = data["email"] as? String ?? "Not provided"

                return """
                Name: \(name)
                Location: \(city), \(state)
                Phone: \(phone)
                Email: \(email)
                """
            }

            let requesterName =
                requester["name"] as? String ?? "Community Member"
            let helperName =
                helper["name"] as? String ?? "Community Member"

            let requesterMessage: [String: Any] = [
                "senderId": "admin",
                "senderName": "Admin",
                "text": """
                The request was accepted.
                Requester contact information:
                \(contactText(requester))
                """,
                "timestamp": FieldValue.serverTimestamp(),
                "isSystemMessage": true
            ]

            let helperMessage: [String: Any] = [
                "senderId": "admin",
                "senderName": "Admin",
                "text": """
                The request was accepted.
                Helper contact information:
                \(contactText(helper))
                """,
                "timestamp": FieldValue.serverTimestamp(),
                "isSystemMessage": true
            ]

            self.db.runTransaction({ transaction, errorPointer -> Any? in
                do {
                    let conversationSnapshot =
                        try transaction.getDocument(conversationRef)
                    let requesterSnapshot =
                        try transaction.getDocument(requesterMessageRef)
                    let helperSnapshot =
                        try transaction.getDocument(helperMessageRef)

                    if !conversationSnapshot.exists {
                        transaction.setData([
                            "participants": [requesterId, helperId],
                            "participantNames": [
                                requesterId: requesterName,
                                helperId: helperName
                            ],
                            "helpCardTitle": card.title,
                            "postType": postType,
                            "lastMessage":
                                "A private conversation was created after the card was accepted.",
                            "updatedAt": FieldValue.serverTimestamp(),
                            "createdAt": FieldValue.serverTimestamp()
                        ], forDocument: conversationRef)
                    }

                    if !requesterSnapshot.exists {
                        transaction.setData(
                            requesterMessage,
                            forDocument: requesterMessageRef
                        )
                    }

                    if !helperSnapshot.exists {
                        transaction.setData(
                            helperMessage,
                            forDocument: helperMessageRef
                        )
                    }

                    return true
                } catch let error as NSError {
                    errorPointer?.pointee = error
                    return nil
                }
            }) { result, error in
                if let error {
                    print("Failed to create conversation: \(error.localizedDescription)")
                } else if result as? Bool == true {
                    print("Conversation ready: \(conversationId)")
                }
            }
        }
    }

    // MARK: Additional Fetch Helpers

    func fetchUserHelpCards() async -> [HelpCard] {
        guard let uid = Auth.auth().currentUser?.uid else { return [] }

        do {
            let snapshot = try await db.collection("users")
                .document(uid)
                .collection("helpCards")
                .getDocuments()

            let cards = snapshot.documents.compactMap {
                try? $0.data(as: HelpCard.self)
            }

            let futureCards = filterFutureAvailabilityCards(cards)
            helpCards = futureCards
            return futureCards
        } catch {
            print("Error fetching user help cards: \(error.localizedDescription)")
            return []
        }
    }

    func fetchCommittedCards() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        db.collectionGroup("helpCards")
            .whereField("committedBy", isEqualTo: uid)
            .getDocuments { [weak self] snapshot, error in
                guard let self else { return }

                if let error {
                    print("Error fetching committed cards: \(error.localizedDescription)")
                    return
                }

                let cards = snapshot?.documents.compactMap {
                    try? $0.data(as: HelpCard.self)
                } ?? []

                DispatchQueue.main.async {
                    self.committedCards =
                        self.filterFutureAvailabilityCards(cards)
                    self.applyCardFiltering()
                }
            }
    }

    private func fetchCurrentUser(completion: @escaping (User?) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(nil)
            return
        }

        db.collection("users")
            .document(uid)
            .getDocument { snapshot, _ in
                guard let snapshot else {
                    completion(nil)
                    return
                }

                completion(try? snapshot.data(as: User.self))
            }
    }

    private func sendInboxMessage(
        to ownerId: String,
        from user: User,
        card: HelpCard
    ) {
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

        db.collection("users")
            .document(ownerId)
            .collection("inbox")
            .addDocument(data: inboxData)
    }
}

// MARK: - Shared Role Home Screen

private struct RoleHomeView: View {
    @ObservedObject var viewModel: MainViewModel
    let isHelper: Bool

    @State private var showingAddCard = false

    private var myCards: [HelpCard] {
        viewModel.helpCards.filter {
            ($0.postType ?? "support_request") ==
                (isHelper ? "help_offer" : "support_request")
        }
    }

    private var acceptedCards: [HelpCard] {
        viewModel.committedCards.filter {
            ($0.postType ?? "support_request") ==
                (isHelper ? "support_request" : "help_offer")
        }
    }

    private var starredTitle: String {
        isHelper ? "Starred Support Requests" : "Starred Help Offers"
    }

    private var matchedTitle: String {
        isHelper ? "Matched Support Requests" : "Matched Help Offers"
    }

    private var otherTitle: String {
        isHelper ? "Other Available Support Requests" : "Other Available Help Offers"
    }

    private var acceptedTitle: String {
        isHelper ? "Support Requests I've Accepted" : "Help Offers I've Accepted"
    }

    private var emptyMessage: String {
        isHelper
            ? "No support requests are available right now. Check back later."
            : "No help offers are available right now. Check back later."
    }

    private var allSectionsEmpty: Bool {
        myCards.isEmpty
            && acceptedCards.isEmpty
            && viewModel.starredCards.isEmpty
            && viewModel.matchedCards.isEmpty
            && viewModel.otherCards.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    homeIntro

                    CardSectionScrollView(
                        title: isHelper ? "My Help Offers" : "My Support Requests",
                        cards: myCards,
                        viewModel: viewModel
                    )

                    if !acceptedCards.isEmpty {
                        CardSectionScrollView(
                            title: acceptedTitle,
                            cards: acceptedCards,
                            viewModel: viewModel
                        )
                    }

                    if !viewModel.starredCards.isEmpty {
                        CardSectionScrollView(
                            title: starredTitle,
                            cards: viewModel.starredCards,
                            viewModel: viewModel
                        )
                    }

                    if !viewModel.matchedCards.isEmpty {
                        CardSectionScrollView(
                            title: matchedTitle,
                            cards: viewModel.matchedCards,
                            viewModel: viewModel
                        )
                    }

                    if !viewModel.otherCards.isEmpty {
                        CardSectionScrollView(
                            title: otherTitle,
                            cards: viewModel.otherCards,
                            viewModel: viewModel
                        )
                    }

                    if allSectionsEmpty {
                        EmptyStateView(
                            title: "Nothing here yet",
                            message: emptyMessage,
                            systemImage: "hand.raised"
                        )
                        .padding(.top, 12)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isHelper ? "Help Others" : "Help for Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddCard = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(
                        isHelper ? "Create Help Offer" : "Create Support Request"
                    )
                }
            }
            .sheet(isPresented: $showingAddCard) {
                AddHelpCardView(viewModel: viewModel)
            }
        }
    }

    private var homeIntro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isHelper ? "Make a difference" : "Find the support you need")
                .font(.title2.bold())
                .foregroundStyle(.primary)

            Text(
                isHelper
                    ? "Browse requests, find a match, and offer support to your community."
                    : "Browse available help, find a match, and manage your requests."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}

struct SupportView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        RoleHomeView(viewModel: viewModel, isHelper: false)
    }
}

struct HelpView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        RoleHomeView(viewModel: viewModel, isHelper: true)
    }
}

// MARK: - Card Sections

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
                .padding(.horizontal)

            if cards.isEmpty {
                EmptyStateView(
                    title: "No cards yet",
                    message: "Cards in this section will appear here.",
                    systemImage: "tray"
                )
                .padding(.horizontal)
            } else {
                VStack(spacing: 12) {
                    ForEach(cards) { card in
                        HelpCardView(card: card, viewModel: viewModel)
                    }
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyStateView: View {
    var title: String = "Nothing to show"
    let message: String
    var systemImage: String = "tray"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.7))

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct HelpCardSectionView: View {
    let title: String
    let cards: [HelpCard]
    var viewModel: MainViewModel
    var isInNeedUser: Bool

    var body: some View {
        CardSectionScrollView(
            title: title,
            cards: cards,
            viewModel: viewModel
        )
    }
}

// MARK: - Create Help Card

struct AddHelpCardView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var type = "Medical"
    @State private var contactInfo = ""
    @State private var name = ""
    @State private var notes = ""
    @State private var showingDatePicker = false
    @State private var newAvailabilityDate = Date().addingTimeInterval(3600)
    @State private var availabilityDates: [Date] = []

    private let db = Firestore.firestore()
    private let types = [
        "Medical",
        "Groceries",
        "Companionship",
        "Transportation",
        "Other"
    ]

    private var isHelper: Bool {
        viewModel.userRole == "helper"
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !contactInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && availabilityDates.contains(where: { $0 > Date() })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(isHelper ? "Help Offer Details" : "Support Request Details") {
                    TextField(
                        isHelper ? "Help offer title" : "Support request title",
                        text: $title
                    )

                    Picker("Category", selection: $type) {
                        ForEach(types, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }

                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.words)

                    TextField("Contact phone", text: $contactInfo)
                        .keyboardType(.phonePad)

                    TextField("Additional notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Availability") {
                    if availabilityDates.isEmpty {
                        Text("No availability slots added.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(
                            availabilityDates.sorted(),
                            id: \.self
                        ) { date in
                            Label {
                                Text(
                                    date.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                                )
                            } icon: {
                                Image(systemName: "calendar")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .onDelete { offsets in
                            let sortedDates = availabilityDates.sorted()
                            let datesToRemove = offsets.map { sortedDates[$0] }
                            availabilityDates.removeAll {
                                datesToRemove.contains($0)
                            }
                        }
                    }

                    Button {
                        newAvailabilityDate = Date().addingTimeInterval(3600)
                        showingDatePicker = true
                    } label: {
                        Label("Add Availability Slot", systemImage: "plus.circle")
                    }
                }

                Section {
                    Text(
                        "Your availability helps others find a suitable time. Only add dates that are still in the future."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(
                isHelper ? "Create Help Offer" : "Create Support Request"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        viewModel.addHelpCardsForMultipleDates(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            type: type.lowercased(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            contactInfo: contactInfo.trimmingCharacters(in: .whitespacesAndNewlines),
                            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                            availabilityDates: availabilityDates.filter { $0 > Date() },
                            city: viewModel.userCity
                        )
                        dismiss()
                    }
                    .disabled(!canCreate)
                }
            }
            .sheet(isPresented: $showingDatePicker) {
                NavigationStack {
                    VStack(spacing: 20) {
                        DatePicker(
                            "Select Date & Time",
                            selection: $newAvailabilityDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.graphical)
                        .padding(.horizontal)

                        Spacer()
                    }
                    .padding(.top)
                    .navigationTitle("Availability")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showingDatePicker = false
                            }
                        }

                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                if !availabilityDates.contains(newAvailabilityDate) {
                                    availabilityDates.append(newAvailabilityDate)
                                }
                                showingDatePicker = false
                            }
                            .disabled(newAvailabilityDate <= Date())
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .task {
                loadUserInfo()
            }
        }
    }

    private func loadUserInfo() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        db.collection("users")
            .document(userId)
            .getDocument { document, error in
                if let error {
                    print("Error fetching user info: \(error.localizedDescription)")
                    return
                }

                guard let data = document?.data() else { return }

                DispatchQueue.main.async {
                    if name.isEmpty {
                        name = data["name"] as? String ?? ""
                    }

                    if contactInfo.isEmpty {
                        contactInfo = data["phone"] as? String ?? ""
                    }
                }
            }
    }
}

// MARK: - Help Card

struct HelpCardView: View {
    let card: HelpCard
    @ObservedObject var viewModel: MainViewModel

    @State private var isStarred = false
    @State private var showDetail = false
    @State private var isUpdatingStar = false

    private let db = Firestore.firestore()

    private var isOwnCard: Bool {
        card.ownerId == Auth.auth().currentUser?.uid
    }

    private var isHelpOffer: Bool {
        (card.postType ?? "support_request") == "help_offer"
    }

    private var cardKindLabel: String {
        isHelpOffer ? "Help Offer" : "Support Request"
    }

    private var contactIsVisible: Bool {
        isOwnCard || card.committedBy == Auth.auth().currentUser?.uid
    }

    private var nextAvailability: Date? {
        card.availabilityDates
            .filter { $0 > Date() }
            .sorted()
            .first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(card.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        CardTag(
                            text: cardKindLabel,
                            systemImage: isHelpOffer ? "hand.raised.fill" : "heart.fill"
                        )

                        CardTag(
                            text: card.type.capitalized,
                            systemImage: "tag"
                        )
                    }

                    if card.isCommitted {
                        Label("Accepted", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }

                Spacer(minLength: 0)

                if !isOwnCard && !card.isCommitted {
                    Button(action: toggleStar) {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(isStarred ? .yellow : .secondary)
                            .frame(width: 40, height: 40)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isUpdatingStar)
                    .accessibilityLabel(
                        isStarred ? "Remove from starred cards" : "Star this card"
                    )
                }
            }

            Divider()

            Label(card.name, systemImage: "person.crop.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if contactIsVisible {
                Label(card.contactInfo, systemImage: "phone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Label(
                    "Contact details are shared after acceptance",
                    systemImage: "lock"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let nextAvailability {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Next available")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(
                            nextAvailability.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    }
                } icon: {
                    Image(systemName: "calendar")
                        .foregroundStyle(.tint)
                }
            }

            if !card.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(card.notes)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isOwnCard {
                Button(role: .destructive) {
                    viewModel.deleteHelpCard(card)
                } label: {
                    Label("Delete My Card", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else if !card.isCommitted {
                Button {
                    viewModel.hideHelpCardForCurrentUser(card)
                } label: {
                    Label("Hide From My View", systemImage: "eye.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }

            Button {
                showDetail = true
            } label: {
                Label(
                    card.isCommitted ? "View Card Status" : "View Details",
                    systemImage: "arrow.up.right.square"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .padding(.horizontal)
        .sheet(isPresented: $showDetail) {
            HelpCardDetailView(card: card, viewModel: viewModel) {
                viewModel.acceptHelpCard(card)
            }
        }
        .onAppear {
            isStarred = card.starredBy?.contains(
                Auth.auth().currentUser?.uid ?? ""
            ) ?? false
        }
        .onChange(of: card.starredBy) { _, newValue in
            isStarred = newValue?.contains(
                Auth.auth().currentUser?.uid ?? ""
            ) ?? false
        }
    }

    private func toggleStar() {
        guard let uid = Auth.auth().currentUser?.uid,
              let cardId = card.id,
              !isOwnCard,
              !card.isCommitted,
              !isUpdatingStar else {
            return
        }

        isUpdatingStar = true

        let cardRef = db.collection("users")
            .document(card.ownerId)
            .collection("helpCards")
            .document(cardId)

        let update: [String: Any] = isStarred
            ? ["starredBy": FieldValue.arrayRemove([uid])]
            : ["starredBy": FieldValue.arrayUnion([uid])]

        cardRef.updateData(update) { error in
            DispatchQueue.main.async {
                isUpdatingStar = false

                if let error {
                    print("Error updating star: \(error.localizedDescription)")
                } else {
                    isStarred.toggle()
                }
            }
        }
    }
}

private struct CardTag: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.10))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }
}

// MARK: - Help Card Details

struct HelpCardDetailView: View {
    let card: HelpCard
    @ObservedObject var viewModel: MainViewModel
    var onVerifiedAndCommitted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showVerification = false
    @State private var showCommitment = false

    private var isHelpOffer: Bool {
        (card.postType ?? "support_request") == "help_offer"
    }

    private var isOwnCard: Bool {
        card.ownerId == Auth.auth().currentUser?.uid
    }

    private var acceptedByCurrentUser: Bool {
        card.committedBy == Auth.auth().currentUser?.uid
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        CardTag(
                            text: isHelpOffer ? "Help Offer" : "Support Request",
                            systemImage: isHelpOffer ? "hand.raised.fill" : "heart.fill"
                        )

                        Text(card.title)
                            .font(.largeTitle.bold())
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Posted by \(card.name)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    detailRow(
                        label: "Category",
                        value: card.type.capitalized,
                        systemImage: "tag"
                    )

                    detailRow(
                        label: "Location",
                        value: card.city.isEmpty ? "Not specified" : card.city,
                        systemImage: "location"
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Availability", systemImage: "calendar")
                            .font(.headline)

                        if card.availabilityDates.isEmpty {
                            Text("No availability listed.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(card.availabilityDates.sorted(), id: \.self) { date in
                                Text(
                                    date.formatted(
                                        date: .complete,
                                        time: .shortened
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !card.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Additional Notes", systemImage: "text.alignleft")
                                .font(.headline)

                            Text(card.notes)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if card.isCommitted {
                        Label(
                            "This card has already been accepted.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)

                        if acceptedByCurrentUser || isOwnCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Contact Information")
                                    .font(.headline)

                                Text(card.contactInfo)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    } else if viewModel.canAcceptCard(card) {
                        Button {
                            showVerification = true
                        } label: {
                            Text(
                                isHelpOffer
                                    ? "Accept Help Offer"
                                    : "Accept Support Request"
                            )
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else if isOwnCard {
                        Label(
                            "This is your card. You cannot accept your own post.",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "This card is not available for your account.",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if !card.isCommitted && !isOwnCard {
                        Text("Contact information should only be shared after acceptance.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isHelpOffer ? "Help Offer" : "Support Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showVerification) {
                VerificationView(card: card) {
                    showVerification = false

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showCommitment = true
                    }
                }
            }
            .sheet(isPresented: $showCommitment) {
                CommitmentView(card: card) {
                    onVerifiedAndCommitted()
                    dismiss()
                }
            }
        }
    }

    private func detailRow(
        label: String,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.body)
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Confirmation Code

struct VerificationView: View {
    let card: HelpCard
    var onVerified: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code: String
    @State private var input = ""
    @State private var error: String?

    init(card: HelpCard, onVerified: @escaping () -> Void) {
        self.card = card
        self.onVerified = onVerified

        let characters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let generatedCode = String(
            (0..<6).compactMap { _ in characters.randomElement() }
        )

        _code = State(initialValue: generatedCode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .padding(.top, 20)

                VStack(spacing: 8) {
                    Text("Confirmation Code")
                        .font(.title2.bold())

                    Text("Re-enter the code below to continue.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text(code)
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)

                TextField("Enter confirmation code", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    if input.trimmingCharacters(in: .whitespacesAndNewlines)
                        .uppercased() == code {
                        dismiss()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onVerified()
                        }
                    } else {
                        error = "The code does not match. Please try again."
                    }
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Confirm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Commitment Confirmation

struct CommitmentView: View {
    let card: HelpCard
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "hand.thumbsup")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .padding(.top, 20)

                VStack(spacing: 10) {
                    Text("Confirm Acceptance")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    Text("Are you sure you want to accept this card?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("“\(card.title)”")
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text("Posted by \(card.name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    Button {
                        onCommit()
                        dismiss()
                    } label: {
                        Text("Yes, Accept")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }

                Spacer()
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Inbox

struct InboxView: View {
    @StateObject private var viewModel = InboxViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView("Loading inbox...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.messages.isEmpty {
                    EmptyStateView(
                        title: "Your inbox is empty",
                        message: "Messages and contact details shared with you will appear here.",
                        systemImage: "tray"
                    )
                    .padding()
                } else {
                    List(viewModel.messages) { message in
                        InboxMessageRow(message: message)
                            .listRowBackground(
                                Color(.secondarySystemGroupedBackground)
                            )
                            .padding(.vertical, 5)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Inbox")
            .onAppear {
                viewModel.startListening()
            }
            .onDisappear {
                viewModel.stopListening()
            }
        }
    }
}

private struct InboxMessageRow: View {
    let message: InboxMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(message.fromName)
                        .font(.headline)

                    Text("Regarding: \(message.helpCardTitle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            if !message.fromEmail.isEmpty {
                Label(message.fromEmail, systemImage: "envelope")
                    .font(.subheadline)
                    .textSelection(.enabled)
            }

            if !message.fromPhone.isEmpty {
                Label(message.fromPhone, systemImage: "phone")
                    .font(.subheadline)
                    .textSelection(.enabled)
            }

            if !message.helpCardType.isEmpty {
                Text("Category: \(message.helpCardType.capitalized)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !message.helpCardNotes.isEmpty {
                Text(message.helpCardNotes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let timestamp = message.timestamp {
                Text(timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }
}

@MainActor
final class InboxViewModel: ObservableObject {
    @Published var messages: [InboxMessage] = []
    @Published private(set) var isLoading = true

    private let db = Firestore.firestore()
    private var inboxListener: ListenerRegistration?
    private var listeningUserID: String?

    func startListening() {
        guard let userId = Auth.auth().currentUser?.uid else {
            messages = []
            isLoading = false
            return
        }

        guard inboxListener == nil || listeningUserID != userId else {
            return
        }

        stopListening()
        isLoading = true
        listeningUserID = userId

        inboxListener = db.collection("users")
            .document(userId)
            .collection("inbox")
            .order(by: "timestamp", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error {
                    print("Error listening to inbox: \(error.localizedDescription)")

                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                    return
                }

                let updatedMessages = snapshot?.documents.compactMap {
                    try? $0.data(as: InboxMessage.self)
                } ?? []

                DispatchQueue.main.async {
                    self.messages = updatedMessages
                    self.isLoading = false
                }
            }
    }

    func stopListening() {
        inboxListener?.remove()
        inboxListener = nil
        listeningUserID = nil
    }

    deinit {
        inboxListener?.remove()
    }
}
