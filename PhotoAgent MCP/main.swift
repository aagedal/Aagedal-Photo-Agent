import Foundation

let planDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Aagedal Photo Agent/Automation/PatchPlans", isDirectory: true)
let tools = MCPFoundationTools(patchPlans: MCPIPTCPatchPlanStore(storageDirectory: planDirectory))
MCPStdioServer(session: MCPServerSession(tools: tools)).run()
