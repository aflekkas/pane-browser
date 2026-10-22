#!/usr/bin/env python3
"""Type-check entire owned UI/coordinator sources, not extracted expressions.
App dependencies are stubs; SwiftUI/AppKit are the real SDK. CLT has no SwiftDataMacros,
so ONLY the @Query declaration is replaced by its typed array in a temporary copy.
This cannot replace full app CI, which must verify the actual app dependency graph.
"""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
files = sorted(root.joinpath('ora/Features/Passwords').rglob('*.swift'))
with tempfile.TemporaryDirectory(prefix='CredentialVaultUI-') as directory:
    support = Path(directory) / 'UISupport.swift'
    support.write_bytes(Path(__file__).with_name('UISupport.swift.fixture').read_bytes())
    # Check the integrated Settings source without any external handoff files.
    files.append(root / 'ora/Features/Settings/Sections/PasswordsSettingsView.swift')
    checked = []
    for original in files:
        source = original.read_text()
        if '@Query(' in source:
            declaration = '    @Query(sort: \\TabContainer.lastAccessedAt, order: .reverse) var containers: [TabContainer]'
            assert source.count(declaration) == 1
            source = source.replace(declaration, '    var containers: [TabContainer] = []')
            copy = Path(directory) / original.name
            copy.write_text(source)
            checked.append(copy)
        else:
            checked.append(original)
    subprocess.run(['swiftc' , '-typecheck', '-target', 'arm64-apple-macos14.0', *map(str, checked), str(support)], check=True)
