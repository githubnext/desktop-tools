import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

private struct MenuRequest: Decodable {
	let target: ManagementTarget
	let path: [String]?
}

private struct MenuRow: Encodable {
	let path: [String]
	let kind: String
	let shortcut: String?
}

private struct MenuFilter: Encodable {
	let path: [String]
	let scope = "returned_native_inventory"
	let total: Int
	let matched: Int
}

private struct MenuInventory: Encodable {
	let target: ManagementTarget
	let application_name: String
	let bundle_id: String?
	let menus: [MenuRow]
	let native_row_count: Int
	let filter: MenuFilter?
	let native_completeness = "unknown"
	let cache_may_be_used = true
	let cache_ttl_ms = 2000
	let warnings = [
		"Native menu reads may reuse a cached structure; its observation time is unavailable. The cache expires 2 seconds after the original traversal finishes.",
		"Native completeness is unknown: lazy submenus, unavailable AX attributes and traversal limits may omit items. An empty subtree does not establish that no commands exist.",
		"Paths are literal title arrays for discovery, not input authority. Enabled and checked states are omitted because unavailable native attributes receive default values."
	]
}

private struct MenuReply: Encodable {
	let success = true
	let data: MenuInventory
}

private struct MenuError: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

func nativeMenus(_ client: PeekabooBridgeClient) async throws -> Data {
	var input = Data()
	while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
		guard input.count + chunk.count <= 4096 else { throw MenuError("Menu inventory requires one exact application target.") }
		input.append(chunk)
	}
	let request = try JSONDecoder().decode(MenuRequest.self, from: input)
	let target = request.target
	if let path = request.path {
		guard !path.isEmpty, path.count <= 8,
			path.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 512 })
		else { throw MenuError("Menu path requires 1 to 8 nonblank literal titles of at most 512 UTF-16 code units each.") }
	}
	guard target.window_id == nil, target.bounds == nil, target.is_minimized == nil else {
		throw MenuError("Menu inventory takes an application target from desktop_apps.")
	}
	let process = try target.processIdentity()
	try await verifyMenuApplication(client, process: process)
	let structure = try await client.listMenus(appIdentifier: "PID:\(process.processIdentifier)")
	// Save the menu's attestation before the following inventory replaces lastOperationReceipt.
	let receipt = await client.lastOperationReceipt()
	guard receipt?.payload.operation == .listMenus, structure.application.processIdentity == process else {
		throw MenuError("The native menu response did not attest the requested application generation. Refresh desktop_apps.")
	}
	try await verifyMenuApplication(client, process: process)
	var rows: [MenuRow] = []
	func append(_ items: [MenuItem], path: [String]) {
		for item in items {
			let path = path + [item.title]
			rows.append(MenuRow(path: path, kind: item.isSeparator ? "separator" : "item", shortcut: item.keyboardShortcut?.displayString))
			append(item.submenu, path: path)
		}
	}
	for menu in structure.menus {
		rows.append(MenuRow(path: [menu.title], kind: "menu", shortcut: nil))
		append(menu.items, path: [menu.title])
	}
	let total = rows.count
	var filter: MenuFilter?
	if let path = request.path {
		for count in 1 ... path.count {
			let prefix = Array(path.prefix(count))
			let matches = rows.filter { $0.path == prefix }
			guard matches.count == 1 else {
				throw MenuError(matches.isEmpty
					? "The requested menu path was not found in the returned native inventory; lazy menus or native limits may omit it."
					: "The requested menu path is ambiguous in the returned native inventory.")
			}
		}
		rows = rows.filter { $0.path.starts(with: path) }
		filter = MenuFilter(path: path, total: total, matched: rows.count)
	}
	try Task.checkCancellation()
	return try JSONEncoder().encode(MenuReply(data: MenuInventory(
		target: ManagementTarget(process), application_name: structure.application.name,
		bundle_id: structure.application.bundleIdentifier, menus: rows, native_row_count: total, filter: filter
	)))
}

private func verifyMenuApplication(_ client: PeekabooBridgeClient, process: ApplicationProcessIdentity) async throws {
	try Task.checkCancellation()
	let inventory = try await client.listApplicationMutationInventory()
	let receipt = await client.lastOperationReceipt()
	guard receipt?.payload.operation == PeekabooBridgeRequest.listApplicationMutationInventory.operation,
		inventory.items.contains(where: { $0.processIdentity == process })
	else { throw MenuError("The observed application generation could not be verified. Refresh desktop_apps before reading its menus.") }
	try Task.checkCancellation()
}
