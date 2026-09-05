import SwiftUI

struct SharingUserSetupView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    
    @State private var wantsNewUser = true
    @State private var username = "screenshare"
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isCreatingUser = false
    @State private var creationResult: CreationResult?
    @State private var showPassword = false
    @State private var showSuccessAnimation = false
    
    // Existing user selection
    @State private var existingUsers: [SystemUser] = []
    @State private var selectedExistingUser: SystemUser?
    @State private var isLoadingUsers = false
    @State private var existingUserSelected = false
    
    struct SystemUser: Identifiable, Hashable {
        let id: String
        let username: String
        let fullName: String
        let isAdmin: Bool
    }
    
    enum CreationResult {
        case success
        case failure(String)
    }
    
    var passwordsMatch: Bool {
        !password.isEmpty && password == confirmPassword
    }
    
    var isValidUsername: Bool {
        let pattern = "^[a-z][a-z0-9_]{2,30}$"
        return username.range(of: pattern, options: .regularExpression) != nil
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if case .success = creationResult {
                    successView
                } else if existingUserSelected, let user = selectedExistingUser {
                    existingUserSuccessView(user: user)
                } else {
                    header
                    
                    optionSelector
                    
                    if wantsNewUser {
                        userCreationForm
                    } else {
                        existingUserSelector
                    }
                    
                    if case .failure = creationResult {
                        resultView(creationResult!)
                    }
                    
                    Spacer()
                    
                    navigationButtons
                }
            }
            .padding(32)
        }
    }
    
    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Animated success icon
            ZStack {
                // Celebration rings
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Color.green.opacity(0.3 - Double(i) * 0.1), lineWidth: 2)
                        .frame(width: 100 + CGFloat(i) * 30, height: 100 + CGFloat(i) * 30)
                        .scaleEffect(showSuccessAnimation ? 1.2 : 0.8)
                        .opacity(showSuccessAnimation ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.5)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.3),
                            value: showSuccessAnimation
                        )
                }
                
                // Main checkmark circle
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.green, Color.green.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .shadow(color: .green.opacity(0.4), radius: 20, x: 0, y: 10)
                
                Image(systemName: "checkmark")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundColor(.white)
            }
            .scaleEffect(showSuccessAnimation ? 1 : 0.5)
            .opacity(showSuccessAnimation ? 1 : 0)
            
            VStack(spacing: 12) {
                Text("Account Created! 🎉")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text("Your dedicated screen sharing account is ready to use")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(showSuccessAnimation ? 1 : 0)
            .offset(y: showSuccessAnimation ? 0 : 20)
            
            // Account details card
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Username")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(username)
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "person.badge.shield.checkmark.fill")
                        .font(.title)
                        .foregroundColor(.green)
                }
                
                Divider()
                
                // Confirmation that this is the selected account
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected as Default")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text("This account will be used for all screen sharing connections")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.1))
                )
                
                Divider()
                
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    
                    Text("Share this username with others who need to connect to your Mac. Your password remains private.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
            )
            .padding(.horizontal, 20)
            .opacity(showSuccessAnimation ? 1 : 0)
            .offset(y: showSuccessAnimation ? 0 : 30)
            
            Spacer()
            
            // Continue button
            Button {
                viewModel.nextStep()
            } label: {
                HStack {
                    Text("Continue Setup")
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .opacity(showSuccessAnimation ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                showSuccessAnimation = true
            }
        }
    }
    
    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 50))
                .foregroundColor(.blue)
            
            Text("Screen Sharing Account")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("For security, we recommend creating a dedicated account for screen sharing instead of using your admin credentials.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var optionSelector: some View {
        VStack(spacing: 12) {
            OptionCard(
                title: "Create Sharing Account",
                description: "Create a dedicated user for screen sharing (recommended)",
                icon: "person.badge.plus",
                isSelected: wantsNewUser
            ) {
                wantsNewUser = true
            }
            
            OptionCard(
                title: "Use Existing Account",
                description: "I'll use my current user account for screen sharing",
                icon: "person.fill",
                isSelected: !wantsNewUser
            ) {
                wantsNewUser = false
            }
        }
    }
    
    private var userCreationForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Account Details")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Username")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("screenshare", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                
                if !username.isEmpty && !isValidUsername {
                    Text("Username must be lowercase, start with a letter, 3-31 characters")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    if showPassword {
                        TextField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                if !password.isEmpty && password.count < 8 {
                    Text("Password must be at least 8 characters")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Confirm Password")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                SecureField("Confirm password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                
                if !confirmPassword.isEmpty && !passwordsMatch {
                    Text("Passwords don't match")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
            
            // Info box
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                
                Text("This will create a standard (non-admin) user account that can only be used for screen sharing. You'll need to enter your admin password to create it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
    
    private var existingUserSelector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Existing Account")
                .font(.headline)
            
            if isLoadingUsers {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading users...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else if existingUsers.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.slash")
                        .foregroundColor(.secondary)
                    Text("No other user accounts found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                VStack(spacing: 8) {
                    ForEach(existingUsers) { user in
                        ExistingUserRow(
                            user: user,
                            isSelected: selectedExistingUser?.id == user.id
                        )
                        .onTapGesture {
                            selectedExistingUser = user
                        }
                    }
                }
            }
            
            if let selected = selectedExistingUser {
                // Show confirmation for selected user
                HStack(spacing: 10) {
                    Image(systemName: selected.isAdmin ? "exclamationmark.shield.fill" : "checkmark.seal.fill")
                        .foregroundColor(selected.isAdmin ? .orange : .green)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.isAdmin ? "Admin Account Selected" : "Standard Account Selected")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text(selected.isAdmin 
                             ? "This account has full system access" 
                             : "Good choice! This account has limited privileges")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected.isAdmin ? Color.orange.opacity(0.1) : Color.green.opacity(0.1))
                )
            }
            
            // Info box
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                
                Text("Select the account you want to use for screen sharing. Non-admin accounts are recommended for security.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear {
            loadExistingUsers()
        }
    }
    
    private func loadExistingUsers() {
        isLoadingUsers = true
        
        Task {
            let users = await fetchSystemUsers()
            await MainActor.run {
                existingUsers = users
                isLoadingUsers = false
            }
        }
    }
    
    private func fetchSystemUsers() async -> [SystemUser] {
        // Get list of users using a single optimized command
        // This gets all user info in one shot instead of multiple calls per user
        let result = ShellExecutor.execute("""
            dscl . -list /Users | while read user; do
                [[ "$user" == _* ]] && continue
                [[ "$user" == "root" || "$user" == "daemon" || "$user" == "nobody" || "$user" == "Guest" ]] && continue
                home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | grep "/Users/" || true)
                [[ -z "$home" ]] && continue
                name=$(dscl . -read "/Users/$user" RealName 2>/dev/null | tail -1 | sed 's/^ *//')
                [[ -z "$name" || "$name" == "RealName:" ]] && name="$user"
                admin=$(dsmemberutil checkmembership -U "$user" -G admin 2>/dev/null | grep -c "is a member" || echo 0)
                echo "$user|$name|$admin"
            done
            """)
        
        var systemUsers: [SystemUser] = []
        
        let lines = result.output.split(separator: "\n")
        for line in lines {
            let parts = String(line).split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count >= 3 else { continue }
            
            let username = parts[0]
            let fullName = parts[1]
            let isAdmin = parts[2] == "1"
            
            // Sanitize username
            let safeUsername = username.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            guard !safeUsername.isEmpty, safeUsername == username else { continue }
            
            systemUsers.append(SystemUser(
                id: safeUsername,
                username: safeUsername,
                fullName: fullName.isEmpty ? safeUsername : fullName,
                isAdmin: isAdmin
            ))
        }
        
        // Sort: non-admin first, then by name
        return systemUsers.sorted { 
            if $0.isAdmin != $1.isAdmin {
                return !$0.isAdmin // Non-admin first
            }
            return $0.fullName < $1.fullName
        }
    }
    
    @ViewBuilder
    private func resultView(_ result: CreationResult) -> some View {
        switch result {
        case .success:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Account Created Successfully!")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("Username: \(username)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.1))
            )
            
        case .failure(let error):
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Failed to Create Account")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.1))
            )
        }
    }
    
    private func existingUserSuccessView(user: SystemUser) -> some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Success icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.blue.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .shadow(color: .blue.opacity(0.4), radius: 20, x: 0, y: 10)
                
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 45, weight: .medium))
                    .foregroundColor(.white)
            }
            .scaleEffect(showSuccessAnimation ? 1 : 0.5)
            .opacity(showSuccessAnimation ? 1 : 0)
            
            VStack(spacing: 12) {
                Text("Account Selected! ✓")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text("You've chosen an existing account for screen sharing")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(showSuccessAnimation ? 1 : 0)
            .offset(y: showSuccessAnimation ? 0 : 20)
            
            // Account details card
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Account")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(user.fullName)
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("@\(user.username)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: user.isAdmin ? "person.badge.shield.checkmark.fill" : "person.badge.checkmark")
                        .font(.title)
                        .foregroundColor(user.isAdmin ? .orange : .blue)
                }
                
                Divider()
                
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected as Default")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text("This account will be used for all screen sharing connections")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.1))
                )
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
            )
            .padding(.horizontal, 20)
            .opacity(showSuccessAnimation ? 1 : 0)
            .offset(y: showSuccessAnimation ? 0 : 30)
            
            Spacer()
            
            Button {
                viewModel.nextStep()
            } label: {
                HStack {
                    Text("Continue Setup")
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .opacity(showSuccessAnimation ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                showSuccessAnimation = true
            }
        }
    }
    
    private var navigationButtons: some View {
        HStack {
            Button("Back") {
                viewModel.previousStep()
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            if wantsNewUser {
                if case .success = creationResult {
                    Button("Continue") {
                        viewModel.nextStep()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        createSharingUser()
                    } label: {
                        HStack {
                            if isCreatingUser {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text("Create Account")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!passwordsMatch || !isValidUsername || password.count < 8 || isCreatingUser)
                }
            } else {
                Button {
                    selectExistingUser()
                } label: {
                    Text("Select Account")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedExistingUser == nil)
            }
        }
    }
    
    private func selectExistingUser() {
        guard let user = selectedExistingUser else { return }
        
        // Save the selected username
        UserDefaults.standard.set(user.username, forKey: "screenShareUsername")
        
        // Show success view
        showSuccessAnimation = false
        existingUserSelected = true
    }
    
    private func createSharingUser() {
        isCreatingUser = true
        creationResult = nil
        
        // The command is an AppleScript string literal wrapping a shell
        // command, so each value is escaped for both layers: shell quoting
        // first, then AppleScript's backslash/double-quote escaping. Doing
        // only the shell layer let a password containing `"` terminate the
        // AppleScript literal (and fail account creation).
        let command = "sysadminctl -addUser \(SharingConfigurationService.shellEscaped(username)) "
            + "-password \(SharingConfigurationService.shellEscaped(password)) -hint 'Screen sharing account'"
        let script = """
        do shell script "\(SharingConfigurationService.appleScriptEscaped(command))" with administrator privileges
        """
        
        Task {
            let success = await SharingConfigurationService.shared.executeAppleScript(script)
            
            await MainActor.run {
                isCreatingUser = false
                if success {
                    creationResult = .success
                    // Save the username for later use
                    UserDefaults.standard.set(username, forKey: "screenShareUsername")
                } else {
                    creationResult = .failure("Could not create user. The username may already exist, or the operation was cancelled.")
                }
            }
        }
    }
}

struct ExistingUserRow: View {
    let user: SharingUserSetupView.SystemUser
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // User icon
            ZStack {
                Circle()
                    .fill(user.isAdmin ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Image(systemName: user.isAdmin ? "person.badge.shield.checkmark" : "person.fill")
                    .foregroundColor(user.isAdmin ? .orange : .blue)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(user.fullName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack(spacing: 4) {
                    Text("@\(user.username)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if user.isAdmin {
                        Text("• Admin")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
        )
        .contentShape(Rectangle())
    }
}

struct OptionCard: View {
    let title: String
    let description: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : .accentColor)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.1))
                    )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct SharingUserSetupView_Previews: PreviewProvider {
    static var previews: some View {
        SharingUserSetupView(viewModel: OnboardingViewModel())
            .frame(width: 500, height: 650)
    }
}

