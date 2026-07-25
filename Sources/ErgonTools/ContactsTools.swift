import Ergon
import FoundationModels
import Contacts

// A function, not a global constant: [any CNKeyDescriptor] is not Sendable,
// so a top-level let trips Swift 6 concurrency checking.
private func contactKeys() -> [CNKeyDescriptor] {
    [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]
}

private func requestContactsAccess(_ store: CNContactStore) async throws {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized, .limited:
        return
    case .restricted, .denied:
        throw ContactsToolError.accessDenied
    case .notDetermined:
        let granted = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, any Error>) in
            store.requestAccess(for: .contacts) { granted, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: granted) }
            }
        }
        if !granted { throw ContactsToolError.accessDenied }
    @unknown default:
        throw ContactsToolError.accessDenied
    }
}

enum ContactsToolError: Error, CustomStringConvertible {
    case accessDenied
    case ambiguousUndo(String)

    var description: String {
        switch self {
        case .accessDenied: "Contacts access was denied"
        case .ambiguousUndo(let name): "Could not undo: no single contact named \(name) to remove"
        }
    }
}

public struct FindContactTool: ReadTool {
    public let name = "findContact"
    public let description = "Searches the user's contacts by name and returns matching phone numbers and emails."

    @Generable
    public struct Arguments {
        @Guide(description: "Full or partial name of the contact to search for")
        var name: String
    }

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        let store = CNContactStore()
        do {
            try await requestContactsAccess(store)
        } catch {
            return "Could not search contacts: \(error.localizedDescription)"
        }

        let predicate = CNContact.predicateForContacts(matchingName: arguments.name)
        let matches: [CNContact]
        do {
            matches = try store.unifiedContacts(matching: predicate, keysToFetch: contactKeys())
        } catch {
            return "Could not search contacts: \(error.localizedDescription)"
        }

        if matches.isEmpty {
            return "No match found for '\(arguments.name)'"
        }

        let lines = matches.map { c -> String in
            let fullName = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
            let phones = c.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
            let emails = c.emailAddresses.map { $0.value as String }.joined(separator: ", ")
            var parts = [fullName]
            if !phones.isEmpty { parts.append("phone: \(phones)") }
            if !emails.isEmpty { parts.append("email: \(emails)") }
            return parts.joined(separator: ", ")
        }
        return lines.joined(separator: "; ")
    }
}

public struct CreateContactTool: ReversibleTool {
    public let name = "createContact"
    public let description = "Creates a new contact in the user's address book."

    @Generable
    public struct Arguments {
        @Guide(description: "Contact's given (first) name")
        var givenName: String
        @Guide(description: "Contact's family (last) name")
        var familyName: String?
        @Guide(description: "Contact's phone number")
        var phone: String?
        @Guide(description: "Contact's email address")
        var email: String?
    }

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        let full = [arguments.givenName, arguments.familyName].compactMap { $0 }.joined(separator: " ")
        var detail = "Add \(full) to contacts"
        if let phone = arguments.phone { detail += ", phone \(phone)" }
        if let email = arguments.email { detail += ", email \(email)" }
        return ActionPreview(title: "Create Contact", detail: detail)
    }

    /// Removes the contact this call added, matched by the same name. Fails
    /// closed when several people share that name rather than guessing which
    /// one to delete.
    public func undo(_ arguments: Arguments) async throws -> String {
        let store = CNContactStore()
        try await requestContactsAccess(store)
        let full = [arguments.givenName, arguments.familyName].compactMap { $0 }.joined(separator: " ")
        let matches = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: full),
            keysToFetch: contactKeys())
        guard matches.count == 1, let contact = matches.first?.mutableCopy() as? CNMutableContact else {
            throw ContactsToolError.ambiguousUndo(full)
        }
        let request = CNSaveRequest()
        request.delete(contact)
        try store.execute(request)
        return "Removed contact \(full)"
    }

    public func call(arguments: Arguments) async throws -> String {
        let store = CNContactStore()
        try await requestContactsAccess(store)

        let contact = CNMutableContact()
        contact.givenName = arguments.givenName
        if let familyName = arguments.familyName {
            contact.familyName = familyName
        }
        if let phone = arguments.phone {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
        }
        if let email = arguments.email {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try store.execute(request)

        let full = [arguments.givenName, arguments.familyName].compactMap { $0 }.joined(separator: " ")
        return "Created contact \(full)"
    }
}
