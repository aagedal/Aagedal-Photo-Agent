import Darwin
import Foundation

// Invalid or Release-build qualification launches never fall back to host stores.
if UITestNativeInvocationConfiguration.isRequested {
    guard let fixture = UITestNativeInvocationConfiguration.current else { exit(64) }
    MCPStdioServer(session: MCPServerSession(authorizationStore: fixture.authorizationStore,
        tools: fixture.helperTools())).run()
    exit(0)
}

let planDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Aagedal Photo Agent/Automation/PatchPlans", isDirectory: true)
let tools = MCPFoundationTools(patchPlans: MCPIPTCPatchPlanStore(storageDirectory: planDirectory),
    voiceTranscriptionPlans: MCPVoiceTranscriptionPlanStore(storageDirectory: MCPVoiceTranscriptionPlanStore.defaultStorageDirectory()))
MCPStdioServer(session: MCPServerSession(tools: tools)).run()
