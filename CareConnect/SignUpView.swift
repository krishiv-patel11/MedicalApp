import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct SignUpView: View {

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var authViewModel: AuthViewModel

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var city = ""
    @State private var selectedState = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var role: String? = nil

    @State private var showIdentityVerification = false
    @State private var showHelperQuestions = false
    @State private var showInNeedQuestions = false

    @State private var errorMessage = ""
    @State private var passwordStrength: PasswordStrength = .weak
    @State private var formAppeared = false

    private let stateMap: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas",
        "CA": "California", "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware",
        "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho",
        "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi",
        "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
        "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah",
        "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
        "WI": "Wisconsin", "WY": "Wyoming"
    ]

    private var usStates: [String] {
        Array(stateMap.keys).sorted()
    }

    enum PasswordStrength {
        case weak, medium, strong

        var color: Color {
            switch self {
            case .weak:
                return .red
            case .medium:
                return .yellow
            case .strong:
                return .green
            }
        }

        var description: String {
            switch self {
            case .weak:
                return "Weak"
            case .medium:
                return "Medium"
            case .strong:
                return "Strong"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {

                    Text("Sign Up")
                        .font(.largeTitle)
                        .foregroundColor(.white)
                        .bold()
                        .opacity(formAppeared ? 1 : 0)

                    groupField("Full Name", text: $name)

                    groupField("Email", text: $email)
                        .keyboardType(.emailAddress)

                    groupField("Phone Number", text: $phone)
                        .keyboardType(.phonePad)

                    groupField("City", text: $city)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("State")
                            .foregroundColor(.white)
                            .font(.caption)

                        Picker("Select State", selection: $selectedState) {
                            Text("Select a State")
                                .tag("")

                            ForEach(usStates, id: \.self) { state in
                                Text(state)
                                    .tag(state)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(12)
                        .foregroundColor(
                            selectedState.isEmpty ? .gray : .white
                        )
                    }

                    secureField("Password", text: $password)
                        .onChange(of: password) {
                            passwordStrength = checkPasswordStrength($0)
                        }

                    VStack(alignment: .leading) {
                        Rectangle()
                            .frame(height: 6)
                            .foregroundColor(passwordStrength.color)
                            .cornerRadius(3)

                        Text(
                            "Password strength: \(passwordStrength.description)"
                        )
                        .font(.caption)
                        .foregroundColor(passwordStrength.color)
                    }

                    secureField(
                        "Confirm Password",
                        text: $confirmPassword
                    )

                    HStack(spacing: 16) {
                        animatedRoleButton(
                            title: "I'm a Helper",
                            value: "helper"
                        )

                        animatedRoleButton(
                            title: "I Need Help",
                            value: "in_need"
                        )
                    }

                    Button(action: submit) {
                        Text("Submit")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                isFormValid()
                                ? Color.white
                                : Color.gray
                            )
                            .foregroundColor(
                                isFormValid()
                                ? .black
                                : .white
                            )
                            .cornerRadius(12)
                    }
                    .disabled(!isFormValid())

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 5)
                    }

                    Spacer(minLength: 50)
                }
                .padding()
                .onAppear {
                    formAppeared = true
                }
            }
        }

        // MARK: Identity Verification

        .sheet(isPresented: $showIdentityVerification) {
            IdentityVerificationView {

                showIdentityVerification = false

                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.25
                ) {
                    if role == "helper" {
                        showHelperQuestions = true
                    } else if role == "in_need" {
                        showInNeedQuestions = true
                    }
                }
            }
        }

        // MARK: Helper Questions

        .sheet(isPresented: $showHelperQuestions) {
            HelperQuestionsView(
                userData: basicUserData(),
                onCompleted: {
                    markOnboardingCompleted()
                }
            )
        }

        // MARK: In-Need Questions

        .sheet(isPresented: $showInNeedQuestions) {
            InNeedQuestionsView(
                userData: basicUserData(),
                onCompleted: {
                    markOnboardingCompleted()
                }
            )
        }
    }

    // MARK: - Basic User Data

    func basicUserData() -> [String: Any] {
        return [
            "name": name,
            "email": email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            "phone": phone,
            "city": city,
            "state": stateMap[selectedState] ?? selectedState,
            "role": role ?? "unknown"
        ]
    }

    // MARK: - Mark Onboarding Complete

    private func markOnboardingCompleted() {
        guard let uid = Auth.auth().currentUser?.uid else {
            print("Could not mark onboarding complete: no current user.")
            return
        }

        Firestore.firestore()
            .collection("users")
            .document(uid)
            .setData(
                [
                    "onboardingStatus": "completed",
                    "onboardingCompletedAt": Timestamp()
                ],
                merge: true
            ) { error in

                if let error = error {
                    print(
                        "Failed to mark onboarding complete: \(error.localizedDescription)"
                    )

                    DispatchQueue.main.async {
                        errorMessage =
                            "Your account could not be finalized. Please try again."
                    }

                    return
                }

                print("Account onboarding marked as completed.")

                DispatchQueue.main.async {
                    authViewModel.completeAccountCreation()
                }
            }
    }

    // MARK: - Fields

    func groupField(
        _ title: String,
        text: Binding<String>
    ) -> some View {

        TextField(title, text: text)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(12)
            .foregroundColor(.white)
            .autocapitalization(.none)
    }

    func secureField(
        _ title: String,
        text: Binding<String>
    ) -> some View {

        SecureField(title, text: text)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(12)
            .foregroundColor(.white)
    }

    // MARK: - Role Buttons

    func animatedRoleButton(
        title: String,
        value: String
    ) -> some View {

        Button(action: {
            withAnimation {
                role = value
            }
        }) {

            Text(title)
                .fontWeight(.semibold)
                .foregroundColor(
                    role == value ? .black : .white
                )
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    role == value
                    ? Color.white
                    : Color.black
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            role == value
                            ? Color.black
                            : Color.white,
                            lineWidth: 2
                        )
                )
                .cornerRadius(12)
                .scaleEffect(
                    role == value ? 1.05 : 1.0
                )
        }
    }

    // MARK: - Form Validation

    func isFormValid() -> Bool {

        guard
            !name.isEmpty,
            !email.isEmpty,
            !phone.isEmpty,
            !city.isEmpty,
            !selectedState.isEmpty,
            !password.isEmpty,
            !confirmPassword.isEmpty,
            password == confirmPassword,
            isValidEmail(email),
            passwordStrength == .strong,
            role != nil
        else {
            return false
        }

        return true
    }

    func isValidEmail(_ email: String) -> Bool {

        let emailRegEx = #"^\S+@\S+\.\S+$"#

        return NSPredicate(
            format: "SELF MATCHES %@",
            emailRegEx
        )
        .evaluate(with: email)
    }

    // MARK: - Password Strength

    func checkPasswordStrength(
        _ password: String
    ) -> PasswordStrength {

        let length = password.count >= 10

        let upper =
            password.rangeOfCharacter(
                from: .uppercaseLetters
            ) != nil

        let lower =
            password.rangeOfCharacter(
                from: .lowercaseLetters
            ) != nil

        let digit =
            password.rangeOfCharacter(
                from: .decimalDigits
            ) != nil

        let symbol =
            password.rangeOfCharacter(
                from: .punctuationCharacters
            ) != nil
            ||
            password.rangeOfCharacter(
                from: .symbols
            ) != nil

        let score = [
            length,
            upper,
            lower,
            digit,
            symbol
        ]
        .filter { $0 }
        .count

        switch score {
        case 5:
            return .strong

        case 3...4:
            return .medium

        default:
            return .weak
        }
    }

    // MARK: - Submit

    func submit() {

        print("Submit tapped")

        errorMessage = ""

        // Validate FIRST.
        // This prevents the onboarding state from getting stuck
        // when the form itself is invalid.
        guard isFormValid() else {

            print("Form invalid")

            if password != confirmPassword {
                errorMessage = "Passwords do not match."

            } else if !isValidEmail(email) {
                errorMessage = "Enter a valid email address."

            } else if passwordStrength != .strong {
                errorMessage = "Password is not strong enough."

            } else if selectedState.isEmpty {
                errorMessage = "Please select a state."

            } else if role == nil {
                errorMessage = "Please select a role."

            } else {
                errorMessage = "Please fill all fields correctly."
            }

            print("Error: \(errorMessage)")
            return
        }

        // Only begin account creation after validation succeeds.
        authViewModel.beginAccountCreation()

        let normalizedEmail =
            email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        print("Creating or resuming account with email: \(normalizedEmail)")

        Auth.auth().createUser(
            withEmail: normalizedEmail,
            password: password
        ) { result, error in

            // MARK: New Account

            if let result = result,
               error == nil {

                let uid = result.user.uid

                print("New user created, uid: \(uid)")

                let db = Firestore.firestore()

                let fullStateName =
                    stateMap[selectedState] ?? selectedState

                let userData: [String: Any] = [
                    "name": self.name,
                    "email": normalizedEmail,
                    "phone": self.phone,
                    "city": self.city,
                    "state": fullStateName,
                    "role": self.role ?? "unknown",
                    "onboardingStatus": "in_progress",
                    "createdAt": Timestamp()
                ]

                db.collection("users")
                    .document(uid)
                    .setData(userData) { err in

                        if let err = err {

                            DispatchQueue.main.async {
                                self.errorMessage =
                                    "Failed to save user data: \(err.localizedDescription)"
                                self.authViewModel.isCreatingAccount = false
                            }

                            print(
                                "Firestore error: \(err.localizedDescription)"
                            )

                            return
                        }

                        print("New user data saved successfully.")

                        DispatchQueue.main.async {

                            // New account → identity verification.
                            self.showIdentityVerification = true
                        }
                    }

                return
            }

            // MARK: Existing Firebase Account

            guard let error = error else {
                DispatchQueue.main.async {
                    self.errorMessage =
                        "Unable to create or resume your account."
                    self.authViewModel.isCreatingAccount = false
                }
                return
            }

            let nsError = error as NSError

            // Firebase uses this error when the email already belongs
            // to an Auth account.
            guard nsError.code == AuthErrorCode.emailAlreadyInUse.rawValue else {

                DispatchQueue.main.async {
                    self.errorMessage =
                        "Failed to create account: \(error.localizedDescription)"
                    self.authViewModel.isCreatingAccount = false
                }

                print(
                    "Auth error: \(error.localizedDescription)"
                )

                return
            }

            print(
                "Email already has a Firebase account. Checking onboarding status."
            )

            // The account exists, so sign into it using the credentials
            // the user just entered. This allows an incomplete signup
            // to be resumed.
            Auth.auth().signIn(
                withEmail: normalizedEmail,
                password: password
            ) { signInResult, signInError in

                if let signInError = signInError {

                    DispatchQueue.main.async {
                        self.errorMessage =
                            "This email already has an account. If this is your account, enter the password you originally used."
                        self.authViewModel.isCreatingAccount = false
                    }

                    print(
                        "Could not resume existing account: \(signInError.localizedDescription)"
                    )

                    return
                }

                guard let uid = signInResult?.user.uid else {

                    DispatchQueue.main.async {
                        self.errorMessage =
                            "Unable to identify the existing account."
                        self.authViewModel.isCreatingAccount = false
                    }

                    return
                }

                let db = Firestore.firestore()

                db.collection("users")
                    .document(uid)
                    .getDocument { document, firestoreError in

                        if let firestoreError = firestoreError {

                            DispatchQueue.main.async {
                                self.errorMessage =
                                    "Unable to check your account status: \(firestoreError.localizedDescription)"
                                self.authViewModel.isCreatingAccount = false
                            }

                            return
                        }

                        let data = document?.data()

                        let onboardingStatus =
                            data?["onboardingStatus"] as? String

                        // MARK: Completed Account

                        if onboardingStatus == "completed" {

                            print(
                                "Account is already fully completed."
                            )

                            do {
                                try Auth.auth().signOut()
                            } catch {
                                print(
                                    "Error signing out completed account: \(error.localizedDescription)"
                                )
                            }

                            DispatchQueue.main.async {
                                self.authViewModel.isCreatingAccount = false

                                self.errorMessage =
                                    "An account with this email has already been completed. Please sign in instead."
                            }

                            return
                        }

                        // MARK: Incomplete Account

                        print(
                            "Existing account is incomplete. Resuming onboarding."
                        )

                        let fullStateName =
                            self.stateMap[self.selectedState] ??
                            self.selectedState

                        let updatedData: [String: Any] = [
                            "name": self.name,
                            "email": normalizedEmail,
                            "phone": self.phone,
                            "city": self.city,
                            "state": fullStateName,
                            "role": self.role ?? "unknown",
                            "onboardingStatus": "in_progress"
                        ]

                        db.collection("users")
                            .document(uid)
                            .setData(
                                updatedData,
                                merge: true
                            ) { updateError in

                                if let updateError = updateError {

                                    DispatchQueue.main.async {
                                        self.errorMessage =
                                            "Unable to resume your account: \(updateError.localizedDescription)"
                                        self.authViewModel.isCreatingAccount = false
                                    }

                                    return
                                }

                                print(
                                    "Incomplete account updated. Resuming identity verification."
                                )

                                DispatchQueue.main.async {

                                    // Existing but incomplete account.
                                    // Let the user retry verification.
                                    self.showIdentityVerification = true
                                }
                            }
                    }
            }
        }
    }
}
