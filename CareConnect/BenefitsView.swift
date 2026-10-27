import SwiftUI
import Combine
import UIKit

struct WebBenefit: Identifiable, Decodable {
    var id: String { link }

    let title: String
    let snippet: String
    let link: String
    let displayLink: String

    enum CodingKeys: String, CodingKey {
        case title
        case snippet
        case link
        case displayLink
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled result"
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet) ?? "No description available."
        link = try container.decode(String.self, forKey: .link)
        displayLink = try container.decodeIfPresent(String.self, forKey: .displayLink)
            ?? URL(string: link)?.host
            ?? link
    }
}

struct GoogleSearchResponse: Decodable {
    let results: [WebBenefit]
}

private enum BenefitsAPI {
    static let functionsBaseURL =
        "https://us-central1-careconnect-3bd75.cloudfunctions.net"

    static func makeURL(
        endpoint: String,
        city: String,
        state: String
    ) -> URL? {
        guard var components = URLComponents(
            string: "\(functionsBaseURL)/\(endpoint)"
        ) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "city", value: city),
            URLQueryItem(name: "state", value: state)
        ]

        return components.url
    }
}

private enum BenefitsAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case emptyResponse
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The search URL could not be created."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpError(let status, let details):
            if details.isEmpty {
                return "The server returned error \(status). Please try again."
            }
            return "Server error \(status): \(details)"
        case .emptyResponse:
            return "The server returned no data."
        case .decodingError:
            return "The server response could not be read."
        }
    }
}

@MainActor
final class BenefitsViewModel: ObservableObject {
    @Published var city = ""
    @Published var selectedState = ""
    @Published var benefits: [WebBenefit] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var dailyPointsVM: DailyPointsViewModel?

    let usStates = [
        "", "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL",
        "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME",
        "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH",
        "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI",
        "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI",
        "WY"
    ]

    private var searchTask: Task<Void, Never>?

    func fetchBenefits() {
        let trimmedCity = city.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmedCity.isEmpty, !selectedState.isEmpty else {
            errorMessage = "Please enter both city and state."
            return
        }

        guard let url = BenefitsAPI.makeURL(
            endpoint: "getSeniorBenefits",
            city: trimmedCity,
            state: selectedState
        ) else {
            errorMessage = "Invalid benefits search URL."
            return
        }

        searchTask?.cancel()
        isLoading = true
        errorMessage = nil
        benefits = []

        searchTask = Task {
            defer {
                if !Task.isCancelled {
                    isLoading = false
                }
            }

            do {
                let (data, response) = try await URLSession.shared.data(
                    from: url
                )

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BenefitsAPIError.invalidResponse
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let details = String(
                        data: data,
                        encoding: .utf8
                    ) ?? ""

                    print("Senior benefits HTTP status:", httpResponse.statusCode)
                    print("Senior benefits response:", details)

                    throw BenefitsAPIError.httpError(
                        httpResponse.statusCode,
                        details
                    )
                }

                guard !data.isEmpty else {
                    throw BenefitsAPIError.emptyResponse
                }

                let decoded: GoogleSearchResponse

                do {
                    decoded = try JSONDecoder().decode(
                        GoogleSearchResponse.self,
                        from: data
                    )
                } catch {
                    print("Senior benefits decoding error:", error)
                    print(
                        "Senior benefits response body:",
                        String(data: data, encoding: .utf8) ?? "Unreadable"
                    )
                    throw BenefitsAPIError.decodingError
                }

                guard !Task.isCancelled else { return }

                benefits = decoded.results

                if benefits.isEmpty {
                    errorMessage = "No benefits found for \(trimmedCity), \(selectedState). Try another location."
                } else {
                    dailyPointsVM?.addPoints(2)
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                print("Senior benefits request failed:", error)
                errorMessage = error.localizedDescription
            }
        }
    }

    deinit {
        searchTask?.cancel()
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
                .background(
                    Color(.systemGroupedBackground)
                        .ignoresSafeArea()
                )
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

            WordSpeakableText(
                text: "Enter your city and state to search for local senior benefits."
            )
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
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
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
                            .tag(state)
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

            Button {
                UIApplication.shared.dismissKeyboard()
                vm.fetchBenefits()
            } label: {
                HStack(spacing: 8) {
                    if vm.isLoading {
                        ProgressView()
                            .tint(.white)
                    }

                    Text(vm.isLoading ? "Searching..." : "Search Benefits")
                        .font(.system(size: 17, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    vm.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || vm.selectedState.isEmpty
                    ? Color.gray
                    : Color.blue
                )
                .cornerRadius(12)
                .padding(.horizontal)
            }
            .disabled(
                vm.isLoading
                || vm.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || vm.selectedState.isEmpty
            )
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if vm.isLoading {
            ProgressView("Searching for benefits...")
                .scaleEffect(1.1)
                .padding()
        } else if let error = vm.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 24))

                WordSpeakableText(text: error)
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(.red)
            .padding(.horizontal, 28)
        } else if !vm.benefits.isEmpty {
            WordSpeakableText(
                text: "\(vm.benefits.count) results found"
            )
            .font(.system(size: 14))
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !vm.benefits.isEmpty {
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
        }
    }

    private var veteranInfoButton: some View {
        VStack(spacing: 6) {
            Button {
                showVeteranSheet = true
            } label: {
                Image("us-army-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .background(Color.black)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                    )
                    .shadow(radius: 6)
                    .padding(8)
            }
            .accessibilityLabel("Open veteran benefits information")

            WordSpeakableText(text: "Veteran Info")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
        }
        .padding(.bottom, 8)
        .padding(.trailing, 24)
        .sheet(isPresented: $showVeteranSheet) {
            NavigationView {
                VeteranBenefitsView()
            }
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
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = URL(string: benefit.link),
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")

                        WordSpeakableText(text: benefit.displayLink)
                            .underline()
                            .lineLimit(2)
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.blue)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: Color.black.opacity(0.08),
                    radius: 8,
                    x: 0,
                    y: 4
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(.systemGray4), lineWidth: 0.5)
                )
        )
        .padding(.vertical, 4)
    }
}

extension UIApplication {
    func dismissKeyboard() {
        sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

struct VeteranBenefitsView: View {
    @State private var city = ""
    @State private var selectedState = "FL"
    @State private var selectedCategory: Category = .benefits
    @State private var results: [ResultItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var requestTask: Task<Void, Never>?

    private let usStates = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
        "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
        "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
        "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
        "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY"
    ]

    enum Category: String, CaseIterable, Identifiable {
        case benefits = "Benefits"
        case offices = "VA Offices"

        var id: String { rawValue }

        var endpoint: String {
            switch self {
            case .benefits:
                return "getVeteranBenefits"
            case .offices:
                return "getVAOffices"
            }
        }
    }

    struct ResultItem: Identifiable {
        var id: String { link }

        let title: String
        let snippet: String
        let link: String
        var displayLink: String {
            URL(string: link)?.host ?? link
        }
    }

    private struct SearchResults: Decodable {
        let results: [SearchResultItem]
    }

    private struct SearchResultItem: Decodable {
        let title: String
        let snippet: String
        let link: String
    }

    var body: some View {
        VStack(spacing: 16) {
            headerSection
            searchControls

            if isLoading {
                ProgressView("Searching...")
                    .scaleEffect(1.1)
                    .padding()
            } else if let errorMessage {
                WordSpeakableText(text: errorMessage)
                    .foregroundColor(.red)
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)

                    WordSpeakableText(
                        text: "Enter a city and select a state to find veteran resources."
                    )
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity)
            } else {
                resultsList
            }
        }
        .padding(.vertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
        )
        .navigationTitle("Veteran Resources")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            requestTask?.cancel()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            WordSpeakableText(text: "Veteran Benefits & VA Offices")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)

            WordSpeakableText(
                text: "Explore veteran-specific benefits and locate VA offices and services."
            )
            .font(.system(size: 15))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
    }

    private var searchControls: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                    .font(.system(size: 17))

                TextField("Enter city", text: $city)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(.system(size: 17))
                    .onSubmit {
                        fetchResults()
                    }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal)

            Menu {
                ForEach(usStates, id: \.self) { state in
                    Button {
                        selectedState = state
                    } label: {
                        Text(state)
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
                    Text(category.rawValue)
                        .tag(category)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            .font(.system(size: 17))

            Button {
                UIApplication.shared.dismissKeyboard()
                fetchResults()
            } label: {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "magnifyingglass.circle.fill")
                    }

                    Text(isLoading ? "Searching..." : "Search")
                }
                .font(.system(size: 17, weight: .semibold))
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding(.horizontal)
            }
            .disabled(
                isLoading
                || city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    private var resultsList: some View {
        List(results) { item in
            VStack(alignment: .leading, spacing: 8) {
                if let url = URL(string: item.link),
                   ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    Link(destination: url) {
                        WordSpeakableText(text: item.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.blue)
                            .lineLimit(3)
                    }
                } else {
                    WordSpeakableText(text: item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                }

                WordSpeakableText(text: item.snippet)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .lineLimit(4)

                WordSpeakableText(text: item.displayLink)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .lineLimit(2)
            }
            .padding(.vertical, 8)
        }
        .listStyle(PlainListStyle())
    }

    private func fetchResults() {
        let trimmedCity = city.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmedCity.isEmpty, !selectedState.isEmpty else {
            errorMessage = "Please enter a city and select a state."
            results = []
            return
        }

        guard let url = BenefitsAPI.makeURL(
            endpoint: selectedCategory.endpoint,
            city: trimmedCity,
            state: selectedState
        ) else {
            errorMessage = "Invalid veteran search URL."
            return
        }

        requestTask?.cancel()
        isLoading = true
        errorMessage = nil
        results = []

        requestTask = Task {
            defer {
                if !Task.isCancelled {
                    isLoading = false
                }
            }

            do {
                let (data, response) = try await URLSession.shared.data(
                    from: url
                )

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BenefitsAPIError.invalidResponse
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let details = String(
                        data: data,
                        encoding: .utf8
                    ) ?? ""

                    print("Veteran search HTTP status:", httpResponse.statusCode)
                    print("Veteran search response:", details)

                    throw BenefitsAPIError.httpError(
                        httpResponse.statusCode,
                        details
                    )
                }

                guard !data.isEmpty else {
                    throw BenefitsAPIError.emptyResponse
                }

                let decoded: SearchResults

                do {
                    decoded = try JSONDecoder().decode(
                        SearchResults.self,
                        from: data
                    )
                } catch {
                    print("Veteran search decoding error:", error)
                    print(
                        "Veteran search response body:",
                        String(data: data, encoding: .utf8) ?? "Unreadable"
                    )
                    throw BenefitsAPIError.decodingError
                }

                guard !Task.isCancelled else { return }

                results = decoded.results.map { item in
                    ResultItem(
                        title: item.title,
                        snippet: item.snippet,
                        link: item.link
                    )
                }

                if results.isEmpty {
                    errorMessage = "No results found for \(trimmedCity), \(selectedState). Try another location."
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                print("Veteran search request failed:", error)
                errorMessage = error.localizedDescription
            }
        }
    }
}
