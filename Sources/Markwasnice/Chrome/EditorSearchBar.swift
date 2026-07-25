import AppKit
import SwiftUI

struct EditorSearchBar: View {
    @ObservedObject private var state: EditorShellState

    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isReplaceFieldFocused: Bool

    init(state: EditorShellState) {
        self.state = state
    }

    var body: some View {
        // A grid keeps the find and replace fields the same width even
        // though each row trails a different set of controls.
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                searchField
                findControls
            }

            if state.isReplaceEnabled {
                GridRow {
                    replaceField
                    replaceControls
                }
            }
        }
        .frame(height: state.searchBarHeight)
        .onAppear {
            focusSearchField()
        }
        .onChange(of: state.searchFocusRequest) { _, _ in
            focusSearchField()
        }
        .onChange(of: state.isReplaceEnabled) { _, isEnabled in
            if isEnabled {
                isReplaceFieldFocused = true
            } else {
                isSearchFieldFocused = true
            }
        }
    }

    /// Cmd+F can arrive while the editor already owns first responder and
    /// the focus binding still reads true from the previous grab, making a
    /// plain re-set a no-op; on first presentation the field is not in the
    /// window yet when onAppear runs. Dropping the value and re-requesting
    /// on the next runloop turn produces a fresh false→true transition
    /// after the field exists, so the request lands in both cases.
    private func focusSearchField() {
        isSearchFieldFocused = false
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    private var findControls: some View {
        HStack(spacing: 8) {
            SearchSplitButton(
                isDisabled: state.searchMatchCount == 0,
                onFirst: { state.selectPreviousSearchMatch() },
                onSecond: { state.selectNextSearchMatch() }
            ) {
                Image(systemName: "chevron.left")
                    .frame(width: 16)
            } secondLabel: {
                Image(systemName: "chevron.right")
                    .frame(width: 16)
            }

            if state.isReplaceEnabled {
                doneButton.hidden()
            } else {
                doneButton
            }

            Toggle(
                "Replace",
                isOn: Binding(
                    get: { state.isReplaceEnabled },
                    set: { state.setReplaceEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 11, weight: .regular))
            .frame(height: 20)
        }
    }

    private var replaceControls: some View {
        HStack(spacing: 8) {
            SearchSplitButton(
                isDisabled: state.searchMatchCount == 0,
                onFirst: { state.replaceCurrentMatch() },
                onSecond: { state.replaceAllMatches() }
            ) {
                Text("Replace")
                    .padding(.horizontal, 10)
            } secondLabel: {
                Text("All")
                    .padding(.horizontal, 10)
            }

            doneButton
        }
    }

    private var doneButton: some View {
        SearchDoneButton {
            state.closeSearch()
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Menu {
                Button {
                    state.setSearchIgnoresCase(!state.searchOptions.ignoresCase)
                } label: {
                    Label {
                        Text("Ignore Case")
                    } icon: {
                        if state.searchOptions.ignoresCase {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(EditorSearchMode.allCases, id: \.self) { mode in
                    Button {
                        state.setSearchMode(mode)
                    } label: {
                        Label {
                            Text(mode.title)
                        } icon: {
                            if state.searchOptions.mode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 16, height: 18)
            }
            .buttonStyle(.plain)
            .menuStyle(.button)
            .fixedSize()

            TextField(
                "Find",
                text: Binding(
                    get: { state.searchQuery },
                    set: { state.setSearchQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($isSearchFieldFocused)
            .onKeyPress(.escape) {
                state.closeSearch()
                return .handled
            }
            .onSubmit {
                state.selectNextSearchMatch()
            }

            if !state.searchQuery.isEmpty {
                Text("\(state.searchMatchCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
                    .padding(.trailing, 3)
            }

            if !state.searchQuery.isEmpty {
                Button {
                    state.setSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.72))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    fieldBorderColor(isFocused: isSearchFieldFocused),
                    lineWidth: fieldBorderWidth(isFocused: isSearchFieldFocused)
                )
        )
    }

    private var replaceField: some View {
        HStack(spacing: 5) {
            TextField(
                "Replace",
                text: Binding(
                    get: { state.replaceQuery },
                    set: { state.replaceQuery = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($isReplaceFieldFocused)
            .onKeyPress(.escape) {
                state.closeSearch()
                return .handled
            }
            .onSubmit {
                state.replaceCurrentMatch()
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    fieldBorderColor(isFocused: isReplaceFieldFocused),
                    lineWidth: fieldBorderWidth(isFocused: isReplaceFieldFocused)
                )
        )
    }

    private func fieldBorderColor(isFocused: Bool) -> Color {
        isFocused
            ? Color(nsColor: .keyboardFocusIndicatorColor)
            : Color.primary.opacity(0.08)
    }

    private func fieldBorderWidth(isFocused: Bool) -> CGFloat {
        isFocused ? 3 : 1
    }
}

/// Done styled to match SearchMatchStepper: the bordered system button
/// cannot be sized to the 24pt control height the search bar uses.
private struct SearchDoneButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.16 : 0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Two actions fused into one control: a shared pill with a divider on the
/// segment boundary that yields to a per-segment hover highlight.
private struct SearchSplitButton<FirstLabel: View, SecondLabel: View>: View {
    private let isDisabled: Bool
    private let onFirst: () -> Void
    private let onSecond: () -> Void
    private let firstLabel: FirstLabel
    private let secondLabel: SecondLabel

    @State private var isFirstHovered = false
    @State private var isSecondHovered = false

    init(
        isDisabled: Bool,
        onFirst: @escaping () -> Void,
        onSecond: @escaping () -> Void,
        @ViewBuilder firstLabel: () -> FirstLabel,
        @ViewBuilder secondLabel: () -> SecondLabel
    ) {
        self.isDisabled = isDisabled
        self.onFirst = onFirst
        self.onSecond = onSecond
        self.firstLabel = firstLabel()
        self.secondLabel = secondLabel()
    }

    var body: some View {
        HStack(spacing: 0) {
            segment(firstLabel, isHovered: $isFirstHovered, action: onFirst)
            segment(secondLabel, isHovered: $isSecondHovered, action: onSecond)
                // Drawn as an overlay straddling the segment boundary so
                // the divider never adds to the control's width.
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1, height: 11)
                        .offset(x: -0.5)
                        .opacity(isDividerVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
        }
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var isDividerVisible: Bool {
        isDisabled || (!isFirstHovered && !isSecondHovered)
    }

    private func segment(
        _ label: some View,
        isHovered: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(
                    isDisabled ? Color.secondary.opacity(0.5) : Color.primary
                )
                .frame(height: 20)
                .background {
                    if isHovered.wrappedValue, !isDisabled {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered.wrappedValue = $0 }
    }
}
