import Foundation

/// Produces a complete immutable rename plan without reading or mutating the filesystem.
nonisolated struct RenamePlanningService: Sendable {
    private static let portableForbiddenCharacters = CharacterSet(
        charactersIn: "/\\:?%*|\"<>"
    ).union(.controlCharacters)

    private let renderer: BatchRenameRecipeRenderer

    init(renderer: BatchRenameRecipeRenderer = BatchRenameRecipeRenderer()) {
        self.renderer = renderer
    }

    func makePlan(
        items: [RenamePlanningItem],
        recipe: BatchRenameRecipe,
        collisionPolicy: RenameCollisionPolicy = .block,
        artifactRegistry: RenameArtifactRegistry = .standard,
        environment: RenamePlanningEnvironment
    ) -> RenamePlan {
        let evaluations = items.enumerated().map { itemIndex, item in
            var context = item.context
            context.sequenceIndex = itemIndex
            context.originalFilename = item.sourceImageURL.lastPathComponent
            return renderer.evaluate(recipe, context: context)
        }
        let initiallyVacatingItemIndexes = Set(items.indices.filter { index in
            let evaluation = evaluations[index]
            guard evaluation.disposition == .rename,
                  let destinationFilename = evaluation.proposedFilename,
                  invalidFilenameReason(destinationFilename) == nil
            else { return false }
            let destination = items[index].sourceImageURL.deletingLastPathComponent()
                .appendingPathComponent(destinationFilename)
            return normalizedPath(destination) != normalizedPath(items[index].sourceImageURL)
        })
        let nonVacatingImageURLs = items.indices.compactMap { index in
            initiallyVacatingItemIndexes.contains(index) ? nil : items[index].sourceImageURL
        }
        let snapshot = PathSnapshot(
            environment: environment,
            requiredExistingImageURLs: nonVacatingImageURLs
        )
        // Artifact sources owned by a moving item are vacatable just like the image itself. This
        // is what allows A↔B swaps (and longer cycles) to include XMP/JSON/custom artifacts.
        var vacatableSourceKeys: Set<String> = []
        for index in initiallyVacatingItemIndexes.sorted() {
            guard let destinationFilename = evaluations[index].proposedFilename else { continue }
            let actions = artifactActions(
                for: items[index].sourceImageURL,
                destinationFilename: destinationFilename,
                registry: artifactRegistry,
                explicitlyAssociated: items[index].associatedArtifacts,
                snapshot: snapshot,
                originalFilenameMetadata: recipe.originalFilenameMetadata
            )
            for action in actions {
                vacatableSourceKeys.insert(pathKey(
                    action.sourceURL,
                    caseSensitivity: environment.caseSensitivity
                ))
            }
        }
        var reservations: [String: Reservation] = [:]
        var reservedURLs: [URL] = []
        var entries: [RenamePlanEntry] = []
        entries.reserveCapacity(items.count)

        for (itemIndex, item) in items.enumerated() {
            // The caller's array is already in visible order; evaluations above assigned its
            // zero-based position as the authoritative sequence number.
            let evaluation = evaluations[itemIndex]
            var itemIssues = missingValueIssues(
                evaluation,
                recipe: recipe,
                itemIndex: itemIndex
            )

            if !evaluation.problems.isEmpty {
                itemIssues += evaluation.problems.map {
                    RenamePlanIssue(
                        severity: .blocking,
                        itemIndex: itemIndex,
                        artifactIdentifier: nil,
                        url: nil,
                        code: .recipeProblem($0)
                    )
                }
            }

            switch evaluation.disposition {
            case .block:
                entries.append(RenamePlanEntry(
                    itemIndex: itemIndex,
                    sourceImageURL: item.sourceImageURL,
                    requestedDestinationImageURL: nil,
                    plannedDestinationImageURL: nil,
                    disposition: .blocked,
                    recipeEvaluation: evaluation,
                    requestedArtifactActions: [],
                    plannedArtifactActions: [],
                    issues: itemIssues
                ))
                continue
            case .skip:
                entries.append(RenamePlanEntry(
                    itemIndex: itemIndex,
                    sourceImageURL: item.sourceImageURL,
                    requestedDestinationImageURL: nil,
                    plannedDestinationImageURL: nil,
                    disposition: .skipped,
                    recipeEvaluation: evaluation,
                    requestedArtifactActions: [],
                    plannedArtifactActions: [],
                    issues: itemIssues
                ))
                continue
            case .rename, .preserveOriginal:
                break
            }

            guard let requestedName = evaluation.proposedFilename else {
                let issue = RenamePlanIssue(
                    severity: .blocking,
                    itemIndex: itemIndex,
                    artifactIdentifier: "image",
                    url: nil,
                    code: .invalidFilename(.empty)
                )
                itemIssues.append(issue)
                entries.append(RenamePlanEntry(
                    itemIndex: itemIndex,
                    sourceImageURL: item.sourceImageURL,
                    requestedDestinationImageURL: nil,
                    plannedDestinationImageURL: nil,
                    disposition: .blocked,
                    recipeEvaluation: evaluation,
                    requestedArtifactActions: [],
                    plannedArtifactActions: [],
                    issues: itemIssues
                ))
                continue
            }

            let sourceFolder = item.sourceImageURL.deletingLastPathComponent()
            let requestedImageURL = sourceFolder.appendingPathComponent(requestedName)
            if let invalidReason = invalidFilenameReason(requestedName) {
                itemIssues.append(RenamePlanIssue(
                    severity: .blocking,
                    itemIndex: itemIndex,
                    artifactIdentifier: "image",
                    url: requestedImageURL,
                    code: .invalidFilename(invalidReason)
                ))
                entries.append(RenamePlanEntry(
                    itemIndex: itemIndex,
                    sourceImageURL: item.sourceImageURL,
                    requestedDestinationImageURL: requestedImageURL,
                    plannedDestinationImageURL: nil,
                    disposition: .blocked,
                    recipeEvaluation: evaluation,
                    requestedArtifactActions: [],
                    plannedArtifactActions: [],
                    issues: itemIssues
                ))
                continue
            }

            if SupportedImageFormats.isSupported(url: item.sourceImageURL),
               !SupportedImageFormats.isSupported(url: requestedImageURL) {
                itemIssues.append(RenamePlanIssue(
                    severity: .warning,
                    itemIndex: itemIndex,
                    artifactIdentifier: "image",
                    url: requestedImageURL,
                    code: .unrecognizedImageExtension
                ))
            }

            let requestedActions = artifactActions(
                for: item.sourceImageURL,
                destinationFilename: requestedName,
                registry: artifactRegistry,
                explicitlyAssociated: item.associatedArtifacts,
                snapshot: snapshot,
                originalFilenameMetadata: recipe.originalFilenameMetadata
            )
            if recipe.originalFilenameMetadata == .preserveInXMP,
               SupportedImageFormats.isRaw(url: item.sourceImageURL),
               !requestedActions.contains(where: { $0.originalFilenameMetadataMutation != nil }) {
                itemIssues.append(RenamePlanIssue(
                    severity: .blocking,
                    itemIndex: itemIndex,
                    artifactIdentifier: "xmp",
                    url: item.sourceImageURL.deletingPathExtension().appendingPathExtension("xmp"),
                    code: .originalFilenameXMPSidecarMissing
                ))
            }

            let initialCheck = collisionCheck(
                actions: requestedActions,
                itemIndex: itemIndex,
                reservations: reservations,
                snapshot: snapshot,
                vacatableSourceKeys: vacatableSourceKeys
            )

            if initialCheck.conflicts.isEmpty {
                let disposition: RenamePlanEntryDisposition = requestedActions.contains(where: \.changesPath)
                    ? .rename
                    : .unchanged
                reserve(
                    requestedActions,
                    itemIndex: itemIndex,
                    reservations: &reservations,
                    reservedURLs: &reservedURLs,
                    caseSensitivity: environment.caseSensitivity
                )
                itemIssues += initialCheck.caseOnlyWarnings
                entries.append(RenamePlanEntry(
                    itemIndex: itemIndex,
                    sourceImageURL: item.sourceImageURL,
                    requestedDestinationImageURL: requestedImageURL,
                    plannedDestinationImageURL: requestedImageURL,
                    disposition: disposition,
                    recipeEvaluation: evaluation,
                    requestedArtifactActions: requestedActions,
                    plannedArtifactActions: requestedActions,
                    issues: itemIssues
                ))
                continue
            }

            // Preserve-original is an explicit promise not to alter this item. It must never be
            // silently converted into a suffixed rename even when that is the batch policy.
            let effectivePolicy: RenameCollisionPolicy = evaluation.disposition == .preserveOriginal
                ? .block
                : collisionPolicy

            switch effectivePolicy {
            case .block:
                itemIssues += initialCheck.conflicts.map { $0.withSeverity(.blocking) }
                entries.append(RenamePlanEntry(
                    itemIndex: itemIndex,
                    sourceImageURL: item.sourceImageURL,
                    requestedDestinationImageURL: requestedImageURL,
                    plannedDestinationImageURL: nil,
                    disposition: .blocked,
                    recipeEvaluation: evaluation,
                    requestedArtifactActions: requestedActions,
                    plannedArtifactActions: [],
                    issues: itemIssues
                ))
            case .skip:
                itemIssues += initialCheck.conflicts.map { $0.withSeverity(.warning) }
                entries.append(RenamePlanEntry(
                    itemIndex: itemIndex,
                    sourceImageURL: item.sourceImageURL,
                    requestedDestinationImageURL: requestedImageURL,
                    plannedDestinationImageURL: nil,
                    disposition: .skipped,
                    recipeEvaluation: evaluation,
                    requestedArtifactActions: requestedActions,
                    plannedArtifactActions: [],
                    issues: itemIssues
                ))
            case let .appendDeterministicSuffix(separator, startAt, maximumAttempts):
                let firstAttempt = max(1, startAt)
                let attemptLimit = max(0, maximumAttempts)
                var resolved: (name: String, actions: [RenameArtifactAction], attempt: Int, warnings: [RenamePlanIssue])?
                if attemptLimit > 0 {
                    for offset in 0..<attemptLimit {
                        let attempt = firstAttempt + offset
                        let candidateName = appendingSuffix(
                            to: requestedName,
                            separator: separator,
                            number: attempt
                        )
                        guard invalidFilenameReason(candidateName) == nil else { continue }
                        let actions = artifactActions(
                            for: item.sourceImageURL,
                            destinationFilename: candidateName,
                            registry: artifactRegistry,
                            explicitlyAssociated: item.associatedArtifacts,
                            snapshot: snapshot,
                            originalFilenameMetadata: recipe.originalFilenameMetadata
                        )
                        let check = collisionCheck(
                            actions: actions,
                            itemIndex: itemIndex,
                            reservations: reservations,
                            snapshot: snapshot,
                            vacatableSourceKeys: vacatableSourceKeys
                        )
                        if check.conflicts.isEmpty {
                            resolved = (candidateName, actions, attempt, check.caseOnlyWarnings)
                            break
                        }
                    }
                }

                if let resolved {
                    let resolvedImageURL = sourceFolder.appendingPathComponent(resolved.name)
                    itemIssues += initialCheck.conflicts.map { $0.withSeverity(.warning) }
                    itemIssues.append(RenamePlanIssue(
                        severity: .warning,
                        itemIndex: itemIndex,
                        artifactIdentifier: "image",
                        url: resolvedImageURL,
                        code: .deterministicSuffixApplied(
                            attempt: resolved.attempt,
                            requestedName: requestedName,
                            resolvedName: resolved.name
                        )
                    ))
                    itemIssues += resolved.warnings
                    reserve(
                        resolved.actions,
                        itemIndex: itemIndex,
                        reservations: &reservations,
                        reservedURLs: &reservedURLs,
                        caseSensitivity: environment.caseSensitivity
                    )
                    entries.append(RenamePlanEntry(
                        itemIndex: itemIndex,
                        sourceImageURL: item.sourceImageURL,
                        requestedDestinationImageURL: requestedImageURL,
                        plannedDestinationImageURL: resolvedImageURL,
                        disposition: .rename,
                        recipeEvaluation: evaluation,
                        requestedArtifactActions: requestedActions,
                        plannedArtifactActions: resolved.actions,
                        issues: itemIssues
                    ))
                } else {
                    itemIssues += initialCheck.conflicts.map { $0.withSeverity(.blocking) }
                    itemIssues.append(RenamePlanIssue(
                        severity: .blocking,
                        itemIndex: itemIndex,
                        artifactIdentifier: "image",
                        url: requestedImageURL,
                        code: .deterministicSuffixExhausted(maximumAttempts: attemptLimit)
                    ))
                    entries.append(RenamePlanEntry(
                        itemIndex: itemIndex,
                        sourceImageURL: item.sourceImageURL,
                        requestedDestinationImageURL: requestedImageURL,
                        plannedDestinationImageURL: nil,
                        disposition: .blocked,
                        recipeEvaluation: evaluation,
                        requestedArtifactActions: requestedActions,
                        plannedArtifactActions: [],
                        issues: itemIssues
                    ))
                }
            }
        }

        entries = enforcingAcceptedSourceDependencies(
            entries: entries,
            items: items,
            caseSensitivity: environment.caseSensitivity
        )
        // Rebuild from accepted entries after dependency validation. A blocked dependent may have
        // tentatively reserved paths during the first pass; none of those may reach execution.
        reservedURLs = reservedDestinations(
            entries: entries,
            caseSensitivity: environment.caseSensitivity
        )
        let allIssues = entries.flatMap(\.issues)
        return RenamePlan(
            entries: entries,
            reservedDestinationURLs: reservedURLs,
            issues: allIssues,
            associatedArtifactSummary: artifactSummary(
                entries: entries,
                registry: artifactRegistry,
                items: items
            )
        )
    }

    private func missingValueIssues(
        _ evaluation: BatchRenameEvaluation,
        recipe: BatchRenameRecipe,
        itemIndex: Int
    ) -> [RenamePlanIssue] {
        let resolution: RenameMissingValueResolution
        let severity: RenamePlanIssue.Severity
        switch recipe.missingValuePolicy {
        case .empty:
            resolution = .empty
            severity = .warning
        case let .fallback(value):
            resolution = .fallback(value)
            severity = .warning
        case .preserveOriginal:
            resolution = .preserveOriginal
            severity = .warning
        case .skip:
            resolution = .skip
            severity = .warning
        case .block:
            resolution = .block
            severity = .blocking
        }
        return evaluation.missingValues.map {
            RenamePlanIssue(
                severity: severity,
                itemIndex: itemIndex,
                artifactIdentifier: nil,
                url: nil,
                code: .missingValue(
                    componentIndex: $0.componentIndex,
                    token: $0.token,
                    resolution: resolution
                )
            )
        }
    }

    private func artifactActions(
        for sourceImageURL: URL,
        destinationFilename: String,
        registry: RenameArtifactRegistry,
        explicitlyAssociated: [RenamePlanningAssociatedArtifact],
        snapshot: PathSnapshot,
        originalFilenameMetadata: BatchRenameOriginalFilenameMetadataPolicy
    ) -> [RenameArtifactAction] {
        var rules = registry.rules
        if !rules.contains(where: { $0.role == .image }) {
            rules.insert(RenameArtifactRegistry.standard.rules[0], at: 0)
        }
        let sourceFilename = sourceImageURL.lastPathComponent
        let root = sourceImageURL.deletingLastPathComponent()
        let derivedActions: [RenameArtifactAction] = rules.compactMap { rule in
            let directory = rule.relativeDirectoryComponents.reduce(root) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            let sourceCandidate = directory.appendingPathComponent(filename(
                from: sourceFilename,
                pattern: rule.filenamePattern
            ))
            let destination = directory.appendingPathComponent(filename(
                from: destinationFilename,
                pattern: rule.filenamePattern
            ))

            let source: URL
            if rule.role == .image {
                source = sourceImageURL
            } else {
                switch rule.presence {
                case .always:
                    source = sourceCandidate
                case .whenSourceExists:
                    guard let existing = snapshot.existingURL(matching: sourceCandidate) else {
                        return nil
                    }
                    source = existing
                }
            }
            let mutation: RenameOriginalFilenameMetadataMutation?
            if originalFilenameMetadata == .preserveInXMP {
                if SupportedImageFormats.isRaw(url: sourceImageURL) {
                    mutation = rule.identifier == "xmp"
                        ? RenameOriginalFilenameMetadataMutation(
                            storage: .xmpSidecar,
                            value: sourceImageURL.lastPathComponent
                        )
                        : nil
                } else {
                    mutation = rule.role == .image
                        ? RenameOriginalFilenameMetadataMutation(
                            storage: .embeddedImageXMP,
                            value: sourceImageURL.lastPathComponent
                        )
                        : nil
                }
            } else {
                mutation = nil
            }
            return RenameArtifactAction(
                identifier: rule.identifier,
                displayName: rule.displayName,
                role: rule.role,
                sourceURL: source,
                destinationURL: destination,
                originalFilenameMetadataMutation: mutation
            )
        }

        let explicitActions = explicitlyAssociated.map { artifact in
            RenameArtifactAction(
                identifier: artifact.identifier,
                displayName: artifact.displayName,
                role: .associated,
                sourceURL: artifact.sourceURL,
                destinationURL: artifact.sourceURL.deletingLastPathComponent()
                    .appendingPathComponent(filename(
                        from: destinationFilename,
                        pattern: artifact.filenamePattern
                    )),
                originalFilenameMetadataMutation: nil
            )
        }
        return derivedActions + explicitActions
    }

    private func filename(
        from imageFilename: String,
        pattern: RenameArtifactFilenamePattern
    ) -> String {
        let basis: String
        switch pattern.basis {
        case .fullFilename:
            basis = imageFilename
        case .stem:
            basis = (imageFilename as NSString).deletingPathExtension
        }
        return pattern.prefix + basis + pattern.suffix
    }

    private struct CollisionCheck {
        let conflicts: [RenamePlanIssue]
        let caseOnlyWarnings: [RenamePlanIssue]
    }

    private func collisionCheck(
        actions: [RenameArtifactAction],
        itemIndex: Int,
        reservations: [String: Reservation],
        snapshot: PathSnapshot,
        vacatableSourceKeys: Set<String>
    ) -> CollisionCheck {
        var conflicts: [RenamePlanIssue] = []
        var warnings: [RenamePlanIssue] = []
        var candidateKeys: [String: RenameArtifactAction] = [:]

        for action in actions {
            let key = pathKey(action.destinationURL, caseSensitivity: snapshot.caseSensitivity)
            if let other = candidateKeys[key] {
                let exact = normalizedPath(other.destinationURL) == normalizedPath(action.destinationURL)
                conflicts.append(RenamePlanIssue(
                    severity: .blocking,
                    itemIndex: itemIndex,
                    artifactIdentifier: action.identifier,
                    url: action.destinationURL,
                    code: exact
                        ? .duplicateTarget(
                            otherItemIndex: itemIndex,
                            otherArtifactIdentifier: other.identifier
                        )
                        : .caseInsensitiveCollision(existingURL: other.destinationURL)
                ))
                continue
            }
            candidateKeys[key] = action

            if let reserved = reservations[key] {
                let exact = normalizedPath(reserved.url) == normalizedPath(action.destinationURL)
                conflicts.append(RenamePlanIssue(
                    severity: .blocking,
                    itemIndex: itemIndex,
                    artifactIdentifier: action.identifier,
                    url: action.destinationURL,
                    code: exact
                        ? .duplicateTarget(
                            otherItemIndex: reserved.itemIndex,
                            otherArtifactIdentifier: reserved.artifactIdentifier
                        )
                        : .caseInsensitiveCollision(existingURL: reserved.url)
                ))
                continue
            }

            let sourcePath = normalizedPath(action.sourceURL)
            let matchingExisting = snapshot.existingURLs(matching: action.destinationURL)
            let destinationIsVacated = vacatableSourceKeys.contains(key)
            let otherExisting = matchingExisting.filter {
                normalizedPath($0) != sourcePath && !destinationIsVacated
            }
            if let existing = otherExisting.first {
                let exact = normalizedPath(existing) == normalizedPath(action.destinationURL)
                conflicts.append(RenamePlanIssue(
                    severity: .blocking,
                    itemIndex: itemIndex,
                    artifactIdentifier: action.identifier,
                    url: action.destinationURL,
                    code: exact
                        ? .existingDestination(existingURL: existing)
                        : .caseInsensitiveCollision(existingURL: existing)
                ))
                continue
            }

            if snapshot.caseSensitivity == .caseInsensitive,
               sourcePath != normalizedPath(action.destinationURL),
               pathKey(action.sourceURL, caseSensitivity: .caseInsensitive) == key {
                warnings.append(RenamePlanIssue(
                    severity: .warning,
                    itemIndex: itemIndex,
                    artifactIdentifier: action.identifier,
                    url: action.destinationURL,
                    code: .caseOnlyRename
                ))
            }
        }
        return CollisionCheck(conflicts: conflicts, caseOnlyWarnings: warnings)
    }

    private func reserve(
        _ actions: [RenameArtifactAction],
        itemIndex: Int,
        reservations: inout [String: Reservation],
        reservedURLs: inout [URL],
        caseSensitivity: RenamePathCaseSensitivity
    ) {
        for action in actions {
            let key = pathKey(action.destinationURL, caseSensitivity: caseSensitivity)
            guard reservations[key] == nil else { continue }
            reservations[key] = Reservation(
                itemIndex: itemIndex,
                artifactIdentifier: action.identifier,
                url: action.destinationURL
            )
            reservedURLs.append(action.destinationURL)
        }
    }

    private func appendingSuffix(to filename: String, separator: String, number: Int) -> String {
        let nsFilename = filename as NSString
        let stem = nsFilename.deletingPathExtension
        let pathExtension = nsFilename.pathExtension
        let suffixedStem = stem + separator + String(number)
        guard !pathExtension.isEmpty else { return suffixedStem }
        return suffixedStem + "." + pathExtension
    }

    private func invalidFilenameReason(_ filename: String) -> RenameInvalidFilenameReason? {
        if filename.isEmpty || filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .empty
        }
        if filename == "." || filename == ".." { return .dotPathComponent }
        if filename.unicodeScalars.contains(where: { Self.portableForbiddenCharacters.contains($0) }) {
            return .forbiddenCharacter
        }
        if filename.last == "." || filename.last?.isWhitespace == true {
            return .trailingSpaceOrPeriod
        }
        if filename.utf8.count > 255 { return .exceedsFilesystemByteLimit }
        return nil
    }

    private func artifactSummary(
        entries: [RenamePlanEntry],
        registry: RenameArtifactRegistry,
        items: [RenamePlanningItem]
    ) -> [RenameArtifactSummary] {
        var descriptors = registry.rules.filter { $0.role == .associated }.map {
            (identifier: $0.identifier, displayName: $0.displayName)
        }
        for artifact in items.flatMap(\.associatedArtifacts) where
            !descriptors.contains(where: { $0.identifier == artifact.identifier }) {
            descriptors.append((artifact.identifier, artifact.displayName))
        }
        return descriptors.compactMap { descriptor in
            let actions = entries.flatMap(\.plannedArtifactActions).filter {
                $0.identifier == descriptor.identifier
            }
            guard !actions.isEmpty else { return nil }
            let renamed = actions.filter(\.changesPath).count
            return RenameArtifactSummary(
                identifier: descriptor.identifier,
                displayName: descriptor.displayName,
                presentCount: actions.count,
                renamedCount: renamed,
                unchangedCount: actions.count - renamed
            )
        }
    }

    /// The pre-pass deliberately over-approximates vacatable sources so cycles can be discovered.
    /// This fixed-point audit tightens that set to entries actually accepted as moves. If an
    /// intended mover was skipped or blocked, every accepted entry depending on its source is
    /// blocked as well; execution can therefore never overwrite a newly-stationary source.
    private func enforcingAcceptedSourceDependencies(
        entries initialEntries: [RenamePlanEntry],
        items: [RenamePlanningItem],
        caseSensitivity: RenamePathCaseSensitivity
    ) -> [RenamePlanEntry] {
        struct OwnedSource {
            let itemIndex: Int
            let artifactIdentifier: String
            let url: URL
        }

        var ownedSources: [String: [OwnedSource]] = [:]
        for (index, item) in items.enumerated() {
            let source = OwnedSource(itemIndex: index, artifactIdentifier: "image", url: item.sourceImageURL)
            ownedSources[pathKey(item.sourceImageURL, caseSensitivity: caseSensitivity), default: []]
                .append(source)
        }
        for entry in initialEntries {
            for action in entry.requestedArtifactActions where action.role == .associated {
                let source = OwnedSource(
                    itemIndex: entry.itemIndex,
                    artifactIdentifier: action.identifier,
                    url: action.sourceURL
                )
                let key = pathKey(action.sourceURL, caseSensitivity: caseSensitivity)
                if ownedSources[key]?.contains(where: {
                    $0.itemIndex == source.itemIndex &&
                        $0.artifactIdentifier == source.artifactIdentifier &&
                        normalizedPath($0.url) == normalizedPath(source.url)
                }) != true {
                    ownedSources[key, default: []].append(source)
                }
            }
        }

        var entries = initialEntries
        var changed = true
        while changed {
            changed = false
            let acceptedMovingItems = Set(entries.compactMap { entry -> Int? in
                guard entry.disposition == .rename,
                      let destination = entry.plannedDestinationImageURL,
                      normalizedPath(destination) != normalizedPath(entry.sourceImageURL)
                else { return nil }
                return entry.itemIndex
            })

            for index in entries.indices {
                let entry = entries[index]
                guard entry.disposition == .rename || entry.disposition == .unchanged else { continue }

                var dependency: OwnedSource?
                for action in entry.plannedArtifactActions {
                    let key = pathKey(action.destinationURL, caseSensitivity: caseSensitivity)
                    guard let owners = ownedSources[key] else { continue }
                    dependency = owners.first(where: { owner in
                        owner.itemIndex != entry.itemIndex &&
                            !acceptedMovingItems.contains(owner.itemIndex)
                    })
                    if dependency != nil { break }
                }
                guard let dependency else { continue }

                let issue = RenamePlanIssue(
                    severity: .blocking,
                    itemIndex: entry.itemIndex,
                    artifactIdentifier: dependency.artifactIdentifier,
                    url: dependency.url,
                    code: .existingDestination(existingURL: dependency.url)
                )
                entries[index] = RenamePlanEntry(
                    itemIndex: entry.itemIndex,
                    sourceImageURL: entry.sourceImageURL,
                    requestedDestinationImageURL: entry.requestedDestinationImageURL,
                    plannedDestinationImageURL: nil,
                    disposition: .blocked,
                    recipeEvaluation: entry.recipeEvaluation,
                    requestedArtifactActions: entry.requestedArtifactActions,
                    plannedArtifactActions: [],
                    issues: entry.issues + [issue]
                )
                changed = true
            }
        }
        return entries
    }

    private func reservedDestinations(
        entries: [RenamePlanEntry],
        caseSensitivity: RenamePathCaseSensitivity
    ) -> [URL] {
        var keys: Set<String> = []
        var result: [URL] = []
        for action in entries.flatMap(\.plannedArtifactActions) {
            let key = pathKey(action.destinationURL, caseSensitivity: caseSensitivity)
            if keys.insert(key).inserted { result.append(action.destinationURL) }
        }
        return result
    }

    private struct Reservation {
        let itemIndex: Int
        let artifactIdentifier: String
        let url: URL
    }

    private struct PathSnapshot {
        let caseSensitivity: RenamePathCaseSensitivity
        private let pathsByKey: [String: [URL]]

        init(environment: RenamePlanningEnvironment, requiredExistingImageURLs: [URL]) {
            caseSensitivity = environment.caseSensitivity
            var paths = Array(environment.existingURLs) + requiredExistingImageURLs
            paths.sort { normalizedPath($0) < normalizedPath($1) }
            var grouped: [String: [URL]] = [:]
            for url in paths {
                let key = pathKey(url, caseSensitivity: environment.caseSensitivity)
                if grouped[key]?.contains(where: { normalizedPath($0) == normalizedPath(url) }) != true {
                    grouped[key, default: []].append(url)
                }
            }
            pathsByKey = grouped
        }

        func existingURL(matching url: URL) -> URL? {
            existingURLs(matching: url).first
        }

        func existingURLs(matching url: URL) -> [URL] {
            pathsByKey[pathKey(url, caseSensitivity: caseSensitivity)] ?? []
        }
    }
}

private nonisolated func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
}

private nonisolated func pathKey(
    _ url: URL,
    caseSensitivity: RenamePathCaseSensitivity
) -> String {
    let path = normalizedPath(url)
    switch caseSensitivity {
    case .caseSensitive: return path
    case .caseInsensitive: return path.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

private extension RenamePlanIssue {
    nonisolated func withSeverity(_ severity: Severity) -> Self {
        Self(
            severity: severity,
            itemIndex: itemIndex,
            artifactIdentifier: artifactIdentifier,
            url: url,
            code: code
        )
    }
}
