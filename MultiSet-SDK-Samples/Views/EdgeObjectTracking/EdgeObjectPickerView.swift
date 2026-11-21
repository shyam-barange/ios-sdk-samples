/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

import SwiftUI
import MultiSetSDK

/// The configured edge objects: their state on the dashboard, their download, and the way into
/// tracking one.
struct EdgeObjectPickerView: View {
    @StateObject private var store: EdgeObjectStore
    @State private var trackingEntry: EdgeObjectEntry?
    @State private var toast: MSToast?

    init(codes: [String]) {
        let api = EdgeObjectAPI(baseURL: MultiSet.shared.activeBaseURL, token: { MultiSet.shared.authToken })
        _store = StateObject(wrappedValue: EdgeObjectStore(codes: codes, api: api, unpack: EdgeObjectUnpacker.unpack))
    }

    var body: some View {
        ZStack(alignment: .top) {
            MSColor.appBackground.ignoresSafeArea()
            List {
                if !EotTracker.isSupported {
                    noticeCard(symbol: "iphone.slash", title: "Edge tracking needs an iPhone",
                               message: "The tracker runs only on a device. Build and run the demo on an iPhone to try it.")
                        .listRowStyling()
                }
                ForEach(store.entries) { entry in
                    EdgeObjectRow(entry: entry, onTap: { act(on: entry) }, onRetry: { Task { await store.retry(code: entry.code) } })
                        .listRowStyling()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if store.isDownloaded(code: entry.code) {
                                Button(role: .destructive) { store.delete(code: entry.code) } label: {
                                    Label("Delete download", systemImage: "trash")
                                }
                            }
                        }
                }
                footer.listRowStyling()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.refresh() }

            MSToastBanner($toast)
                .padding(.horizontal, MSSpacing.lg)
                .padding(.top, MSSpacing.sm)
        }
        .navigationTitle("Edge Objects")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: Binding(get: { trackingEntry != nil }, set: { if !$0 { trackingEntry = nil } })) {
            if let trackingEntry, let object = trackingEntry.object, case .ready(let model) = trackingEntry.state {
                EdgeTrackingView(object: object, model: model, storage: store.storage)
            }
        }
        .task { await store.refresh() }
        .onChange(of: store.sessionExpired) { expired in
            if expired { toast = MSToast(message: "Session expired, go back and authenticate again", tone: .failure) }
        }
    }

    private func act(on entry: EdgeObjectEntry) {
        switch entry.state {
        case .ready:
            guard EotTracker.isSupported else {
                toast = MSToast(message: "Edge tracking needs an iPhone", tone: .info)
                return
            }
            trackingEntry = entry
        case .available:
            Task { await store.download(code: entry.code) }
        case .failed:
            Task { await store.retry(code: entry.code) }
        default:
            break
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: MSSpacing.sm) {
            Image(systemName: "lightbulb")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MSColor.warning)
            Text("Keep in mind: edge tracking works best on rigid objects that stand out in colour from what is behind them. Process the model in \"Edge Based\" mode on the MultiSet dashboard.")
                .font(MSFont.caption)
                .foregroundStyle(MSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, MSSpacing.sm)
    }

    private func noticeCard(symbol: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: MSSpacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MSColor.warning)
            VStack(alignment: .leading, spacing: MSSpacing.xxs) {
                Text(title).font(MSFont.headline).foregroundStyle(MSColor.textPrimary)
                Text(message).font(MSFont.caption).foregroundStyle(MSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MSSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MSColor.warningWash, in: RoundedRectangle(cornerRadius: MSRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MSRadius.lg, style: .continuous).strokeBorder(MSColor.warningEdge, lineWidth: 1))
    }
}

private extension View {
    func listRowStyling() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: MSSpacing.sm, leading: MSSpacing.lg, bottom: MSSpacing.sm, trailing: MSSpacing.lg))
    }
}

private struct EdgeObjectRow: View {
    let entry: EdgeObjectEntry
    let onTap: () -> Void
    let onRetry: () -> Void

    private var isActionable: Bool {
        switch entry.state {
        case .ready, .available, .failed: return true
        default: return false
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: MSSpacing.md) {
                thumbnail
                VStack(alignment: .leading, spacing: MSSpacing.xs) {
                    Text(entry.title)
                        .font(MSFont.headline)
                        .foregroundStyle(isGreyed ? MSColor.textMuted : MSColor.textPrimary)
                        .lineLimit(1)
                    detail
                }
                Spacer(minLength: MSSpacing.sm)
                trailing
            }
            .padding(MSSpacing.md)
            .msSurface(.raised)
        }
        .msPressable()
        .disabled(!isActionable)
        .accessibilityLabel("\(entry.title), \(accessibilityState)")
    }

    private var isGreyed: Bool {
        if case .unavailable = entry.state { return true }
        return false
    }

    private var startText: String? {
        guard let object = entry.object else { return nil }
        if object.startsAutomatically { return "Starts automatically" }
        let views = object.guideViews
        return views.isEmpty ? nil : "\(views.count) guide view\(views.count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var detail: some View {
        switch entry.state {
        case .loading:
            Text("Checking the dashboard…").font(MSFont.caption).foregroundStyle(MSColor.textSecondary)
        case .unavailable(let reason):
            Text(reason).font(MSFont.caption).foregroundStyle(MSColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        case .available:
            Text([startText, "Tap to download (about 16 MB)"].compactMap { $0 }.joined(separator: " · "))
                .font(MSFont.caption).foregroundStyle(MSColor.textSecondary)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: MSSpacing.xs) {
                Text("Downloading… \(Int(progress * 100)) %").font(MSFont.caption).foregroundStyle(MSColor.textSecondary)
                ProgressView(value: progress).tint(MSColor.accent)
            }
        case .preparing:
            Text("Preparing the model…").font(MSFont.caption).foregroundStyle(MSColor.textSecondary)
        case .ready(let model):
            Text([model.sizeText, startText].compactMap { $0 }.joined(separator: " · "))
                .font(MSFont.caption).foregroundStyle(MSColor.textSecondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: MSSpacing.xs) {
                Text(message).font(MSFont.caption).foregroundStyle(MSColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: onRetry)
                    .font(MSFont.captionEmphasis)
                    .foregroundStyle(MSColor.accent)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch entry.state {
        case .loading, .preparing:
            ProgressView().tint(MSColor.textMuted)
        case .available:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(MSColor.accent)
        case .ready:
            HStack(spacing: MSSpacing.sm) {
                MSStatusPill("Ready", tone: .positive, systemImage: "checkmark")
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MSColor.textMuted)
            }
        default:
            EmptyView()
        }
    }

    private var thumbnail: some View {
        ZStack {
            if let image = entry.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(MSColor.thumbnailPlaceholder)
                Image(systemName: "cube.transparent")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(MSColor.accent.opacity(0.7))
            }
        }
        .frame(width: MSSize.thumbnail, height: MSSize.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: MSRadius.md, style: .continuous))
        .opacity(isGreyed ? 0.5 : 1)
    }

    private var accessibilityState: String {
        switch entry.state {
        case .loading: return "checking"
        case .unavailable(let reason): return reason
        case .available: return "ready to download"
        case .downloading(let progress): return "downloading \(Int(progress * 100)) percent"
        case .preparing: return "preparing"
        case .ready: return "ready to track"
        case .failed(let message): return message
        }
    }
}
