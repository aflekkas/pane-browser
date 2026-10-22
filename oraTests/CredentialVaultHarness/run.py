#!/usr/bin/env python3
"""Build the actual owned sources with CLT Security/LA/AppKit/Compression and Swift Testing.
Copies are hashed against originals on every run; no production keychain backend is constructed.
Real OS tests explicitly create a temporary keychain and constrain ALL reads to that file.
"""
import hashlib
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
services = root / 'ora/Features/Passwords/Services'
files = sorted(set(services.glob('Credential*.swift')) | set(services.glob('PasswordManager*.swift')) |
               {services / 'LegacyPasswordMigration.swift', services / 'PasswordMetadataStore.swift',
                services / 'PasswordVaultModels.swift'})
files = sorted(set(files) | set(services.glob('PasswordAutofill*.swift')))
tests = sorted(root.joinpath('oraTests').glob('Credential*Tests.swift')) + [root / 'oraTests/CredentialVaultTestSupport.swift']
with tempfile.TemporaryDirectory(prefix='CredentialVaultHarness-') as scratch:
    path = pathlib.Path(scratch)
    for folder, sources in [('Sources/Ora', files), ('Tests/OraTests', tests)]:
        target = path / folder
        target.mkdir(parents=True)
        for source in sources:
            shutil.copy2(source, target / source.name)
            assert hashlib.sha256(source.read_bytes()).digest() == hashlib.sha256((target / source.name).read_bytes()).digest()
    shutil.copy2(pathlib.Path(__file__).with_name('BridgeSupport.swift.fixture'), path / 'Sources/Ora/BridgeSupport.swift')
    shutil.copy2(root / 'oraTests/CredentialImportZIPFixtures.json', path / 'Tests/OraTests/CredentialImportZIPFixtures.json')
    path.joinpath('Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CredentialVaultCheck", platforms: [.macOS(.v14)], targets: [
.target(name: "Ora"), .testTarget(name: "OraTests", dependencies: ["Ora"], exclude: ["CredentialImportZIPFixtures.json"],
            swiftSettings: [.define("CREDENTIAL_VAULT_HARNESS")])])
''')
    frameworks = '/Library/Developer/CommandLineTools/Library/Developer/Frameworks'
    subprocess.run(['swift', 'test', '-Xswiftc', '-F' + frameworks, '-Xlinker', '-F' + frameworks, '-Xlinker', '-rpath', '-Xlinker', frameworks, '-Xlinker', '-rpath', '-Xlinker', '/Library/Developer/CommandLineTools/Library/Developer/usr/lib', '--package-path', str(path), '--scratch-path', str(root / 'oraTests/CredentialVaultHarness/.build')], check=True)
