import SwiftUI
import FirebaseAuth
import GoogleSignIn
import GoogleSignInSwift
import Firebase
import FirebaseCore

struct LoginView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var showSignup = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Welcome Back")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.white)

            VStack(spacing: 16) {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .padding()
                    .background(Color(.systemGray6).opacity(0.2))
                    .cornerRadius(10)
                    .foregroundColor(.white)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding()
                    .background(Color(.systemGray6).opacity(0.2))
                    .cornerRadius(10)
                    .foregroundColor(.white)

                if let error = errorMessage ?? authViewModel.authError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }

                Button(action: {
                    authViewModel.signInWithEmail(email: email, password: password) { error in
                        errorMessage = error
                    }
                }) {
                    if authViewModel.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Text("Login")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .padding(.vertical, 8)
            }
            Spacer()

            HStack {
                Text("Don't have an account?")
                    .foregroundColor(.gray)

                Button("Sign Up") {
                    showSignup = true
                }
                .foregroundColor(.blue)
            }
            .sheet(isPresented: $showSignup) {
                SignUpView()
                    .environmentObject(authViewModel)
            }
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

class AuthViewModel: ObservableObject {
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var authError: String?

    private var authStateListenerHandle: AuthStateDidChangeListenerHandle?

    init() {
        isLoggedIn = Auth.auth().currentUser != nil
        listenToAuthState()
    }

    private func listenToAuthState() {
        authStateListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async {
                self?.isLoggedIn = (user != nil)
            }
        }
    }

    deinit {
        if let handle = authStateListenerHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    func signInWithEmail(email: String, password: String, completion: @escaping (String?) -> Void) {
        isLoading = true
        authError = nil

        Auth.auth().signIn(withEmail: email, password: password) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let error = error {
                    self?.authError = error.localizedDescription
                    completion(error.localizedDescription)
                } else {
                    self?.authError = nil
                    completion(nil)
                }
            }
        }
    }

    func signInWithGoogle() {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            print("Missing Firebase client ID")
            self.authError = "Missing Firebase client ID"
            return
        }

        let config = GIDConfiguration(clientID: clientID)
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            print("Could not get root view controller")
            self.authError = "Root view controller not found"
            return
        }

        self.isLoading = true
        self.authError = nil

        GIDSignIn.sharedInstance.configuration = config

        GIDSignIn.sharedInstance.signIn(withPresenting: rootVC) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.isLoading = false
                    if (error as NSError).code == GIDSignInError.canceled.rawValue {
                        print("Google Sign-In was canceled.")
                    } else {
                        print("Google Sign-In failed: \(error.localizedDescription)")
                        self.authError = error.localizedDescription
                    }
                }
                return
            }

            guard let user = result?.user,
                  let idToken = user.idToken else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.authError = "Missing Google token information."
                }
                return
            }

            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken.tokenString,
                accessToken: user.accessToken.tokenString
            )

            Auth.auth().signIn(with: credential) { _, error in
                DispatchQueue.main.async {
                    self.isLoading = false
                    if let error = error {
                        self.authError = error.localizedDescription
                        print("Firebase sign-in failed: \(error.localizedDescription)")
                    } else {
                        self.authError = nil
                        print("Google sign-in succeeded.")
                    }
                }
            }
        }
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
            self.authError = nil
            self.isLoggedIn = false
            print("User signed out")
        } catch {
            self.authError = error.localizedDescription
            print("Sign out error: \(error.localizedDescription)")
        }
    }
}

struct ModernGoogleButtonView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("google-icon")
                    .resizable()
                    .renderingMode(.original)
                    .frame(width: 24, height: 24)
                Text("Sign in with Google")
                    .fontWeight(.medium)
                    .foregroundColor(.white)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.black.cornerRadius(8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
        }
    }
}
