import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import GoogleSignInSwift

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        FirebaseApp.configure()
        do {
            try Auth.auth().signOut()
        } catch {
            print("Error signing out on launch: \(error.localizedDescription)")
        }

        return true
    }

    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
}

@main
struct CareConnectApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var authViewModel = AuthViewModel()
    @StateObject var accessibilitySettings = AccessibilitySettings()
    @StateObject var medicationViewModel = MedicationListViewModel()
    @StateObject var dailyPointsVM = DailyPointsViewModel()

    init() {
        print("CareConnectApp initialized")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authViewModel)
                .environmentObject(accessibilitySettings)
                .environmentObject(medicationViewModel)
                .environmentObject(dailyPointsVM) 
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @EnvironmentObject var accessibilitySettings: AccessibilitySettings
    @EnvironmentObject var dailyPointsVM: DailyPointsViewModel
    @State private var homeViewID = UUID()

    var body: some View {
        Group {
            if authViewModel.isLoggedIn {
                HomeView(viewModel: MainViewModel())
                    .environmentObject(dailyPointsVM)
                    .id(homeViewID)
            } else {
                LoginView()
            }
        }
        .onAppear {
            print("RootView appeared. isLoggedIn = \(authViewModel.isLoggedIn)")
        }
        .onChange(of: authViewModel.isLoggedIn) { isLoggedIn in
            print("authViewModel.isLoggedIn changed to \(isLoggedIn)")
            if isLoggedIn {
                homeViewID = UUID()
            }
        }
    }
}
