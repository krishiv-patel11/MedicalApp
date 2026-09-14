import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct HelperQuestionsView: View {
    var userData: [String: Any]
    @Environment(\.dismiss) var dismiss
    @State private var selectedServices: Set<String> = []
    @State private var selectedDays: Set<String> = []
    @State private var isVerified = false
    @State private var isSubmitting = false
    @State private var errorMessage = ""

    let services = ["Medical", "Home", "Transportation", "Other"]
    let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("What Services Can You Offer?")) {
                    ForEach(services, id: \.self) { service in
                        Toggle(service, isOn: Binding(
                            get: { selectedServices.contains(service) },
                            set: { isOn in
                                if isOn { selectedServices.insert(service) }
                                else { selectedServices.remove(service) }
                            }
                        ))
                    }
                }

                Section(header: Text("What Days Are You Available?")) {
                    ForEach(days, id: \.self) { day in
                        Toggle(day, isOn: Binding(
                            get: { selectedDays.contains(day) },
                            set: { isOn in
                                if isOn { selectedDays.insert(day) }
                                else { selectedDays.remove(day) }
                            }
                        ))
                    }
                }

                Section {
                    Toggle("I verify I am a safe and reliable person for transportation assistance.", isOn: $isVerified)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }

                Button(action: saveHelperProfile) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Submit")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Helper Info")
        }
    }

    func saveHelperProfile() {
        guard !selectedServices.isEmpty, !selectedDays.isEmpty else {
            errorMessage = "Please select at least one service and one available day."
            return
        }

        isSubmitting = true
        errorMessage = ""

        guard let uid = Auth.auth().currentUser?.uid else { return }
        var profile = userData
        profile["services"] = Array(selectedServices)
        profile["daysAvailable"] = Array(selectedDays)
        profile["verified"] = isVerified

        Firestore.firestore().collection("users").document(uid).setData(profile, merge: true) { error in
            isSubmitting = false
            if let error = error {
                errorMessage = "Error saving data: \(error.localizedDescription)"
            } else {
                dismiss()
            }
        }
    }
}
