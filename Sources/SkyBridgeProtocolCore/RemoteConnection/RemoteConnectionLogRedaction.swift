/// Produces diagnostics that preserve event structure without retaining
/// authentication material or persistent peer identifiers in system logs.
public enum RemoteConnectionLogRedaction {
    public static func session(_ value: String) -> String {
        value.isEmpty ? "<empty>" : "<redacted>"
    }

    public static func peer(_ value: String) -> String {
        value.isEmpty ? "<empty>" : "<redacted>"
    }

    public static func untrustedText(_ value: String) -> String {
        value.isEmpty ? "<empty>" : "<redacted>"
    }

    public static func error(_ error: any Error) -> String {
        String(describing: type(of: error))
    }
}
