import SwiftUI
import Foundation
import Firebase
import FirebaseAuth
import FirebaseFirestore

struct CommunityMessage: Identifiable, Codable {
    @DocumentID var id: String?
    var userId: String
    var name: String
    var role: String
    var message: String
    var timestamp: Date
}

class CommunityViewModel: ObservableObject {
    @Published var messages: [CommunityMessage] = []
    @Published var newMessage: String = ""
    @Published var name: String = "Anonymous"
    @Published var role: String = ""
    @Published var isAnonymous: Bool = false

    private var db = Firestore.firestore()
    private var listenerRegistration: ListenerRegistration?

    var dailyPointsVM: DailyPointsViewModel

    init(dailyPointsVM: DailyPointsViewModel) {
        self.dailyPointsVM = dailyPointsVM
        fetchMessages()
        fetchCurrentUserInfo()
    }

    deinit {
        listenerRegistration?.remove()
    }

    func fetchCurrentUserInfo() {
        guard let user = Auth.auth().currentUser else { return }
        let uid = user.uid
        db.collection("users").document(uid).getDocument { [weak self] snapshot, error in
            guard let self = self else { return }
            if let data = snapshot?.data() {
                self.name = data["name"] as? String ?? user.displayName ?? "User"
                var rawRole = (data["role"] as? String ?? "Member")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                switch rawRole {
                case "in_need": rawRole = "Seeking Support"
                case "helper": rawRole = "Helper"
                default: break
                }

                self.role = rawRole.capitalized
            }
        }
    }

    func fetchMessages() {
        listenerRegistration = db.collection("community_messages")
            .order(by: "timestamp", descending: false)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self else { return }
                guard let documents = snapshot?.documents else { return }
                self.messages = documents.compactMap { doc in
                    try? doc.data(as: CommunityMessage.self)
                }
            }
    }

    func sendMessage() {
        guard let user = Auth.auth().currentUser else { return }
        let trimmed = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let finalName = isAnonymous ? "Anonymous" : name
        let finalRole = isAnonymous ? "Anonymous" : role

        let message = CommunityMessage(
            userId: user.uid,
            name: finalName,
            role: finalRole,
            message: trimmed,
            timestamp: Date()
        )

        do {
            _ = try db.collection("community_messages").addDocument(from: message)
            newMessage = ""
            dailyPointsVM.addPoints(1)
        } catch {
            print("Error sending message: \(error)")
        }
    }

    func deleteMessage(_ message: CommunityMessage) {
        guard message.userId == Auth.auth().currentUser?.uid, let id = message.id else { return }
        db.collection("community_messages").document(id).delete()
    }
}

struct CommunityView: View {
    @EnvironmentObject var dailyPointsVM: DailyPointsViewModel
    @StateObject private var viewModel: CommunityViewModel

    init() {
        _viewModel = StateObject(wrappedValue: CommunityViewModel(dailyPointsVM: DailyPointsViewModel()))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                headerSection
                chatScrollView
                Divider()
                inputSection
                    .padding(.bottom, 30)
                    .background(Color(UIColor.systemBackground))
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .background(Color(UIColor.systemBackground))
            .onAppear {
                viewModel.dailyPointsVM = dailyPointsVM
            }
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                WordSpeakableText(text: "Community Chat")
                    .font(.system(size: 22, weight: .bold))
                Text("Logged in as: \(viewModel.isAnonymous ? "Anonymous" : viewModel.name) - \(viewModel.role)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: {
                viewModel.isAnonymous.toggle()
            }) {
                Image(systemName: viewModel.isAnonymous ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
            }
            .padding(.trailing)
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .bottom)
    }

    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { msg in
                        MessageBubble(
                            message: msg,
                            currentUserId: Auth.auth().currentUser?.uid ?? "",
                            onDelete: {
                                viewModel.deleteMessage(msg)
                            }
                        )
                        .id(msg.id ?? UUID().uuidString)
                    }
                }
                .padding(.vertical)
                .padding(.horizontal, 10)
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let last = viewModel.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var inputSection: some View {
        HStack(spacing: 10) {
            TextField("Type a message...", text: $viewModel.newMessage)
                .font(.system(size: 17))
                .padding(12)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(10)

            Button(action: {
                viewModel.sendMessage()
            }) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(viewModel.newMessage.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.accentColor)
                    .clipShape(Circle())
            }
            .disabled(viewModel.newMessage.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

struct MessageBubble: View {
    let message: CommunityMessage
    let currentUserId: String
    var onDelete: () -> Void

    var isCurrentUser: Bool {
        message.userId == currentUserId
    }

    var timeAgo: String {
        let interval = Date().timeIntervalSince(message.timestamp)
        let minute = 60.0, hour = 3600.0, day = 86400.0, month = 2592000.0, year = 31536000.0

        switch interval {
        case 0..<minute: return "Just now"
        case minute..<hour: return "\(Int(interval / minute)) min ago"
        case hour..<day: return "\(Int(interval / hour)) hr ago"
        case day..<month: return "\(Int(interval / day)) days ago"
        case month..<year: return "\(Int(interval / month)) mo ago"
        default: return "\(Int(interval / year)) yr ago"
        }
    }

    var body: some View {
        HStack {
            if isCurrentUser { Spacer(minLength: 20) }

            VStack(alignment: isCurrentUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 4) {
                    WordSpeakableText(text: message.name).font(.system(size: 12, weight: .semibold))
                    WordSpeakableText(text: "- \(message.role.capitalized)")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                WordSpeakableText(text: message.message)
                    .font(.system(size: 17))
                    .padding(12)
                    .background(isCurrentUser ? Color.accentColor : Color(UIColor.systemGray5))
                    .foregroundColor(isCurrentUser ? .white : .primary)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.15), radius: 3, x: 1, y: 2)

                HStack(spacing: 12) {
                    WordSpeakableText(text: timeAgo)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                    if isCurrentUser {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                                .padding(4)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: isCurrentUser ? .trailing : .leading)
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: isCurrentUser ? .trailing : .leading)

            if !isCurrentUser { Spacer(minLength: 20) }
        }
        .padding(.horizontal, 10)
    }
}
