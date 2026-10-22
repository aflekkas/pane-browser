#!/usr/bin/env python3
"""Independent zipfile/zlib oracle, deliberately does not use the Swift reader's CRC or writer."""
import base64
import io
import json
from pathlib import Path
import struct
import zipfile
import zlib

item = {'categoryUuid': '001', 'state': 'active', 'overview': {'url': 'https://example.com', 'title': 'not shown'},
        'details': {'loginFields': [{'designation': 'username', 'value': 'a'}, {'designation': 'password', 'value': 'pw'}]}}
root = {'accounts': [{'vaults': [{'items': [item, {'categoryUuid': '002'}]}, {'items': [item]}]}, {'vaults': [{'items': [item]}]}]}
payload = json.dumps(root, separators=(',', ':')).encode()
def archive(method, names=('export.data',), body=payload):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w', method) as writer:
        for name in names:
            writer.writestr(name, body)
    return out.getvalue()
def changed(data, offset, fmt, value):
    result = bytearray(data)
    struct.pack_into('<' + fmt, result, offset, value)
    return bytes(result)
fixtures = {'valid-stored': archive(zipfile.ZIP_STORED), 'valid-deflated': archive(zipfile.ZIP_DEFLATED)}
data = fixtures['valid-deflated']
central = data.index(b'PK\x01\x02')
end = data.index(b'PK\x05\x06')
fixtures['overflow-eocd'] = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 0, 0, 0xfffffff0, 0xfffffff0, 0)
fixtures['overlap-eocd'] = changed(data, end + 12, 'I', end - central + 1)
fixtures['different-disk-count'] = changed(data, end + 8, 'H', 0)
fixtures['nonzero-disk'] = changed(data, end + 4, 'H', 1)
fixtures['central-disk'] = changed(data, central + 34, 'H', 1)
fixtures['missing-entry'] = changed(changed(data, end + 8, 'H', 2), end + 10, 'H', 2)
fixtures['leftover-directory'] = changed(changed(data, end + 8, 'H', 0), end + 10, 'H', 0)
fixtures['truncated'] = data[:-10]
fixtures['truncated-local'] = changed(data, central + 42, 'I', central - 10)
fixtures['duplicate-export'] = archive(zipfile.ZIP_STORED, ('export.data', './export.data'))
fixtures['local-name-mismatch'] = data[:30] + b'x' + data[31:]
for label, offset, fmt in [('flags', 6, 'H'), ('method', 8, 'H'), ('crc', 14, 'I'), ('size', 22, 'I'), ('compressed', 18, 'I')]:
    fixtures['local-' + label] = changed(data, offset, fmt, 65534)
fixtures['zip64'] = changed(data, central + 24, 'I', 0xffffffff)
fixtures['invalid-schema'] = archive(zipfile.ZIP_STORED, body=b'{"accounts":[{"vaults":null}]}')
fixtures['no-accounts'] = archive(zipfile.ZIP_STORED, body=b'{}')
# Valid JSON prefix plus additional decompressed bytes; size+CRC lie consistently in BOTH headers.
prefix = b'{"accounts":[]}'
extra = archive(zipfile.ZIP_DEFLATED, body=prefix + b'evil')
c = extra.index(b'PK\x01\x02')
for o in [14, c + 16]: extra = changed(extra, o, 'I', zlib.crc32(prefix))
for o in [22, c + 24]: extra = changed(extra, o, 'I', len(prefix))
fixtures['deflate-valid-prefix-extra-output'] = extra
# Trailing compressed bytes inserted before directory; update central/EOCD offsets and compressed lengths.
trailing = data[:central] + b'EXTRA' + data[central:]
newc, newe = central + 5, end + 5
for o in [18, newc + 20]: trailing = changed(trailing, o, 'I', struct.unpack_from('<I', data, 18)[0] + 5)
trailing = changed(trailing, newe + 16, 'I', newc)
fixtures['deflate-trailing-input'] = trailing
# Missing the final deflate bytes, but directory/header metadata agree.
short = data[:central-2] + data[central:]
newc, newe = central - 2, end - 2
for o in [18, newc + 20]: short = changed(short, o, 'I', struct.unpack_from('<I', data, 18)[0] - 2)
short = changed(short, newe + 16, 'I', newc)
fixtures['deflate-truncated-stream'] = short
output = Path(__file__).resolve().parents[1] / 'CredentialImportZIPFixtures.json'
output.write_text(json.dumps({name: base64.b64encode(value).decode() for name, value in fixtures.items()}, indent=2) + '\n')
