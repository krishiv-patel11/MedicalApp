import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import Combine
import AVFoundation
import NaturalLanguage

class AccessibilitySettings: ObservableObject {
    @Published var boldText: Bool = false
    @Published var textToSpeechEnabled: Bool = false
    @Published var speechRate: Double = 0.5
    @Published var reduceMotion: Bool = false
}

class SpeechHelper: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechHelper()
    @Published var currentWordIndex: Int? = nil
    @Published var activeTextID: UUID? = nil

    private var wordRanges: [Range<String.Index>] = []
    private var originalText: String = ""
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, textID: UUID, rate: Float) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        originalText = text
        activeTextID = textID
        currentWordIndex = nil

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        wordRanges = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            wordRanges.append(range)
            return true
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.speech.synthesis.voice.siri.en-GB") ??
            AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = rate
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard let swiftRange = Range(characterRange, in: originalText) else { return }
        if let index = wordRanges.firstIndex(where: { $0.overlaps(swiftRange) }) {
            DispatchQueue.main.async {
                self.currentWordIndex = index
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.currentWordIndex = nil
            self.activeTextID = nil
        }
    }
}

struct WordSpeakableText: View {
    let text: String
    @State private var textID = UUID()
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings
    @ObservedObject private var speechHelper = SpeechHelper.shared
    @State private var attributedString = AttributedString("")
    @State private var wordRanges: [Range<String.Index>] = []

    var body: some View {
        Text(attributedString)
            .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
            .onAppear(perform: prepareAttributedString)
            .onChange(of: speechHelper.currentWordIndex) { _ in
                if speechHelper.activeTextID == textID {
                    highlightCurrentWord()
                } else {
                    clearHighlight()
                }
            }
            .onTapGesture {
                if accessibilitySettings.textToSpeechEnabled {
                    speechHelper.speak(text, textID: textID, rate: Float(accessibilitySettings.speechRate))
                }
            }
    }

    private func clearHighlight() {
        attributedString = AttributedString(text)
        attributedString.backgroundColor = .clear
    }

    private func prepareAttributedString() {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        wordRanges = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            wordRanges.append(range)
            return true
        }

        attributedString = AttributedString(text)
        attributedString.backgroundColor = .clear
    }

    private func highlightCurrentWord() {
        guard let currentIndex = speechHelper.currentWordIndex,
              currentIndex < wordRanges.count else {
            clearHighlight()
            return
        }

        attributedString = AttributedString(text)
        attributedString.backgroundColor = .clear

        let wordRange = wordRanges[currentIndex]
        if let start = AttributedString.Index(wordRange.lowerBound, within: attributedString),
           let end = AttributedString.Index(wordRange.upperBound, within: attributedString) {
            let range = start..<end
            attributedString[range].backgroundColor = .yellow.opacity(0.5)
        }
    }
}

struct SpeakableLabel: View {
    let title: String
    let systemImage: String
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
            WordSpeakableText(text: title)
                .font(.system(size: 17))
        }
        .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
    }
}

struct SpeakableToggle: View {
    let label: String
    @Binding var isOn: Bool
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    var body: some View {
        Toggle(isOn: $isOn) {
            WordSpeakableText(text: label)
                .font(.system(size: 17))
        }
        .font(.system(size: 17))
        .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
    }
}

struct SpeakableButton: View {
    let title: String
    let action: () -> Void
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    var body: some View {
        Button(action: {
            if accessibilitySettings.textToSpeechEnabled {
                SpeechHelper.shared.speak(title, textID: UUID(), rate: Float(accessibilitySettings.speechRate))
            }
            action()
        }) {
            Text(title)
                .font(.system(size: 17))
                .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(8)
        }
    }
}

struct LabeledText: View {
    let label: String
    let value: String
    let fontSize: CGFloat
    let bold: Bool
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    var body: some View {
        HStack {
            WordSpeakableText(text: label)
                .fontWeight(bold ? .bold : .regular)
                .font(.system(size: fontSize))
            Spacer()
            WordSpeakableText(text: value)
                .foregroundColor(.gray)
                .fontWeight(bold ? .bold : .regular)
                .font(.system(size: fontSize))
        }
    }
}

struct MultiSelectPicker: View {
    let title: String
    let options: [String]
    @Binding var selections: [String]
    let fontSize: CGFloat
    let bold: Bool
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    var body: some View {
        VStack(alignment: .leading) {
            WordSpeakableText(text: title)
                .fontWeight(bold ? .bold : .regular)
                .font(.system(size: fontSize))
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { selections.contains(option) },
                    set: { isSelected in
                        if isSelected {
                            selections.append(option)
                        } else {
                            selections.removeAll { $0 == option }
                        }
                    }
                ))
                .font(.system(size: fontSize))
                .fontWeight(bold ? .bold : .regular)
            }
        }
        .padding(.vertical, 5)
    }
}

struct SettingsView: View {
    @State private var navigateToLogin = false
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings
    @EnvironmentObject var authViewModel: AuthViewModel

    var body: some View {
        NavigationView {
            List {
                Section(header:
                    WordSpeakableText(text: "User")
                        .font(.system(size: 17))
                        .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
                ) {
                    NavigationLink(destination: AccountSettingsView()) {
                        SpeakableLabel(title: "Account", systemImage: "person.circle")
                    }
                }

                Section(header:
                    WordSpeakableText(text: "App Settings")
                        .font(.system(size: 17))
                        .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
                ) {
                    NavigationLink(destination: AccessibilitySettingsView()) {
                        SpeakableLabel(title: "Accessibility", systemImage: "textformat.size")
                    }
                    NavigationLink(destination: TermsAndConditionsView()) {
                        SpeakableLabel(title: "Terms & Conditions", systemImage: "doc.text")
                    }
                    NavigationLink(destination: AppInfoView()) {
                        SpeakableLabel(title: "App Info", systemImage: "info.circle")
                    }
                    NavigationLink(destination: HelplinesView()) {
                        SpeakableLabel(title: "Helplines", systemImage: "phone.arrow.up.right")
                    }
                }

                Section {
                    Button(action: {
                        authViewModel.signOut()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.backward.square")
                                .foregroundColor(.red)
                                .font(.system(size: 17))
                            Text("Log Out")
                                .foregroundColor(.red)
                                .font(.system(size: 17))
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .font(.system(size: 17))
            .navigationTitle("Settings")
        }
    }
}

struct AppInfoView: View {
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    var body: some View {
        Form {
            Section(header:
                WordSpeakableText(text: "About")
                    .font(.system(size: 17))
                    .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
            ) {
                WordSpeakableText(text: "CareConnect v1.0.0")
                    .font(.system(size: 17))
                WordSpeakableText(text: "Developed for community care assistance.")
                    .font(.system(size: 17))
            }

            Section(header:
                WordSpeakableText(text: "Contact")
                    .font(.system(size: 17))
                    .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
            ) {
                WordSpeakableText(text: "support@careconnect.app")
                    .font(.system(size: 17))
                WordSpeakableText(text: "2025 CareConnect")
                    .font(.system(size: 17))
            }
        }
        .navigationTitle("App Info")
    }
}

struct AccountSettingsView: View {
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var city = ""
    @State private var state = ""
    @State private var notes = ""
    @State private var role = ""
    @State private var daysNeeded: [String] = []
    @State private var needs: [String] = []
    @State private var isEditing = false
    @State private var errorMessage: String?

    private let daysOptions = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private let needsOptions = ["Medical", "Groceries", "Transportation", "Companionship", "Other"]

    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    var body: some View {
        Form {
            if let error = errorMessage {
                WordSpeakableText(text: error)
                    .foregroundColor(.red)
                    .font(.system(size: 17))
                    .padding(.vertical, 4)
            }

            Section(header: WordSpeakableText(text: "User Information")
                .font(.system(size: 20))
                .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
            ) {
                if isEditing {
                    Group {
                        TextField("Name", text: $name)
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                        TextField("Phone", text: $phone)
                            .keyboardType(.phonePad)
                        TextField("City", text: $city)
                        TextField("State", text: $state)
                    }
                    .font(.system(size: 17))
                } else {
                    LabeledText(label: "Name", value: name, fontSize: 17, bold: accessibilitySettings.boldText)
                    LabeledText(label: "Email", value: email, fontSize: 17, bold: accessibilitySettings.boldText)
                    LabeledText(label: "Phone", value: phone, fontSize: 17, bold: accessibilitySettings.boldText)
                    LabeledText(label: "City", value: city, fontSize: 17, bold: accessibilitySettings.boldText)
                    LabeledText(label: "State", value: state, fontSize: 17, bold: accessibilitySettings.boldText)
                }
            }

            Section(header: WordSpeakableText(text: "Needs & Availability")
                .font(.system(size: 20))
                .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
            ) {
                if isEditing {
                    MultiSelectPicker(title: "Days Needed", options: daysOptions, selections: $daysNeeded, fontSize: 17, bold: accessibilitySettings.boldText)

                    MultiSelectPicker(title: "Needs", options: needsOptions, selections: $needs, fontSize: 17, bold: accessibilitySettings.boldText)

                    TextField("Notes", text: $notes)
                        .font(.system(size: 17))
                } else {
                    LabeledText(label: "Days Needed", value: daysNeeded.joined(separator: ", "), fontSize: 17, bold: accessibilitySettings.boldText)
                    LabeledText(label: "Needs", value: needs.joined(separator: ", "), fontSize: 17, bold: accessibilitySettings.boldText)
                    LabeledText(label: "Notes", value: notes, fontSize: 17, bold: accessibilitySettings.boldText)
                }
            }

            Section(header: WordSpeakableText(text: "Role")
                .font(.system(size: 20))
                .fontWeight(accessibilitySettings.boldText ? .bold : .regular)
            ) {
                WordSpeakableText(text: role == "in_need" ? "Needs Help" : "Helper")
                    .font(.system(size: 17))
                    .foregroundColor(.gray)
            }

            Section {
                Button(action: {
                    if isEditing {
                        updateUserData()
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    withAnimation {
                        isEditing.toggle()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle.fill")
                            .foregroundColor(.blue)
                        Text(isEditing ? "Save" : "Edit")
                            .foregroundColor(.blue)
                            .fontWeight(.semibold)
                            .font(.system(size: 17))
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.clear)
                }
            }
        }
        .navigationTitle("Account")
        .onAppear(perform: fetchUserData)
    }

    private func fetchUserData() {
        guard let uid = Auth.auth().currentUser?.uid else {
            self.errorMessage = "User not logged in."
            return
        }
        Firestore.firestore().collection("users").document(uid).getDocument { snapshot, error in
            if let error = error {
                self.errorMessage = "Failed to load user: \(error.localizedDescription)"
                return
            }

            guard let data = snapshot?.data() else {
                self.errorMessage = "User data not found."
                return
            }

            self.name = data["name"] as? String ?? ""
            self.email = data["email"] as? String ?? ""
            self.phone = data["phone"] as? String ?? ""
            self.city = data["city"] as? String ?? ""
            self.state = data["state"] as? String ?? ""
            self.notes = data["notes"] as? String ?? ""
            self.role = data["role"] as? String ?? ""
            self.daysNeeded = data["daysNeeded"] as? [String] ?? []
            self.needs = data["needs"] as? [String] ?? []
        }
    }

    private func updateUserData() {
        guard let uid = Auth.auth().currentUser?.uid else {
            self.errorMessage = "User not logged in."
            return
        }
        let updatedData: [String: Any] = [
            "name": name,
            "email": email,
            "phone": phone,
            "city": city,
            "state": state,
            "notes": notes,
            "daysNeeded": daysNeeded,
            "needs": needs
        ]
        Firestore.firestore().collection("users").document(uid).setData(updatedData, merge: true) { error in
            if let error = error {
                self.errorMessage = "Update failed: \(error.localizedDescription)"
            } else {
                self.errorMessage = nil
            }
        }
    }
}

struct AccessibilitySettingsView: View {
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    var body: some View {
        Form {
            Section(header: WordSpeakableText(text: "Text Style")) {
                SpeakableToggle(label: "Bold Text", isOn: $accessibilitySettings.boldText)
                SpeakableToggle(label: "Text To Speech", isOn: $accessibilitySettings.textToSpeechEnabled)
                SpeakableToggle(label: "Reduce Motion", isOn: $accessibilitySettings.reduceMotion)
                HStack {
                    WordSpeakableText(text: "Speech Rate")
                        .font(.system(size: 17))
                    Slider(value: $accessibilitySettings.speechRate, in: 0.4...1.0, step: 0.1)
                }
            }
        }
        .navigationTitle("Accessibility")
    }
}

struct TermsAndConditionsView: View {
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings

    var body: some View {
        ScrollView {
            WordSpeakableText(text: """
1. Acceptance of Terms
By accessing or using the CareConnect app, you agree to be bound by these Terms and Conditions. If you do not agree, please do not use the app.

2. Use of the App
CareConnect is intended for informational and support purposes only.

You must use the app in compliance with all applicable laws and regulations.

You agree not to misuse or disrupt the service (e.g., hacking, spreading false information, etc.).

3. User Accounts
Reatures require you to create an account.

You are responsible for keeping your login information secure.

You agree to provide accurate and up-to-date information.

4. Content and Services
We aim to provide reliable resources and connections to helpful services.

We do not guarantee the accuracy or availability of any external services listed in the app.

We are not responsible for third-party content or services accessed through CareConnect.

5. Intellectual Property
All content in CareConnect (text, logos, design) is the property of CareConnect or its partners.

You may not copy, distribute, or reuse content without permission.

6. Disclaimer of Warranties
The app is provided “as is” without warranties of any kind.

We do not guarantee that the app will always be available, error-free, or secure.

7. Limitation of Liability
CareConnect is not liable for any damages arising from your use of the app.

This includes but is not limited to: loss of data, loss of access, or issues with third-party services.

8. Changes to the Terms
We may update these Terms from time to time. If we do, we will notify you through the app or by other means.
""")
            .font(.system(size: 17))
            .padding()
        }
        .navigationTitle("Terms & Conditions")
    }
}

struct Helpline: Identifiable {
    let id = UUID()
    let name: String
    let number: String
}

struct HelplinesView: View {
    let helplines: [Helpline] = [
        Helpline(name: "National Suicide Prevention Lifeline", number: "988"),
        Helpline(name: "SAMHSA Helpline (Substance Abuse)", number: "1-800-662-4357"),
        Helpline(name: "Domestic Violence Hotline", number: "1-800-799-7233"),
        Helpline(name: "National Child Abuse Hotline", number: "1-800-422-4453"),
        Helpline(name: "Emergency Services", number: "911")
    ]
    
    var body: some View {
        NavigationView {
            List(helplines) { helpline in
                HStack {
                    VStack(alignment: .leading) {
                        Text(helpline.name)
                            .font(.headline)
                        Text(helpline.number)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        callNumber(helpline.number)
                    }) {
                        Image(systemName: "phone.fill")
                            .foregroundColor(.blue)
                    }
                }
                .padding(.vertical, 6)
            }
            .navigationTitle("Helplines")
        }
    }
    
    private func callNumber(_ number: String) {
        let tel = "tel://\(number)"
        if let url = URL(string: tel) {
            UIApplication.shared.open(url)
        }
    }
}
