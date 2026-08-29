import SwiftUI
import GSDModel
import GSDSync

/// Settings → Feedback: anonymous, opt-in feedback (parity with the web's
/// Settings → Feedback, spec'd by web #516).
///
/// Everything drafts locally (standard `UserDefaults`; extensions never read
/// it) and nothing touches the network until the user presses Send. The
/// disclosure renders from the same `FeedbackPayloadBuilder.build` output that
/// becomes the request body, so the preview cannot drift from what is sent.
struct FeedbackView: View {
    @State private var draft = FeedbackDraft()
    @State private var isSending = false
    @State private var sendFailure: FeedbackSubmitOutcome?
    @State private var lastSentAt: Date?

    private let store = FeedbackDraftStore()
    private let client = FeedbackClient(baseURL: AuthConfig.live.baseURL)

    var body: some View {
        Form {
            roadmapSection
            sentimentSection
            messageSection
            disclosureSection
            sendSection
        }
        .scrollContentBackground(.hidden)
        .background(Surface.paper)
        .tint(Surface.tint)
        .navigationTitle(String(localized: "Feedback"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draft = store.loadDraft()
            lastSentAt = store.lastSentAt
        }
        .onChange(of: draft) { store.save(draft) }
    }

    // MARK: Roadmap poll

    private var roadmapSection: some View {
        Section {
            ForEach(Feedback.roadmapItems, id: \.slug) { item in
                Toggle(isOn: voteBinding(item.slug)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                        Text(item.description)
                            .font(.footnote).foregroundStyle(Surface.ink2)
                    }
                }
                .tint(Surface.tint)
            }
        } header: {
            Text(String(localized: "What should GSD build next?"))
        } footer: {
            Text(String(localized: "Votes are anonymous — they carry no account, device, or task information."))
        }
    }

    private func voteBinding(_ slug: String) -> Binding<Bool> {
        Binding(
            get: { draft.votes.contains(slug) },
            set: { on in
                draft.votes.removeAll { $0 == slug }
                if on { draft.votes.append(slug) }
            }
        )
    }

    // MARK: Sentiment + category

    private var sentimentSection: some View {
        Section(String(localized: "How is GSD working for you?")) {
            HStack(spacing: 12) {
                sentimentButton(.up, symbol: "hand.thumbsup",
                                label: String(localized: "Thumbs up"))
                sentimentButton(.down, symbol: "hand.thumbsdown",
                                label: String(localized: "Thumbs down"))
                Spacer()
            }
            Picker(String(localized: "Category"), selection: $draft.category) {
                Text(String(localized: "None")).tag(FeedbackCategory?.none)
                Text(String(localized: "Idea")).tag(FeedbackCategory?.some(.idea))
                Text(String(localized: "Praise")).tag(FeedbackCategory?.some(.praise))
                Text(String(localized: "Gripe")).tag(FeedbackCategory?.some(.gripe))
                Text(String(localized: "Bug")).tag(FeedbackCategory?.some(.bug))
            }
        }
    }

    private func sentimentButton(_ value: FeedbackSentiment, symbol: String, label: String) -> some View {
        let selected = draft.sentiment == value
        return Button {
            draft.sentiment = selected ? nil : value
        } label: {
            Image(systemName: selected ? "\(symbol).fill" : symbol)
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(selected ? Surface.tint : Surface.ink2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Message

    private var messageSection: some View {
        Section {
            TextEditor(text: $draft.message)
                .frame(minHeight: 88)
                .accessibilityLabel(String(localized: "Feedback message"))
                .onChange(of: draft.message) {
                    if draft.message.count > Feedback.maxMessageLength {
                        draft.message = String(draft.message.prefix(Feedback.maxMessageLength))
                    }
                }
        } header: {
            Text(String(localized: "Anything else?"))
        } footer: {
            Text("\(draft.message.count)/\(Feedback.maxMessageLength)")
                .monospacedDigit()
        }
    }

    // MARK: Disclosure — the exact payload, from the same builder that sends

    private var disclosureSection: some View {
        Section {
            DisclosureGroup(String(localized: "See exactly what gets sent")) {
                Text(payloadPreview)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Surface.ink2)
                    .textSelection(.enabled)
            }
        } footer: {
            Text(String(localized: "This is the complete payload. No name, email, account, device ID, or task data — the app cannot add fields without changing this preview."))
        }
    }

    private var payloadPreview: String {
        guard let payload = try? FeedbackPayloadBuilder.build(draft: draft,
                                                              submissionID: store.submissionID(),
                                                              appVersion: Self.appVersion,
                                                              submittedAt: .now),
              let data = try? encoder.encode(payload) else {
            return String(localized: "Nothing to send yet.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: Send

    private var sendSection: some View {
        Section {
            Button {
                send()
            } label: {
                if isSending {
                    ProgressView()
                } else {
                    Label(String(localized: "Send Feedback"), systemImage: "paperplane")
                }
            }
            .disabled(draft.isEmpty || isSending)
            if let sendFailure {
                Text(failureMessage(sendFailure))
                    .font(.footnote).foregroundStyle(Surface.alert)
            }
        } footer: {
            if let lastSentAt {
                Text(String(localized: "Last sent \(lastSentAt.formatted(date: .abbreviated, time: .shortened)). Thank you!"))
            } else {
                Text(String(localized: "Nothing is sent until you press Send."))
            }
        }
    }

    private func send() {
        // The submission id is minted per draft and reused across retries, so
        // a resend of the same draft collapses server-side instead of doubling.
        guard let payload = try? FeedbackPayloadBuilder.build(draft: draft,
                                                              submissionID: store.submissionID(),
                                                              appVersion: Self.appVersion,
                                                              submittedAt: .now) else { return }
        isSending = true
        sendFailure = nil
        _Concurrency.Task {
            let outcome = await client.submit(payload)
            isSending = false
            if outcome == .sent {
                draft = FeedbackDraft()
                store.clearAfterSend()
                lastSentAt = store.lastSentAt
            } else {
                sendFailure = outcome
            }
        }
    }

    private func failureMessage(_ outcome: FeedbackSubmitOutcome) -> String {
        switch outcome {
        case .offline:
            String(localized: "Couldn't reach the server. Your draft is saved — try again when you're online.")
        case .rateLimited:
            String(localized: "Too many submissions right now. Your draft is saved — try again later.")
        case .serverError:
            String(localized: "The server had a problem. Your draft is saved — try again shortly.")
        case .rejected, .sent:
            String(localized: "The server refused this submission. Your draft is saved.")
        }
    }

    /// `ios-<version>.<build>`, clamped to the wire limit — e.g. `ios-2.2.0.31`.
    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return String("ios-\(version).\(build)".prefix(Feedback.maxAppVersionLength))
    }
}

/// Draft persistence in standard `UserDefaults` (deliberately NOT the App
/// Group — extensions have no feedback surface, so the draft stays app-only).
private struct FeedbackDraftStore {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let draft = "feedback.draft"
        static let submissionID = "feedback.submissionID"
        static let lastSentAt = "feedback.lastSentAt"
    }

    func loadDraft() -> FeedbackDraft {
        guard let data = defaults.data(forKey: Key.draft),
              let draft = try? JSONDecoder().decode(FeedbackDraft.self, from: data) else {
            return FeedbackDraft()
        }
        return draft
    }

    func save(_ draft: FeedbackDraft) {
        if let data = try? JSONEncoder().encode(draft) {
            defaults.set(data, forKey: Key.draft)
        }
    }

    /// Stable per draft: minted on first use, cleared only after a successful
    /// send, so retries of the same draft carry the same id.
    func submissionID() -> String {
        if let existing = defaults.string(forKey: Key.submissionID) { return existing }
        let fresh = IDGenerator.generate()
        defaults.set(fresh, forKey: Key.submissionID)
        return fresh
    }

    var lastSentAt: Date? {
        let stamp = defaults.double(forKey: Key.lastSentAt)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    func clearAfterSend() {
        defaults.removeObject(forKey: Key.draft)
        defaults.removeObject(forKey: Key.submissionID)
        defaults.set(Date.now.timeIntervalSince1970, forKey: Key.lastSentAt)
    }
}
