import AppKit

@MainActor
final class ResponseTextHighlightingState {
    private static let maximumWritesPerBatch = 128
    private static let maximumBatchDuration = Duration.milliseconds(4)
    private static let batchYieldInterval = Duration.milliseconds(8)
    private static let maximumInteractionPause = Duration.milliseconds(120)

    private let clock = ContinuousClock()
    private weak var textView: NSTextView?
    private var documentUTF16Length: Int
    private var generation: UInt64 = 0
    private var applicationTask: Task<Void, Never>?
    private var appliedRanges: [NSRange] = []
    private var nextAppliedRangeToClear = 0
    private var pauseDeadline: ContinuousClock.Instant?

    init(textView: NSTextView) {
        self.textView = textView
        documentUTF16Length = (textView.string as NSString).length
    }

    func replace(spans: [SyntaxHighlighting.Span], textUTF16Length: Int) {
        advanceGeneration()
        let currentGeneration = generation
        let documentLength = max(0, textUTF16Length)

        applicationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            guard await self.clearAppliedRanges(generation: currentGeneration, documentLength: documentLength),
                self.canContinue(generation: currentGeneration, documentLength: documentLength)
            else {
                return
            }

            await self.apply(
                spans: spans,
                generation: currentGeneration,
                documentLength: documentLength
            )

            if self.isCurrent(currentGeneration) {
                self.applicationTask = nil
            }
        }
    }

    func cancelPendingApplication() {
        advanceGeneration()
    }

    func resetForTextReplacement(textUTF16Length: Int) {
        advanceGeneration()
        self.documentUTF16Length = max(0, textUTF16Length)
        appliedRanges.removeAll(keepingCapacity: false)
        nextAppliedRangeToClear = 0
        pauseDeadline = nil
    }

    func pausePendingBatchesBriefly() {
        pauseDeadline = clock.now.advanced(by: Self.maximumInteractionPause)
    }

    private func advanceGeneration() {
        generation &+= 1
        applicationTask?.cancel()
        applicationTask = nil
    }

    private func clearAppliedRanges(
        generation: UInt64,
        documentLength: Int
    ) async -> Bool {
        guard await waitWhilePaused(generation: generation, documentLength: documentLength) else {
            return false
        }

        while nextAppliedRangeToClear < appliedRanges.count {
            guard canContinue(generation: generation, documentLength: documentLength),
                let textView,
                let textStorage = textView.textStorage,
                textStorage.length == documentLength
            else {
                return false
            }

            let batchStart = clock.now
            var writes = 0
            textStorage.beginEditing()

            while nextAppliedRangeToClear < appliedRanges.count,
                writes < Self.maximumWritesPerBatch,
                writes == 0 || batchStart.duration(to: clock.now) < Self.maximumBatchDuration
            {
                let range = appliedRanges[nextAppliedRangeToClear]
                if Self.isValid(range, textUTF16Length: documentLength) {
                    textStorage.addAttribute(
                        .foregroundColor,
                        value: NSColor.textColor,
                        range: range
                    )
                }

                nextAppliedRangeToClear += 1
                writes += 1
            }

            textStorage.endEditing()
            guard await yieldToMainLoop(generation: generation, documentLength: documentLength) else {
                return false
            }
        }

        appliedRanges.removeAll(keepingCapacity: true)
        nextAppliedRangeToClear = 0
        return canContinue(generation: generation, documentLength: documentLength)
    }

    private func apply(
        spans: [SyntaxHighlighting.Span],
        generation: UInt64,
        documentLength: Int
    ) async {
        guard await waitWhilePaused(generation: generation, documentLength: documentLength) else {
            return
        }

        var spanIndex = 0

        while spanIndex < spans.count {
            guard canContinue(generation: generation, documentLength: documentLength),
                let textStorage = textView?.textStorage
            else {
                return
            }

            let batchStart = clock.now
            var writes = 0
            textStorage.beginEditing()

            while spanIndex < spans.count,
                writes < Self.maximumWritesPerBatch,
                writes == 0 || batchStart.duration(to: clock.now) < Self.maximumBatchDuration
            {
                let span = spans[spanIndex]
                let range = span.range
                if Self.isValid(range, textUTF16Length: documentLength) {
                    textStorage.addAttribute(
                        .foregroundColor,
                        value: span.color.appKitColor,
                        range: range
                    )
                    appliedRanges.append(range)
                }

                spanIndex += 1
                writes += 1
            }

            textStorage.endEditing()
            guard await yieldToMainLoop(generation: generation, documentLength: documentLength) else {
                return
            }
        }
    }

    private func yieldToMainLoop(generation: UInt64, documentLength: Int) async -> Bool {
        do {
            try await Task.sleep(for: Self.batchYieldInterval)
        } catch {
            return false
        }

        return await waitWhilePaused(generation: generation, documentLength: documentLength)
    }

    private func waitWhilePaused(generation: UInt64, documentLength: Int) async -> Bool {
        guard canContinue(generation: generation, documentLength: documentLength) else {
            return false
        }

        while let pauseDeadline, clock.now < pauseDeadline {
            let remainingPause = clock.now.duration(to: pauseDeadline)
            do {
                try await Task.sleep(for: min(remainingPause, Self.batchYieldInterval))
            } catch {
                return false
            }

            guard canContinue(generation: generation, documentLength: documentLength) else {
                return false
            }
        }

        self.pauseDeadline = nil
        return true
    }

    private func canContinue(generation: UInt64, documentLength: Int) -> Bool {
        guard isCurrent(generation),
            let textView,
            let textStorage = textView.textStorage
        else {
            return false
        }

        return self.documentUTF16Length == documentLength
            && textStorage.length == documentLength
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == self.generation
    }

    private static func isValid(_ range: NSRange, textUTF16Length: Int) -> Bool {
        range.location >= 0
            && range.length > 0
            && range.location <= textUTF16Length
            && range.length <= textUTF16Length - range.location
    }
}
