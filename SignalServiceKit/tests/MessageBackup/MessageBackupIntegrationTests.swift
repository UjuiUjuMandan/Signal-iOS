//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

class MessageBackupIntegrationTests: XCTestCase {
    override func setUp() {
        DDLog.add(DDTTYLogger.sharedInstance!)
    }

    // MARK: -

    /// Describes what output to log if LibSignal reports a test failure.
    private enum LibSignalComparisonFailureLogOutput {
        /// Log the full backup JSONs returned by LibSignal, for external
        /// analysis via `parse-libsignal-comparator-failure.py`.
        case fullLibSignalJSON

        /// Log a minimal diff of the backup JSONs returned by LibSignal, for
        /// inline analysis in the Xcode logs.
        case minimalDiff
    }

    /// The preferred log output for test failures.
    ///
    /// Set by default to `.minimalDiff` to reduce log noise in automated test
    /// runs. Toggle to `.fullLibSignalJSON` if desired during local
    /// development, for more thorough inspection of the failure case.
    private let preferredFailureLogOutput: LibSignalComparisonFailureLogOutput = .minimalDiff

    // MARK: -

    private enum WhichIntegrationTestCases {
        case specific(names: [String])
        case all
    }

    /// Specifies which integration test cases to run.
    ///
    /// Set by default to `.all`. Toggle to `.specific` during local development
    /// to run only on a subset of test cases, for debugging purposes.
    private let whichIntegrationTestCases: WhichIntegrationTestCases = .all

    // MARK: -

    /// Performs a round-trip import/export test on all `.binproto` integration
    /// test cases.
    func testAllIntegrationTestCases() async throws {
        let binProtoFileUrls: [URL] = {
            let bundle = Bundle(for: type(of: self))

            switch whichIntegrationTestCases {
            case .specific(let names):
                return names.compactMap { name in
                    return bundle.url(
                        forResource: name,
                        withExtension: "binproto"
                    )
                }
            case .all:
                return Bundle(for: type(of: self)).urls(
                    forResourcesWithExtension: "binproto",
                    subdirectory: nil
                ) ?? []
            }
        }()

        guard binProtoFileUrls.count > 0 else {
            XCTFail("Failed to find binprotos in test bundle!")
            return
        }

        for binprotoFileUrl in binProtoFileUrls {
            let filename = binprotoFileUrl
                .lastPathComponent
                .filenameWithoutExtension

            do {
                try await runRoundTripTest(
                    testCaseFileUrl: binprotoFileUrl,
                    failureLogOutput: preferredFailureLogOutput
                )
            } catch TestError.failure(let message) {
                XCTFail("""

                ------------

                Test case failed: \(filename)!

                \(message)

                ------------
                """)
            } catch let error {
                XCTFail("""

                ------------

                Test case failed with unexpected error: \(filename)!

                \(error)

                ------------
                """)
            }
        }
    }

    // MARK: -

    private enum TestError: Error {
        case failure(String)
    }

    private var deps: DependenciesBridge { .shared }

    /// Runs a round-trip import/export test for the given `.binproto` file.
    ///
    /// The round-trip test imports the given `.binproto` into an empty app,
    /// then exports the app's state into another `.binproto`. The
    /// originally-imported and recently-exported `.binprotos` are then compared
    /// by LibSignal. They should be equivalent; any disparity indicates that
    /// some data was dropped or modified as part of the import/export process,
    /// which should be idempotent.
    private func runRoundTripTest(
        testCaseFileUrl: URL,
        failureLogOutput: LibSignalComparisonFailureLogOutput
    ) async throws {
        /// A backup doesn't contain our own local identifiers. Rather, those
        /// are determined as part of registration for a backup import, and are
        /// already-known for a backup export.
        ///
        /// Consequently, we can use any local identifiers for our test
        /// purposes without worrying about the contents of each test case's
        /// backup file.
        let localIdentifiers: LocalIdentifiers = .forUnitTests

        /// Backup files hardcode timestamps, some of which are interpreted
        /// relative to "now". For example, "deleted" story distribution lists
        /// are marked as deleted for a period of time before being actually
        /// deleted; when these frames are restored from a Backup, their
        /// deletion timestamp is compared to "now" to determine if they should
        /// be deleted.
        ///
        /// Consequently, in order for tests to remain stable over time we need
        /// to "anchor" them with an unchanging timestamp. To that end, we'll
        /// extract the `backupTimeMs` field from the Backup header, and use
        /// that as our "now" during import.
        let backupTimeMs = try readBackupTimeMs(testCaseFileUrl: testCaseFileUrl)

        await initializeApp(dateProvider: { Date(millisecondsSince1970: backupTimeMs) })

        try await deps.messageBackupManager.importPlaintextBackup(
            fileUrl: testCaseFileUrl,
            localIdentifiers: localIdentifiers
        )

        let exportedBackupUrl = try await deps.messageBackupManager
            .exportPlaintextBackup(localIdentifiers: localIdentifiers)

        try compareViaLibsignal(
            sharedTestCaseBackupUrl: testCaseFileUrl,
            exportedBackupUrl: exportedBackupUrl,
            failureLogOutput: failureLogOutput
        )
    }

    /// Compare the canonical representation of the Backups at the two given
    /// file URLs, via `LibSignal`.
    ///
    /// - Throws
    /// If there are errors reading or validating either Backup, or if the
    /// Backups' canonical representations are not equal.
    private func compareViaLibsignal(
        sharedTestCaseBackupUrl: URL,
        exportedBackupUrl: URL,
        failureLogOutput: LibSignalComparisonFailureLogOutput
    ) throws {
        let sharedTestCaseBackup = try ComparableBackup(url: sharedTestCaseBackupUrl)
        let exportedBackup = try ComparableBackup(url: exportedBackupUrl)

        guard sharedTestCaseBackup.unknownFields.fields.isEmpty else {
            throw TestError.failure("Unknown fields: \(sharedTestCaseBackup.unknownFields)!")
        }

        let sharedTestCaseBackupString = sharedTestCaseBackup.comparableString()
        let exportedBackupString = exportedBackup.comparableString()

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .prettyPrinted

        if sharedTestCaseBackupString != exportedBackupString {
            switch failureLogOutput {
            case .fullLibSignalJSON:
                throw TestError.failure("""
                Copy the JSON lines below and run `pbpaste | parse-libsignal-comparator-failure.py`.

                \(sharedTestCaseBackupString.removeCharacters(characterSet: .whitespacesAndNewlines))
                \(exportedBackupString.removeCharacters(characterSet: .whitespacesAndNewlines))
                """)
            case .minimalDiff:
                let jsonStringDiff: LineByLineStringDiff = .diffing(
                    lhs: sharedTestCaseBackupString,
                    rhs: exportedBackupString
                )

                let prettyDiff = jsonStringDiff.prettyPrint(
                    lhsLabel: "testcase",
                    rhsLabel: "exported",
                    diffGroupDivider: "************"
                )

                throw TestError.failure("""
                JSON diff:

                \(prettyDiff)
                """)
            }
        }
    }

    // MARK: -

    /// Read the `backupTimeMs` field from the header of the Backup file at the
    /// given local URL.
    private func readBackupTimeMs(testCaseFileUrl: URL) throws -> UInt64 {
        let plaintextStreamProvider = MessageBackupPlaintextProtoStreamProviderImpl()

        let stream: MessageBackupProtoInputStream
        switch plaintextStreamProvider.openPlaintextInputFileStream(
            fileUrl: testCaseFileUrl
        ) {
        case .success(let _stream, _):
            stream = _stream
        case .fileNotFound:
            throw TestError.failure("Missing test case backup file!")
        case .unableToOpenFileStream:
            throw TestError.failure("Failed to open test case backup file!")
        case .hmacValidationFailedOnEncryptedFile:
            throw TestError.failure("Impossible – this is a plaintext stream!")
        }

        let backupInfo: BackupProto_BackupInfo
        switch stream.readHeader() {
        case .success(let _backupInfo, _):
            backupInfo = _backupInfo
        case .invalidByteLengthDelimiter:
            throw TestError.failure("Invalid byte length delimiter!")
        case .protoDeserializationError(let error):
            throw TestError.failure("Proto deserialization error: \(error)!")
        }

        return backupInfo.backupTimeMs
    }

    // MARK: -

    @MainActor
    private func initializeApp(dateProvider: DateProvider?) async {
        let testAppContext = TestAppContext()
        SetCurrentAppContext(testAppContext)

        /// Note that ``SDSDatabaseStorage/grdbDatabaseFileUrl``, through a few
        /// layers of abstraction, uses the "current app context" to decide
        /// where to put the database,
        ///
        /// For a ``TestAppContext`` as configured above, this will be a
        /// subdirectory of our temp directory unique to the instantiation of
        /// the app context.
        let databaseStorage = try! SDSDatabaseStorage(
            databaseFileUrl: SDSDatabaseStorage.grdbDatabaseFileUrl,
            keychainStorage: MockKeychainStorage()
        )

        /// We use crashy versions of dependencies that should never be called
        /// during backups, and no-op implementations of payments because those
        /// are bound to the SignalUI target.
        _ = await AppSetup().start(
            appContext: testAppContext,
            databaseStorage: databaseStorage,
            paymentsEvents: PaymentsEventsNoop(),
            mobileCoinHelper: MobileCoinHelperMock(),
            callMessageHandler: CrashyMocks.MockCallMessageHandler(),
            currentCallProvider: CrashyMocks.MockCurrentCallThreadProvider(),
            notificationPresenter: CrashyMocks.MockNotificationPresenter(),
            incrementalTSAttachmentMigrator: NoOpIncrementalMessageTSAttachmentMigrator(),
            testDependencies: AppSetup.TestDependencies(
                dateProvider: dateProvider,
                networkManager: CrashyMocks.MockNetworkManager(libsignalNet: nil),
                webSocketFactory: CrashyMocks.MockWebSocketFactory()
            )
        ).prepareDatabase().awaitable()
    }
}

// MARK: -

private extension LibSignalClient.ComparableBackup {
    convenience init(url: URL) throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        let fileLength = try fileHandle.seekToEnd()
        try fileHandle.seek(toOffset: 0)

        try self.init(
            purpose: .remoteBackup,
            length: fileLength,
            stream: fileHandle
        )
    }
}

// MARK: - CrashyMocks

private func failTest<T>(
    _ type: T.Type,
    _ function: StaticString = #function
) -> Never {
    let message = "Unexpectedly called \(type)#\(function)!"
    XCTFail(message)
    owsFail(message)
}

/// As a rule, integration tests for message backup should not mock out their
/// dependencies as their goal is to validate how the real, production app will
/// behave with respect to Backups.
///
/// These mocks are the exceptions to that rule, and encompass managers that
/// should never be invoked during Backup import or export.
private enum CrashyMocks {
    final class MockNetworkManager: NetworkManager {
        override func makePromise(request: TSRequest, canUseWebSocket: Bool = false) -> Promise<any HTTPResponse> { failTest(Self.self) }
    }

    final class MockWebSocketFactory: WebSocketFactory {
        var canBuildWebSocket: Bool { failTest(Self.self) }
        func buildSocket(request: WebSocketRequest, callbackScheduler: any Scheduler) -> (any SSKWebSocket)? { failTest(Self.self) }
    }

    final class MockCallMessageHandler: CallMessageHandler {
        func receivedEnvelope(_ envelope: SSKProtoEnvelope, callEnvelope: CallEnvelopeType, from caller: (aci: Aci, deviceId: UInt32), plaintextData: Data, wasReceivedByUD: Bool, sentAtTimestamp: UInt64, serverReceivedTimestamp: UInt64, serverDeliveryTimestamp: UInt64, tx: SDSAnyWriteTransaction) { failTest(Self.self) }
        func receivedGroupCallUpdateMessage(_ updateMessage: SSKProtoDataMessageGroupCallUpdate, for thread: TSGroupThread, serverReceivedTimestamp: UInt64) async { failTest(Self.self) }
    }

    final class MockCurrentCallThreadProvider: CurrentCallProvider {
        var hasCurrentCall: Bool { failTest(Self.self) }
        var currentGroupCallThread: TSGroupThread? { failTest(Self.self) }
    }

    final class MockNotificationPresenter: NotificationPresenter {
        func notifyUser(forIncomingMessage: TSIncomingMessage, thread: TSThread, transaction: SDSAnyReadTransaction) { failTest(Self.self) }
        func notifyUser(forIncomingMessage: TSIncomingMessage, editTarget: TSIncomingMessage, thread: TSThread, transaction: SDSAnyReadTransaction) { failTest(Self.self) }
        func notifyUser(forReaction: OWSReaction, onOutgoingMessage: TSOutgoingMessage, thread: TSThread, transaction: SDSAnyReadTransaction) { failTest(Self.self) }
        func notifyUser(forErrorMessage: TSErrorMessage, thread: TSThread, transaction: SDSAnyWriteTransaction) { failTest(Self.self) }
        func notifyUser(forTSMessage: TSMessage, thread: TSThread, wantsSound: Bool, transaction: SDSAnyWriteTransaction) { failTest(Self.self) }
        func notifyUser(forPreviewableInteraction: any TSInteraction & OWSPreviewText, thread: TSThread, wantsSound: Bool, transaction: SDSAnyWriteTransaction) { failTest(Self.self) }
        func notifyTestPopulation(ofErrorMessage errorString: String) { failTest(Self.self) }
        func notifyUser(forFailedStorySend: StoryMessage, to: TSThread, transaction: SDSAnyWriteTransaction) { failTest(Self.self) }
        func notifyUserToRelaunchAfterTransfer(completion: @escaping () -> Void) { failTest(Self.self) }
        func notifyUserOfDeregistration(transaction: SDSAnyWriteTransaction) { failTest(Self.self) }
        func clearAllNotifications() { failTest(Self.self) }
        func cancelNotifications(threadId: String) { failTest(Self.self) }
        func cancelNotifications(messageIds: [String]) { failTest(Self.self) }
        func cancelNotifications(reactionId: String) { failTest(Self.self) }
        func cancelNotificationsForMissedCalls(threadUniqueId: String) { failTest(Self.self) }
        func cancelNotifications(for storyMessage: StoryMessage) { failTest(Self.self) }
        func notifyUserOfDeregistration(tx: any DBWriteTransaction) { failTest(Self.self) }
    }
}
