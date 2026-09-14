import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct InNeedQuestionsView: View {
    var userData: [String: Any]
    @Environment(\.dismiss) var dismiss
    @State private var selectedNeeds: Set<String> = []
    @State private var selectedDays: Set<String> = []
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage = ""

    let needs = ["Medical", "Home", "Transportation", "Other"]
    let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("What Services Do You Need?")) {
                    ForEach(needs, id: \.self) { need in
                        Toggle(need, isOn: Binding(
                            get: { selectedNeeds.contains(need) },
                            set: { isOn in
                                if isOn { selectedNeeds.insert(need) }
                                else { selectedNeeds.remove(need) }
                            }
                        ))
                    }
                }

                Section(header: Text("What Days Do You Need Help?")) {
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

                Section(header: Text("Additional Notes")) {
                    TextEditor(text: $notes)
                        .frame(height: 100)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }

                Button(action: saveInNeedProfile) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Submit")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("In Need Info")
        }
    }

    func saveInNeedProfile() {
        guard !selectedNeeds.isEmpty, !selectedDays.isEmpty else {
            errorMessage = "Please select at least one need and one day."
            return
        }

        isSubmitting = true
        errorMessage = ""

        guard let uid = Auth.auth().currentUser?.uid else { return }
        var profile = userData
        profile["needs"] = Array(selectedNeeds)
        profile["daysNeeded"] = Array(selectedDays)
        profile["notes"] = notes

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
