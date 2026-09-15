### 🤖 TASK HAND-OFF: Automation of Touch ID for Sudo on macOS

#### 📋 Context & Requirements
* **Environment:** macOS (MDM-managed).
* **Pain Point:** The user is frequently prompted for a manual password when executing occasional commands like `sudo purge`.
* **Goal:** Automate the injection of the Touch ID PAM module (`pam_tid.so`) into `/etc/pam.d/sudo` and create a resilient shell wrapper to handle MDM/update overwrites.

---

#### 🛠️ Execution Plan for Code Agent

1.  **File Modification:** Insert `auth sufficient pam_tid.so` as the first active line (typically line 2, right below the header comment) in `/etc/pam.d/sudo`.
2.  **Persistence Mechanism:** Create a robust Zsh function/alias setup to automatically check for and re-apply this configuration if an MDM policy or macOS update rolls it back.

---

#### 💻 Reference Implementation (Shell Script / `.zshrc`)

Provide or append the following logic to the user's environment configuration:

```bash
# ==============================================================================
# TOUCH ID FOR SUDO PERSISTENCE LAYER
# ==============================================================================

# Function to verify and patch the PAM configuration dynamically
ensure_sudo_touchid() {
    local pam_file="/etc/pam.d/sudo"
    local target_rule="auth       sufficient     pam_tid.so"

    # Check if the pam_tid rule is already present
    if ! grep -q "pam_tid.so" "$pam_file"; then
        echo "⚠️  Touch ID rule missing in $pam_file (likely reset by MDM/OS update)."
        echo "🔄 Re-applying Touch ID configuration..."
        
        # Inject the rule safely as the second line using awk
        sudo awk -v rule="$target_rule" 'NR==2{print rule}1' "$pam_file" > /tmp/sudo_pam_tmp \
        && sudo mv /tmp/sudo_pam_tmp "$pam_file" \
        && sudo chmod 444 "$pam_file" # Reset permissions to read-only
    fi
}

# Wrapper function for the user's specific workflow
spurge() {
    ensure_sudo_touchid
    sudo purge
}
```

---

#### 🧪 Verification Steps for Code Agent
* Verify that `spurge` triggers `ensure_sudo_touchid`.
* Confirm that if `pam_tid.so` is manually stripped from `/etc/pam.d/sudo` for testing, the wrapper correctly identifies the absence, prompts for a password *once* to fix it, and immediately functions via Touch ID on the subsequent run.