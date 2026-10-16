import Foundation
import RinaCore
@main struct Probe {
 @MainActor static func main() async throws {
  let wronglySame = ProductionIdentity.sameBoard(sourceBoardID: "wifi:reused.local", sourceGeneration: UUID(), currentBoardID: "wifi:reused.local", currentGeneration: UUID())
  assert(wronglySame)
  print("REPRO R2: production sameBoard accepts identical hostname across different generations without physical identity")
  let dir = URL(fileURLWithPath: "/tmp/rina-reaudit-20261015/probe-journal-" + UUID().uuidString)
  let storage = DraftStorage(directory: dir)
  let coordinator = MultiBoardFaceSaveCoordinator(storage: storage)
  let connection = BoardConnection()
  let target = FrozenFaceSaveDestination(name: "A", connection: connection)!
  let first = await coordinator.prepare(name: "Original", snapshot: .init(frameHex: PackedFrame().hex94, type: "custom"), destinations: [target])
  assert(first)
  await coordinator.retry(using: [target])
  assert(coordinator.operation?.targets.first?.status == .conflict)
  await coordinator.finishIfConfirmed()
  assert(coordinator.operation != nil)
  let retained = try await MultiBoardFaceSaveCoordinator.hasRetainedOperation(in: storage)
  assert(retained)
  let next = await coordinator.prepare(name: "New unrelated save", snapshot: .init(frameHex: PackedFrame().hex94, type: "custom"), destinations: [target])
  assert(!next)
  print("REPRO R1: conflict -> Finish retains journal -> next unrelated prepare refused; operation isRunning=false")
  try FileManager.default.removeItem(at: dir)
 }
}
