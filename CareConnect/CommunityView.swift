import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct CommunityConversation: Identifiable {
    let id: String
    let participants: [String]
    let participantNames: [String: String]
    let helpCardTitle: String
    let lastMessage: String
    let updatedAt: Date?
}

struct CommunityChatMessage: Identifiable {
    let id: String
    let senderId: String
    let senderName: String
    let text: String
    let timestamp: Date?
    let isSystemMessage: Bool
}

@MainActor
final class CommunityViewModel: ObservableObject {
    @Published var conversations: [CommunityConversation] = []
    @Published var errorMessage: String?

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorMessage = "Please sign in to view your conversations."
            return
        }

        listener?.remove()

        listener = db.collection("conversations")
            .whereField("participants", arrayContains: uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error {
                    Task { @MainActor in
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }

                let results = snapshot?.documents.compactMap { doc -> CommunityConversation? in
                    let data = doc.data()

                    return CommunityConversation(
                        id: doc.documentID,
                        participants: data["participants"] as? [String] ?? [],
                        participantNames: data["participantNames"] as? [String: String] ?? [:],
                        helpCardTitle: data["helpCardTitle"] as? String ?? "Help request",
                        lastMessage: data["lastMessage"] as? String ?? "",
                        updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue()
                    )
                } ?? []

                Task { @MainActor in
                    self.conversations = results.sorted {
                        ($0.updatedAt ?? .distantPast) >
                        ($1.updatedAt ?? .distantPast)
                    }
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    deinit {
        listener?.remove()
    }
}

struct CommunityView: View {
    @StateObject private var viewModel = CommunityViewModel()

    var body: some View {
        NavigationView {
            Group {
                if let error = viewModel.errorMessage {
                    ContentUnavailableView(
                        "Unable to Load Community",
                        systemImage: "exclamationmark.bubble",
                        description: Text(error)
                    )
                } else if viewModel.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(
                            "When you accept or receive an accepted help request, your private conversation will appear here."
                        )
                    )
                } else {
                    List(viewModel.conversations) { conversation in
                        NavigationLink {
                            CommunityChatView(conversation: conversation)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(otherParticipantName(conversation))
                                    .font(.headline)

                                Text(conversation.helpCardTitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text(conversation.lastMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)

                                if let date = conversation.updatedAt {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Community")
            .onAppear {
                viewModel.startListening()
            }
            .onDisappear {
                viewModel.stopListening()
            }
        }
    }

    private func otherParticipantName(_ conversation: CommunityConversation) -> String {
        guard let uid = Auth.auth().currentUser?.uid else {
            return "Conversation"
        }

        let otherId = conversation.participants.first { $0 != uid }
        return otherId.flatMap { conversation.participantNames[$0] } ?? "Community Member"
    }
}

@MainActor
final class CommunityChatViewModel: ObservableObject {
    @Published var messages: [CommunityChatMessage] = []
    @Published var draft = ""
    @Published var errorMessage: String?
    @Published var isSending = false

    private let db = Firestore.firestore()
    private let conversationId: String
    private var listener: ListenerRegistration?

    init(conversationId: String) {
        self.conversationId = conversationId
    }

    func startListening() {
        listener?.remove()

        listener = db.collection("conversations")
            .document(conversationId)
            .collection("messages")
            .order(by: "timestamp", descending: false)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }

                if let error {
                    Task { @MainActor in
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }

                let results = snapshot?.documents.compactMap { doc -> CommunityChatMessage? in
                    let data = doc.data()

                    return CommunityChatMessage(
                        id: doc.documentID,
                        senderId: data["senderId"] as? String ?? "",
                        senderName: data["senderName"] as? String ?? "Community Member",
                        text: data["text"] as? String ?? "",
                        timestamp: (data["timestamp"] as? Timestamp)?.dateValue(),
                        isSystemMessage: data["isSystemMessage"] as? Bool ?? false
                    )
                } ?? []

                Task { @MainActor in
                    self.messages = results
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    func sendMessage() {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorMessage = "Please sign in to send a message."
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        isSending = true
        errorMessage = nil

        let conversationRef = db.collection("conversations").document(conversationId)
        let messageRef = conversationRef.collection("messages").document()

        conversationRef.getDocument { [weak self] snapshot, error in
            guard let self else { return }

            if let error {
                Task { @MainActor in
                    self.isSending = false
                    self.errorMessage = error.localizedDescription
                }
                return
            }

            guard let data = snapshot?.data(),
                  let participants = data["participants"] as? [String],
                  participants.contains(uid) else {
                Task { @MainActor in
                    self.isSending = false
                    self.errorMessage = "You are not a participant in this conversation."
                }
                return
            }

            let userRef = self.db.collection("users").document(uid)

            userRef.getDocument { userSnapshot, userError in
                if let userError {
                    Task { @MainActor in
                        self.isSending = false
                        self.errorMessage = userError.localizedDescription
                    }
                    return
                }

                let userData = userSnapshot?.data() ?? [:]
                let name = userData["name"] as? String ?? "Community Member"

                let batch = self.db.batch()

                batch.setData([
                    "senderId": uid,
                    "senderName": name,
                    "text": text,
                    "timestamp": FieldValue.serverTimestamp(),
                    "isSystemMessage": false
                ], forDocument: messageRef)

                batch.updateData([
                    "lastMessage": text,
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: conversationRef)

                batch.commit { batchError in
                    Task { @MainActor in
                        self.isSending = false

                        if let batchError {
                            self.errorMessage = batchError.localizedDescription
                        } else {
                            self.draft = ""
                        }
                    }
                }
            }
        }
    }

    deinit {
        listener?.remove()
    }
}

struct CommunityChatView: View {
    let conversation: CommunityConversation

    @StateObject private var viewModel: CommunityChatViewModel

    init(conversation: CommunityConversation) {
        self.conversation = conversation
        _viewModel = StateObject(
            wrappedValue: CommunityChatViewModel(conversationId: conversation.id)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _ in
                    guard let lastId = viewModel.messages.last?.id else { return }
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Write a message...", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button {
                    viewModel.sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(
                    viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    viewModel.isSending
                )
                .accessibilityLabel("Send message")
            }
            .padding()
        }
        .navigationTitle(otherParticipantName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.startListening()
        }
        .onDisappear {
            viewModel.stopListening()
        }
    }

    private var otherParticipantName: String {
        guard let uid = Auth.auth().currentUser?.uid else {
            return "Private Chat"
        }

        let otherId = conversation.participants.first { $0 != uid }
        return otherId.flatMap { conversation.participantNames[$0] } ?? "Private Chat"
    }

    @ViewBuilder
    private func messageBubble(_ message: CommunityChatMessage) -> some View {
        if message.isSystemMessage {
            VStack(spacing: 4) {
                Text(message.senderName)
                    .font(.caption)
                    .fontWeight(.semibold)

                Text(message.text)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            let isMine = message.senderId == Auth.auth().currentUser?.uid

            HStack {
                if isMine { Spacer(minLength: 45) }

                VStack(alignment: .leading, spacing: 4) {
                    if !isMine {
                        Text(message.senderName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(message.text)
                        .font(.body)
                        .textSelection(.enabled)

                    if let date = message.timestamp {
                        Text(date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(isMine ? .white.opacity(0.8) : .secondary)
                    }
                }
                .padding(12)
                .foregroundStyle(isMine ? .white : .primary)
                .background(isMine ? Color.accentColor : Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                if !isMine { Spacer(minLength: 45) }
            }
        }
    }
}
