#!/usr/bin/env python3
"""Generate binary data for displaced_cube.gltf"""

import struct
import os

# 24 vertices (4 per face), each face has unique vertices for correct normals/UVs
positions = [
    # Top face (Y=+1) - vertices 0-3
    -1.0,  1.0, -1.0,
     1.0,  1.0, -1.0,
     1.0,  1.0,  1.0,
    -1.0,  1.0,  1.0,
    # Bottom face (Y=-1) - vertices 4-7
    -1.0, -1.0,  1.0,
     1.0, -1.0,  1.0,
     1.0, -1.0, -1.0,
    -1.0, -1.0, -1.0,
    # Front face (Z=+1) - vertices 8-11
    -1.0, -1.0,  1.0,
     1.0, -1.0,  1.0,
     1.0,  1.0,  1.0,
    -1.0,  1.0,  1.0,
    # Back face (Z=-1) - vertices 12-15
     1.0, -1.0, -1.0,
    -1.0, -1.0, -1.0,
    -1.0,  1.0, -1.0,
     1.0,  1.0, -1.0,
    # Right face (X=+1) - vertices 16-19
     1.0, -1.0,  1.0,
     1.0, -1.0, -1.0,
     1.0,  1.0, -1.0,
     1.0,  1.0,  1.0,
    # Left face (X=-1) - vertices 20-23
    -1.0, -1.0, -1.0,
    -1.0, -1.0,  1.0,
    -1.0,  1.0,  1.0,
    -1.0,  1.0, -1.0,
]

normals = [
    # Top face
    0.0,  1.0,  0.0,
    0.0,  1.0,  0.0,
    0.0,  1.0,  0.0,
    0.0,  1.0,  0.0,
    # Bottom face
    0.0, -1.0,  0.0,
    0.0, -1.0,  0.0,
    0.0, -1.0,  0.0,
    0.0, -1.0,  0.0,
    # Front face
    0.0,  0.0,  1.0,
    0.0,  0.0,  1.0,
    0.0,  0.0,  1.0,
    0.0,  0.0,  1.0,
    # Back face
    0.0,  0.0, -1.0,
    0.0,  0.0, -1.0,
    0.0,  0.0, -1.0,
    0.0,  0.0, -1.0,
    # Right face
    1.0,  0.0,  0.0,
    1.0,  0.0,  0.0,
    1.0,  0.0,  0.0,
    1.0,  0.0,  0.0,
    # Left face
   -1.0,  0.0,  0.0,
   -1.0,  0.0,  0.0,
   -1.0,  0.0,  0.0,
   -1.0,  0.0,  0.0,
]

# UV coordinates - same pattern for each face
uvs = []
for _ in range(6):
    uvs.extend([
        0.0, 0.0,
        1.0, 0.0,
        1.0, 1.0,
        0.0, 1.0,
    ])

# Indices - 6 indices per face (2 triangles)
indices = []
for face in range(6):
    base = face * 4
    indices.extend([base, base + 1, base + 2, base, base + 2, base + 3])

# Pack data
pos_bytes = struct.pack(f'{len(positions)}f', *positions)
norm_bytes = struct.pack(f'{len(normals)}f', *normals)
uv_bytes = struct.pack(f'{len(uvs)}f', *uvs)
idx_bytes = struct.pack(f'{len(indices)}H', *indices)

# Combine all data
all_bytes = pos_bytes + norm_bytes + uv_bytes + idx_bytes

print(f"Positions: {len(positions)//3} vertices, {len(pos_bytes)} bytes")
print(f"Normals: {len(normals)//3} vertices, {len(norm_bytes)} bytes")
print(f"UVs: {len(uvs)//2} vertices, {len(uv_bytes)} bytes")
print(f"Indices: {len(indices)} indices, {len(idx_bytes)} bytes")
print(f"Total: {len(all_bytes)} bytes")

# Write binary file
script_dir = os.path.dirname(os.path.abspath(__file__))
output_path = os.path.join(script_dir, "displaced_cube.bin")
with open(output_path, 'wb') as f:
    f.write(all_bytes)

print(f"Written to: {output_path}")
