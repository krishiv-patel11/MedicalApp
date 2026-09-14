import SwiftUI
import Combine
import UIKit

struct WebBenefit: Identifiable, Decodable {
    var id: String { link }
    let title: String
    let snippet: String
    let link: String
    let displayLink: String
}

struct GoogleSearchResponse: Decodable {
    let results: [WebBenefit]
}

class BenefitsViewModel: ObservableObject {
    @Published var city: String = ""
    @Published var selectedState: String = ""
    @Published var benefits: [WebBenefit] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    var dailyPointsVM: DailyPointsViewModel?

    let usStates = ["", "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL",
                    "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME",
                    "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH",
                    "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI",
                    "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY"]

    func fetchBenefits() {
        guard !city.isEmpty, !selectedState.isEmpty else {
            errorMessage = "Please enter both city and state."
            return
        }

        errorMessage = nil
        isLoading = true
        benefits = []

        let cityParam = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let stateParam = selectedState.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "http://127.0.0.1:5001/careconnect-ee8d7/us-central1/getSeniorBenefits?city=\(cityParam)&state=\(stateParam)"

        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL"
            isLoading = false
            return
        }
        
        dailyPointsVM?.addPoints(2)

        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    self.errorMessage = "Request error: \(error.localizedDescription)"
                    return
                }
                guard let data = data else {
                    self.errorMessage = "No data received."
                    return
                }

                do {
                    let decoded = try JSONDecoder().decode(GoogleSearchResponse.self, from: data)
                    self.benefits = decoded.results
                    if self.benefits.isEmpty {
                        self.errorMessage = "No benefits found."
                    }
                } catch {
                    self.errorMessage = "Failed to decode response: \(error.localizedDescription)"
                }
            }
        }.resume()
    }
}

struct BenefitsView: View {
    @StateObject private var vm = BenefitsViewModel()
    @State private var showVeteranSheet = false
    @EnvironmentObject var dailyPointsVM: DailyPointsViewModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationView {
                ScrollView {
                    VStack(spacing: 24) {
                        headerSection
                        searchSection
                        feedbackSection
                        resultsSection
                    }
                    .padding(.bottom, 100)
                    .padding(.top, 24)
                }
                .navigationTitle("Benefits")
                .navigationBarTitleDisplayMode(.inline)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            }
            .onAppear {
                vm.dailyPointsVM = dailyPointsVM
            }
            veteranInfoButton
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            WordSpeakableText(text: "Senior Benefits Finder")
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)

            WordSpeakableText(text: "Enter your city and state to search for local senior benefits.")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var searchSection: some View {
        VStack(spacing: 16) {
            TextField("City", text: $vm.city)
                .font(.system(size: 17))
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)

            HStack {
                WordSpeakableText(text: "State:")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.leading, 24)

                Spacer()

                Picker("State", selection: $vm.selectedState) {
                    ForEach(vm.usStates, id: \.self) { state in
                        Text(state.isEmpty ? "Select" : state)
                            .font(.system(size: 17))
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: 140)
                .padding(.vertical, 10)
                .padding(.horizontal)
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.trailing, 24)
            }

            Button(action: {
                vm.fetchBenefits()
                UIApplication.shared.dismissKeyboard()
            }) {
                Text("Search Benefits")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(vm.city.isEmpty || vm.selectedState.isEmpty ? Color.gray : Color.blue)
                    .cornerRadius(12)
                    .padding(.horizontal)
            }
            .disabled(vm.city.isEmpty || vm.selectedState.isEmpty)
        }
    }

    private var feedbackSection: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()
            } else if let error = vm.errorMessage {
                WordSpeakableText(text: error)
                    .font(.system(size: 17))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private var resultsSection: some View {
        if vm.benefits.isEmpty { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                WordSpeakableText(text: "Results")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal)

                ForEach(vm.benefits) { benefit in
                    BenefitCardView(benefit: benefit)
                        .padding(.horizontal)
                }
            }
            .padding(.top, 8)
        )
    }

    private var veteranInfoButton: some View {
        VStack(spacing: 6) {
            Button(action: {
                showVeteranSheet = true
            }) {
                Image("us-army-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(radius: 6)
                    .padding(8)
            }
            WordSpeakableText(text: "Veteran Info")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.bottom, 2)
        .padding(.trailing, 24)
        .sheet(isPresented: $showVeteranSheet) {
            VeteranBenefitsView()
        }
    }
}

struct BenefitCardView: View {
    let benefit: WebBenefit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WordSpeakableText(text: benefit.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            WordSpeakableText(text: benefit.snippet)
                .font(.system(size: 17))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = URL(string: benefit.link) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                        WordSpeakableText(text: benefit.displayLink)
                            .underline()
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.blue)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(.systemGray4), lineWidth: 0.5)
                )
        )
        .padding(.vertical, 8)
    }
}

extension UIApplication {
    func dismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct VeteranBenefitsView: View {
    @State private var city: String = ""
    @State private var selectedState: String = "AL"
    @State private var selectedCategory: Category = .benefits
    @State private var results: [ResultItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var forceRefresh = false 

    let usStates = ["AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
                    "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
                    "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
                    "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
                    "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY"]

    enum Category: String, CaseIterable, Identifiable {
        case benefits = "Benefits"
        case offices = "Offices"
        var id: String { self.rawValue }
    }

    struct ResultItem: Identifiable {
        let id = UUID()
        let title: String
        let snippet: String
        let link: String
    }

    var body: some View {
        VStack(spacing: 16) {
            headerSection
            searchControls

            if isLoading {
                ProgressView()
                    .scaleEffect(1.6)
                    .padding()
            } else if let errorMessage = errorMessage {
                WordSpeakableText(text: errorMessage)
                    .foregroundColor(.red)
                    .font(.system(size: 17))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                resultsList
            }
        }
        .padding(.vertical)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onChange(of: selectedCategory) { _ in fetchResults() }
        .onChange(of: forceRefresh) { _ in fetchResults() }
        .onAppear { fetchResults() }
    }

    var headerSection: some View {
        VStack(spacing: 8) {
            WordSpeakableText(text: "Veteran Benefits & VA Offices")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)

            WordSpeakableText(text: "Explore veteran-specific benefits and locate nearby VA offices.")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    var searchControls: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                    .font(.system(size: 17))

                TextField("Enter city", text: $city)
                    .autocapitalization(.words)
                    .disableAutocorrection(true)
                    .font(.system(size: 17))
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal)

            Menu {
                ForEach(usStates, id: \.self) { state in
                    Button(action: {
                        selectedState = state
                    }) {
                        WordSpeakableText(text: state)
                            .font(.system(size: 17))
                    }
                }
            } label: {
                HStack {
                    Text("State: \(selectedState)")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundColor(.gray)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .font(.system(size: 17))
                .padding(.horizontal)
            }

            Picker("Search For", selection: $selectedCategory) {
                ForEach(Category.allCases) { category in
                    WordSpeakableText(text: category.rawValue).tag(category)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            .font(.system(size: 17))

            Button(action: {
                fetchResults()
            }) {
                HStack {
                    Image(systemName: "magnifyingglass.circle.fill")
                    Text("Search")
                }
                .font(.system(size: 17, weight: .semibold))
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }

    var resultsList: some View {
        List(results) { item in
            VStack(alignment: .leading, spacing: 8) {
                if let url = URL(string: item.link) {
                    Link(destination: url) {
                        WordSpeakableText(text: item.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.blue)
                            .lineLimit(2)
                    }
                } else {
                    WordSpeakableText(text: item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }

                WordSpeakableText(text: item.snippet)
                    .font(.system(size: 17))
                    .foregroundColor(.secondary)
                    .lineLimit(3)

                WordSpeakableText(text: item.link)
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
        }
        .listStyle(PlainListStyle())
    }

    func fetchResults() {
        guard !city.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        results = []

        let baseURL = "http://127.0.0.1:5001/careconnect-ee8d7/us-central1/"
        let endpoint = selectedCategory == .benefits ? "getVeteranBenefits" : "getVAOffices"
        let urlString = "\(baseURL)\(endpoint)?city=\(city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&state=\(selectedState)"

        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL."
            isLoading = false
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error = error {
                    errorMessage = "Error: \(error.localizedDescription)"
                    return
                }
                guard let data = data else {
                    errorMessage = "No data returned."
                    return
                }
                do {
                    let decoded = try JSONDecoder().decode(SearchResults.self, from: data)
                    results = decoded.results.map {
                        ResultItem(title: $0.title, snippet: $0.snippet, link: $0.link)
                    }
                } catch {
                    errorMessage = "Failed to decode results."
                    print("Decode error:", error)
                }
            }
        }.resume()
    }

    struct SearchResults: Codable {
        let results: [SearchResultItem]
    }

    struct SearchResultItem: Codable {
        let title: String
        let snippet: String
        let link: String
    }
}
