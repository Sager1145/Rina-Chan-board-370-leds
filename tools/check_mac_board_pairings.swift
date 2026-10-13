// Read only the two test boards; do not expose or change unrelated devices.
import Foundation
import IOBluetooth

let addresses: Set<String> = ["80b54ef48e08", "80b54ef48e09", "80b54ef74800", "80b54ef74801"]
guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
    fputs("Unable to verify the Mac Bluetooth pairing inventory.\n", stderr)
    exit(1)
}
let boards = devices.filter {
    let address = ($0.addressString ?? "").lowercased().filter { $0.isHexDigit }
    return addresses.contains(address)
}
print("pairedBoardCount=\(boards.count)")
for board in boards {
    print("board=\(board.addressString ?? "unknown") paired=\(board.isPaired()) connected=\(board.isConnected())")
}
if !boards.isEmpty {
    fputs("Forget only the listed boards in System Settings → Bluetooth before completing cleanup.\n", stderr)
    exit(1)
}
