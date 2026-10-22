#!/usr/bin/env python3
"""Generate reviewable shared changes WITHOUT modifying the shared checkout."""
from pathlib import Path
import difflib
import hashlib
import json
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
changes = {}
def change(path, transform):
    original = root.joinpath(path).read_text()
    updated = transform(original)
    assert original != updated, path
    changes[path] = (original, updated)
def settings(source):
    source = source.replace('    @State private var isAuthenticating = false',
                            '    @State private var isAuthenticating = false\n    @State private var unlockAttempt = UUID()', 1)
    source = source.replace('        .onDisappear {\n            lockVault()\n        }',
                            '''        .onDisappear {
            lockVault()
        }
        .onReceive(passwordManager.$authenticationRevision.dropFirst()) { _ in
            clearVaultState()
        }''', 1)
    needle = '            if !selectedProvider.isAvailable {'
    source = source.replace(needle, '''            if selectedProvider.usesBuiltInVault {
                Text(passwordManager.vaultProtection.userFacingDescription)
                    .font(.caption)
                    .foregroundStyle(passwordManager.vaultProtection == .userPresence ? Color.secondary : Color.orange)
            }

'''+needle, 1)
    source = source.replace('        isAuthenticating = true\n        Task {',
                            '        isAuthenticating = true\n        let attempt = UUID()\n        unlockAttempt = attempt\n        Task {', 1)
    source = source.replace('                isUnlocked = authenticated',
                            '                guard unlockAttempt == attempt else { return }\n                isUnlocked = authenticated && passwordManager.isAuthenticated', 1)
    source = source.replace('    private func lockVault() {\n', '''    private func lockVault() {
        clearVaultState()
        passwordManager.invalidateAuthenticatedContext()
    }

    private func clearVaultState() {
        unlockAttempt = UUID()
''', 1)
    source = source.replace('                    if let origin = entry.origin {', '''                    Text(passwordManager.storedProtectionDescription(for: entry))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let origin = entry.origin {''', 1)
    return source
def project(source):
    source = source.replace('        com.apple.developer.web-browser.public-key-credential: true',
        '''        com.apple.developer.web-browser.public-key-credential: true
        # Release only: provisioning must authorize this group; Debug keeps pane-local.entitlements.
        keychain-access-groups:
          - "$(AppIdentifierPrefix)com.aflekkas.pane"''', 1)
    source = source.replace('      - path: oraTests\n', '      - path: oraTests\n        excludes:\n          - "CredentialVaultHarness/**"\n', 1)
    return source
change('ora/Features/Settings/Sections/PasswordsSettingsView.swift', settings)
change('ora/Features/Importer/Views/ImportDataButton.swift', lambda s: s.replace('// importSafari()',
    'Task { @MainActor in openPasswordsWindow() }').replace('// importChrome()',
    'Task { @MainActor in openPasswordsWindow() }'))
change('project.yml', project)
change('ora/Info/ora.entitlements', lambda s: s.replace('\t<key>com.apple.security.app-sandbox</key>',
    '\t<key>keychain-access-groups</key>\n\t<array>\n\t\t<string>$(AppIdentifierPrefix)com.aflekkas.pane</string>\n\t</array>\n\t<key>com.apple.security.app-sandbox</key>', 1))
# Format only an isolated copy of proposed Settings Swift, never the original shared file.
with tempfile.TemporaryDirectory(prefix='CredentialVaultIntegration-') as temp:
    for name, (original, updated) in list(changes.items()):
        if name.endswith('.swift'):
            copied = Path(temp) / Path(name).name
            copied.write_text(updated)
            subprocess.run(['/tmp/swiftformat-0.63.1/swiftformat', str(copied), '--config', str(root / '.swiftformat')], check=True, capture_output=True)
            changes[name] = (original, copied.read_text())
patch = ''.join(''.join(difflib.unified_diff(a.splitlines(True), b.splitlines(True), fromfile='a/'+name, tofile='b/'+name))
                for name, (a, b) in changes.items())
root.joinpath('../../parallel-ports/vault-integration.patch').write_text(patch)
Path(__file__).with_name('integration-base-hashes.json').write_text(json.dumps({name: hashlib.sha256(a.encode()).hexdigest() for name, (a,b) in changes.items()}, indent=2)+'\n')
# Verify the exact patch applies to a disposable copy of the captured shared inputs.
with tempfile.TemporaryDirectory(prefix='CredentialVaultPatchCheck-') as temp:
    for name, (original, _) in changes.items():
        target = Path(temp) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(original)
    subprocess.run(['patch', '--dry-run', '-p1', '-i', str(root.joinpath('../../parallel-ports/vault-integration.patch').resolve())], cwd=temp, check=True)
