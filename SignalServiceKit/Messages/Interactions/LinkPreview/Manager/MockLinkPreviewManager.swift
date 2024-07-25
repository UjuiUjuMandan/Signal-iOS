//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

#if TESTABLE_BUILD

public class MockLinkPreviewManager: LinkPreviewManager {

    public init() {}

    public var areLinkPreviewsEnabledMock = true

    public func areLinkPreviewsEnabled(tx: DBReadTransaction) -> Bool {
        return areLinkPreviewsEnabledMock
    }

    public var fetchedURLs = [URL]()

    public var fetchLinkPreviewBlock: ((URL) async throws -> OWSLinkPreviewDraft)?

    public func fetchLinkPreview(for url: URL) async throws -> OWSLinkPreviewDraft {
        fetchedURLs.append(url)
        return try await fetchLinkPreviewBlock!(url)
    }

    public func validateAndBuildLinkPreview(
        from proto: SSKProtoPreview,
        dataMessage: SSKProtoDataMessage,
        ownerType: TSResourceOwnerType,
        tx: DBWriteTransaction
    ) throws -> OwnedAttachmentBuilder<OWSLinkPreview> {
        return .withoutFinalizer(.init())
    }

    public func validateAndBuildLinkPreview<Builder: LinkPreviewBuilder>(
        from proto: SSKProtoPreview,
        dataMessage: SSKProtoDataMessage,
        builder: Builder,
        ownerType: TSResourceOwnerType,
        tx: DBWriteTransaction
    ) throws -> OwnedAttachmentBuilder<OWSLinkPreview> {
        return .withoutFinalizer(.init())
    }

    public func validateAndBuildStoryLinkPreview(
        from proto: SSKProtoPreview,
        tx: DBWriteTransaction
    ) throws -> OwnedAttachmentBuilder<OWSLinkPreview> {
        return .withoutFinalizer(.init())
    }

    public func buildDataSource(
        from draft: OWSLinkPreviewDraft,
        ownerType: TSResourceOwnerType
    ) throws -> LinkPreviewTSResourceDataSource {
        return .init(
            metadata: .init(
                urlString: draft.urlString,
                title: draft.title,
                previewDescription: draft.previewDescription,
                date: draft.date
            ),
            imageV2DataSource: nil,
            imageLegacyDataSource: nil
        )
    }

    public func buildDataSource<Builder: LinkPreviewBuilder>(
        from draft: OWSLinkPreviewDraft,
        builder: Builder,
        ownerType: TSResourceOwnerType
    ) throws -> Builder.DataSource {
        return try builder.buildDataSource(draft, ownerType: ownerType)
    }

    public func buildLinkPreview(
        from dataSource: LinkPreviewTSResourceDataSource,
        ownerType: TSResourceOwnerType,
        tx: DBWriteTransaction
    ) throws -> OwnedAttachmentBuilder<OWSLinkPreview> {
        return .withoutFinalizer(.init())
    }

    public func buildLinkPreview<Builder: LinkPreviewBuilder>(
        from dataSource: Builder.DataSource,
        builder: Builder,
        ownerType: TSResourceOwnerType,
        tx: DBWriteTransaction
    ) throws -> OwnedAttachmentBuilder<OWSLinkPreview> {
        return .withoutFinalizer(.init())
    }

    public func buildProtoForSending(
        _ linkPreview: OWSLinkPreview,
        parentMessage: TSMessage,
        tx: DBReadTransaction
    ) throws -> SSKProtoPreview {
        return SSKProtoPreview.builder(url: linkPreview.urlString!).buildIgnoringErrors()!
    }

    public func buildProtoForSending(
        _ linkPreview: OWSLinkPreview,
        parentStoryMessage: StoryMessage,
        tx: DBReadTransaction
    ) throws -> SSKProtoPreview {
        return SSKProtoPreview.builder(url: linkPreview.urlString!).buildIgnoringErrors()!
    }
}

#endif
