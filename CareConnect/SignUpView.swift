import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct SignUpView: View {
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var city = ""
    @State private var selectedState = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var role: String? = nil

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

    private var usStates: [String] { Array(stateMap.keys).sorted() }

    enum PasswordStrength {
        case weak, medium, strong

        var color: Color {
            switch self {
            case .weak: return .red
            case .medium: return .yellow
            case .strong: return .green
            }
        }

        var description: String {
            switch self {
            case .weak: return "Weak"
            case .medium: return "Medium"
            case .strong: return "Strong"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    Text("Sign Up")
                        .font(.largeTitle)
                        .foregroundColor(.white)
                        .bold()
                        .opacity(formAppeared ? 1 : 0)

                    groupField("Full Name", text: $name)
                    groupField("Email", text: $email).keyboardType(.emailAddress)
                    groupField("Phone Number", text: $phone).keyboardType(.phonePad)
                    groupField("City", text: $city)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("State")
                            .foregroundColor(.white)
                            .font(.caption)
                        Picker("Select State", selection: $selectedState) {
                            Text("Select a State").tag("")
                            ForEach(usStates, id: \.self) { state in
                                Text(state).tag(state)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(12)
                        .foregroundColor(selectedState.isEmpty ? .gray : .white)
                    }

                    secureField("Password", text: $password)
                        .onChange(of: password) { passwordStrength = checkPasswordStrength($0) }

                    VStack(alignment: .leading) {
                        Rectangle().frame(height: 6).foregroundColor(passwordStrength.color).cornerRadius(3)
                        Text("Password strength: \(passwordStrength.description)")
                            .font(.caption)
                            .foregroundColor(passwordStrength.color)
                    }

                    secureField("Confirm Password", text: $confirmPassword)

                    HStack(spacing: 16) {
                        animatedRoleButton(title: "I'm a Helper", value: "helper")
                        animatedRoleButton(title: "I Need Help", value: "in_need")
                    }

                    Button(action: submit) {
                        Text("Submit")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isFormValid() ? Color.white : Color.gray)
                            .foregroundColor(isFormValid() ? .black : .white)
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
                .onAppear { formAppeared = true }
            }
        }
        .sheet(isPresented: $showHelperQuestions) {
            HelperQuestionsView(userData: basicUserData())
        }
        .sheet(isPresented: $showInNeedQuestions) {
            InNeedQuestionsView(userData: basicUserData())
        }
    }
    
    func basicUserData() -> [String: Any] {
        return [
            "name": name,
            "email": email,
            "phone": phone,
            "city": city,
            "state": selectedState,
            "role": role ?? "unknown",
            "createdAt": Timestamp()
        ]
    }
    
    func groupField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(12)
            .foregroundColor(.white)
            .autocapitalization(.none)
    }

    func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(12)
            .foregroundColor(.white)
    }

    func animatedRoleButton(title: String, value: String) -> some View {
        Button(action: {
            withAnimation { role = value }
        }) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundColor(role == value ? .black : .white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(role == value ? Color.white : Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(role == value ? Color.black : Color.white, lineWidth: 2)
                )
                .cornerRadius(12)
                .scaleEffect(role == value ? 1.05 : 1.0)
        }
    }

    func isFormValid() -> Bool {
        guard !name.isEmpty,
              !email.isEmpty,
              !phone.isEmpty,
              !city.isEmpty,
              !selectedState.isEmpty,
              !password.isEmpty,
              !confirmPassword.isEmpty,
              password == confirmPassword,
              isValidEmail(email),
              passwordStrength == .strong,
              role != nil else { return false }
        return true
    }

    func isValidEmail(_ email: String) -> Bool {
        let emailRegEx = #"^\S+@\S+\.\S+$"#
        return NSPredicate(format: "SELF MATCHES %@", emailRegEx).evaluate(with: email)
    }

    func checkPasswordStrength(_ password: String) -> PasswordStrength {
        let length = password.count >= 10
        let upper = password.rangeOfCharacter(from: .uppercaseLetters) != nil
        let lower = password.rangeOfCharacter(from: .lowercaseLetters) != nil
        let digit = password.rangeOfCharacter(from: .decimalDigits) != nil
        let symbol = password.rangeOfCharacter(from: .punctuationCharacters) != nil || password.rangeOfCharacter(from: .symbols) != nil

        let score = [length, upper, lower, digit, symbol].filter { $0 }.count
        switch score {
        case 5: return .strong
        case 3...4: return .medium
        default: return .weak
        }
    }

    func submit() {
        print("Submit tapped")
        errorMessage = ""

        if !isFormValid() {
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

        print("Creating user with email: \(email)")
        Auth.auth().createUser(withEmail: email, password: password) { result, error in
            if let error = error {
                self.errorMessage = "Failed to create account: \(error.localizedDescription)"
                print("Auth error: \(error.localizedDescription)")
                return
            }

            guard let uid = result?.user.uid else {
                self.errorMessage = "Unexpected error: User ID missing."
                print("No uid found")
                return
            }

            print("User created, uid: \(uid)")

            let db = Firestore.firestore()
            let fullStateName = stateMap[selectedState] ?? selectedState

            let userData: [String: Any] = [
                "name": self.name,
                "email": self.email,
                "phone": self.phone,
                "city": self.city,
                "state": fullStateName, 
                "role": self.role ?? "unknown",
                "createdAt": Timestamp()
            ]
            
            db.collection("users").document(uid).setData(userData) { err in
                if let err = err {
                    self.errorMessage = "Failed to save user data: \(err.localizedDescription)"
                    print("Firestore error: \(err.localizedDescription)")
                    return
                }

                print("User data saved successfully")

                if self.role == "helper" {
                    self.showHelperQuestions = true
                } else if self.role == "in_need" {
                    self.showInNeedQuestions = true
                }
            }
        }
    }
}
