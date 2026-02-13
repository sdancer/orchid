#!/usr/bin/env python3
"""Extract MPQ archives from Diablo II Demo installer."""
import struct
import os
import sys

def extract_mpqs(installer_path, output_dir):
    with open(installer_path, "rb") as f:
        data = f.read()

    os.makedirs(output_dir, exist_ok=True)
    sig = b"MPQ\x1a"
    pos = 0
    idx = 0

    while True:
        pos = data.find(sig, pos)
        if pos < 0:
            break
        header_size = struct.unpack_from("<I", data, pos + 4)[0]
        archive_size = struct.unpack_from("<I", data, pos + 8)[0]

        # Real MPQ headers have header_size == 32 (MPQv1)
        if header_size == 32 and archive_size > 1000:
            # Clamp to file size
            actual_size = min(archive_size, len(data) - pos)
            fname = os.path.join(output_dir, "d2demo_%d.mpq" % idx)
            with open(fname, "wb") as out:
                out.write(data[pos:pos + actual_size])
            mb = actual_size / 1024 / 1024
            print("Extracted %s (%.1f MB) from offset 0x%08x" % (fname, mb, pos))
            idx += 1
        pos += 4

    print("\nExtracted %d MPQ archive(s) to %s" % (idx, output_dir))

if __name__ == "__main__":
    installer = sys.argv[1] if len(sys.argv) > 1 else "/opt/diablo2-demo/DiabloIIDemo.exe"
    outdir = sys.argv[2] if len(sys.argv) > 2 else "/opt/diablo2-demo/mpqs"
    extract_mpqs(installer, outdir)
