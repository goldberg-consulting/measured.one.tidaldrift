import SwiftUI

/// Sheet presented before connecting to a LocalCast host.
/// Auto-fills from saved device credentials or lets the user enter a password.
struct LocalCastPINEntryView: View {
    let deviceName: String
    let savedPassword: String?
    let onConnect: (String?) -> Void
    let onCancel: () -> Void
    
    @State private var password: String = ""
    @FocusState private var isPasswordFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                
                Text("Connect to \(deviceName)")
                    .font(.headline)
                
                if savedPassword != nil {
                    Text("Saved credentials found — connecting with your stored password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Enter the host password, or connect without authentication.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            
            if savedPassword == nil {
                // Password entry (only shown if no saved credentials)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($isPasswordFocused)
                    .onSubmit {
                        if !password.isEmpty {
                            onConnect(password)
                        }
                    }
            }
            
            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                if savedPassword == nil {
                    Button("Skip (No Auth)") {
                        onConnect(nil)
                    }
                    .buttonStyle(.bordered)
                }
                
                Button(savedPassword != nil ? "Connect" : "Connect") {
                    if let saved = savedPassword {
                        onConnect(saved)
                    } else {
                        onConnect(password.isEmpty ? nil : password)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 360)
        .onAppear {
            if savedPassword != nil {
                // Auto-connect after a brief delay so the user sees the sheet
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onConnect(savedPassword)
                }
            } else {
                isPasswordFocused = true
            }
        }
    }
}
